# Windows 版后续实施方案

本文件供接手实现的 agent 使用，也供维护者排期。它**自包含**：不依赖 `work/` 下的任何文件（该目录不进版本库）。面向用户的说明在 [windows.md](windows.md)，本文件只讲“还要做什么、怎么做、怎么验收”。

- 一个 agent 一次只领取一个工作包（下称 WP），按第 4 节的顺序和依赖关系进行。
- 每个 WP 完成并通过检查后单独提交，然后在第 1 节的状态表里把它标成已完成（写上提交号），再交给下一个 agent。
- 文中“已核实”表示写这份方案时逐行读过对应的 macOS 源码；“待核实”表示只确认了入口位置，**实现前必须先读源码**，不要按本文的概述猜测字段或时序。

## 1. 状态

| WP | 内容 | 规模 | 状态 |
| --- | --- | --- | --- |
| — | 第一版：协议核心、Windows 被控端与控制端、构建与检查 | — | 已完成（`dafab21`、`4e236d7`、`d34ad04`） |
| — | 编码器低延迟修复（实机反馈“光标跟随慢”的直接原因） | — | 已提交 `e8b0508`，**待实机确认**（见 WP0） |
| — | 媒体会话的线格式与状态机 `windows/core/src/media.rs` | — | 基础实现已提交 `5da7c0c`，会话接入见 WP1 |
| WP0 | 实机确认编码器修复 | 小 | 待用户执行 |
| WP1 | 媒体会话接入（控制连接上的 `shared` 路径） | 中 | 已完成 `cc31c4a`，双向互通与 Wine 验收通过。Windows 10/11 实机表现待确认 |
| WP2 | 独立光标（本地即时光标） | 中 | 已提交 `945008b`。双向协议与 Wine 检查通过，单光标观感、热点和延迟待 Windows 实机确认 |
| WP3 | 控制端断线自动重连与空闲暂停 | 小 | 已完成 `fcb8215`。回环重启恢复、主动结束、配对失败及隔离 Wine 窗口检查通过 |
| WP4 | 多显示器 | 中 | 已提交 `3567d16`。双向切屏、失败回滚和 Wine 单屏窗口验收通过。物理双屏热插拔与混合 DPI 待 Windows 实机确认 |
| WP5 | 输入补全（输入状态回馈、Caps Lock 同步、相对鼠标、手势、设备身份） | 中，可拆分 | 键盘动作与反馈已提交 `22bdedd`，相对鼠标已提交 `4b32a41`，精密滚动和手势已提交 `a9c4c70`，设备身份已提交 `4e67c77`。已完成软件验收，物理键鼠及触摸设备待实机确认 |
| WP6 | 自动剪贴板，图片与文件 | 大 | 未开始 |
| WP7 | 视频性能：GPU 缩放与色彩转换、硬件编码、HEVC、60 fps 以上、码率自适应 | 大，可拆分 | 每秒性能统计已提交 `e9002e1`。Windows 实机基线和硬件路径待验，后续优化待开发 |
| WP8 | 远端声音 | 中 | 未开始 |
| WP9 | 辅助 TCP 通道与 UDP 视频（DTLS、分片、补传、FEC、路径策略） | 特大，分 5 步 | 未开始，依赖 WP1 |
| WP10 | 自托管中继 | 大 | 未开始，依赖 WP9 |
| WP11 | 会话工具：模拟键入、桌面操作、静音/黑屏遮罩/断开后锁屏、自动解锁、画质探测 | 中，可拆分 | 未开始 |
| WP12 | 端口映射 | 中 | 未开始 |
| WP13 | 以系统服务运行（UAC 提示与锁屏可控） | 大，安全敏感 | 未开始，需用户先确认方案 |
| WP14 | 工程化：ARM64、CI 与发布、签名、安装与更新、macOS 端文案 | 中，可拆分 | 未开始，部分需用户决定 |

“规模”只表示相对工作量与风险，用于分配，不是工期。

本地 `main` 领先远端，**没有推送**。推送 `main` 会触发 macOS 自动发布，未经用户明确要求禁止推送。

### 交给 agent 时可以直接用的说明

> 请先阅读仓库根目录的 `AGENTS.md` 和 `docs/windows-plan.md` 的第 2、3 节，然后实现其中的 **WPn**（n 换成具体编号，只做这一个工作包）。移植前先读该工作包列出的 macOS 源码，以源码为准；标注“待核实”的内容不要按方案里的概述猜测。完成标准是该工作包的“完成标准”加第 3 节第 11–15 条：检查全部通过、单独提交到本地 `main`、更新状态表与文档、不推送。交付时分开说明：哪些由检查验证过，哪些只在 Wine 里运行过，哪些需要在真实 Windows 上确认。遇到需要用户决定的事项（方案里标了“与用户确认”的地方）先停下来问。

## 2. 现状

### 2.1 已有的东西

```
windows/
  core/     与平台无关的协议实现，在 macOS 上即可编译和测试
    wire.rs      帧封装、消息编号（47 种，与 macOS 一致）、ByteReader
    messages.rs  Hello、StreamSettings、RemoteInput、暂停/结束/控制状态等 JSON 消息
    pairing.rs   配对码；tls.rs  TLS 1.2 PSK（OpenSSL，随源码构建）
    peer.rs      一条加密连接：有序收发、心跳、空闲超时、半关闭收尾
    video.rs     VideoPacket、H.264 Annex B 与 AVCC 转换、H264FrameAssembler
    host.rs      被控端会话（HostPlatform、FrameSink、HostOptions/HostCommand/HostEvent）
    viewer.rs    控制端会话（ViewerPlatform、ViewerCommand/ViewerEvent/ViewerEnd）
    media.rs     媒体会话线格式与双方状态机，供 host.rs / viewer.rs 协商与传输视频
    keymap.rs input.rs   macOS 键码与 PC 扫描码互译、修饰键映射、点击计数、滚轮
    pixel.rs     BGRA→NV12（面积平均缩放，BT.709 视频范围）、NV12→BGRA、光标绘制
    tests/loopback.rs    Rust 被控端 ↔ Rust 控制端的回环测试
  probe/    无界面的被控端/控制端，经标准输入输出驱动，供互通检查使用
  app/      Windows 程序（只在 Windows 目标上编译）
    win/capture.rs   按所选显示器使用桌面复制或 GDI 采集
    win/codec.rs     Media Foundation H.264 软件编码器与解码器
    win/pipeline.rs  采集线程：采集→光标→NV12→编码→FrameSink
    win/inject.rs    SendInput；win/clipboard.rs 文字剪贴板
    win/app.rs       监听与会话生命周期、解码线程、日志
    win/canvas.rs    控制端窗口（Direct2D、键盘钩子、全屏、菜单）
    win/ui.rs        主窗口；win/settings.rs 设置与 DPAPI
    bin/wincheck.rs  只用于检查的控制台入口（capture / codec / host / viewer）
AppChecks/WindowsInteropChecks.swift   与 macOS 实现的双向互通检查
scripts/run-windows-interop-checks.sh  Rust 测试 + 上述互通检查
scripts/run-windows-wine-checks.sh     交叉编译产物在 Wine 容器中的冒烟检查
scripts/build-windows.sh               交叉编译并打包到 outputs/windows/
scripts/windows-toolchain.sh           固定版本并校验摘要的 llvm-mingw
scripts/check-cargo-lock-age.py        检查锁定的依赖是否已发布满 7 天
```

初版 Windows 端通过 macOS 的旧版兼容路径互通。WP1 在此基础上增加了可选媒体会话。

- 被控端 Hello 声明 `liveSettings`、`controlStatusUpdates`、`extendedVideoSettings`、`preferredSettings`、`highRefreshVideoSettings`、`preferredHighRefreshSettings`、`sessionPause`、`sessionTerminationV1`、`initialStreamNegotiationV1`。WP1 新增 `mediaTransportV1`，WP2 在平台支持光标采样时声明 `independentCursorV1`，在首个媒体流提交后独立协商。
- 两端支持时使用控制连接上的 `shared` 流，H.264 视频通过 `mediaFrame` 发送并以 `mediaFeedback` 确认。首次切换前和对接旧版本时继续支持 `video` / `acknowledgement`。Windows 被控端最多等待 3 帧确认。
- 被控端能枚举活动屏幕时声明 `displaySwitchingV1`，能读取当前控制台的键盘大写状态时声明 `inputActions`。两项能力独立协商。
- 控制端只使用被控端 Hello 里声明且自己已实现的能力；收到未协商的消息类型即断开，与 macOS 一致。

### 2.2 WP1 开工前的验证基线

| 检查 | 当前结果 | 覆盖 |
| --- | --- | --- |
| `cargo test -p quietdesk-core` | 56 项单元测试 + 2 项回环测试通过 | 线格式、校验、键位、像素、媒体状态机 |
| `run-windows-interop-checks.sh` | 11 项通过 | Windows 协议代码 ↔ 本机 `Peer`、`Hello`、`VideoTuningSession`、VideoToolbox、`MediaSession.host`、`InputInjector`，双向 |
| `run-windows-wine-checks.sh` | 3 项通过 | GDI 采集、MF 编解码、Windows 被控端 ↔ Windows 控制端 |
| 真实 Windows | 用户运行过第一版并提供了一份 Windows 被控端的日志，反馈当时唯一的问题是“光标跟随非常慢” | 没有逐项记录测过哪些方向与功能；第 5 节的清单都还要确认 |

Wine 不等于 Windows：没有桌面复制，编解码来自 GStreamer（编码器会先缓存约 60 帧），不验证 `SendInput`、键盘钩子、Direct2D 上屏、DPAPI、防火墙与高 DPI。**任何 WP 都不能以 Wine 通过代替实机结论**，交付说明里要分开写。

### 2.3 已知缺口（不属于某个 WP 的零散项）

- 主窗口与远程窗口的中文排版只在 Wine（无中文字体，显示为方框）里看过控件位置。
- Windows N/KN 版缺少媒体功能包时没有 H.264 编解码器，目前只会在日志里报错，界面没有专门提示。
- WP4 前只共享主显示器。现在可在主窗口选屏，在支持显示器协商的会话中动态切换。显示器旋转时回退 GDI。
- 控制端只支持到 60 fps；被控端编码上限由“画质上限”决定，CPU 缩放加软件编码在 4K 屏上达不到 60 fps。
- WP3 前的控制端窗口会在断线后直接关闭。现在网络故障会进入重连倒计时，并保留已显示的画面。

## 3. 所有 agent 必须遵守的约束

先读仓库根目录的 `AGENTS.md`，下面是对 Windows 工作的补充和强调。

**协议与兼容**

1. macOS 是协议的唯一事实来源：`Sources/QuietDeskCore`（协议与会话）与 `Sources/QuietDesk`（应用如何使用协议，尤其是 `DeskModel.swift`）。移植前读实现，不要从文档或本文推断线格式。
2. 默认**不修改 macOS 源码**。确需修改（例如 WP14 的文案）时单独说明原因并取得用户同意；修改协议模型时两端一起改并跑全量检查。
3. 新能力只在实现完成后才写进 Hello。Windows 端不声明的能力，macOS 端不会使用；这是目前互通安全的基础。
4. 消息编号、JSON 字段名、字节序（大端）、长度上限全部照搬。可选字段缺失时保持旧行为。对端输入一律校验后再用（长度、范围、枚举值、方向）。
5. 不引入明文或证书回退路径；配对码即 PSK。日志不得出现配对码、地址、剪贴板内容、按键、令牌或密钥。

**工程**

6. Windows 专有 API 只出现在 `windows/app`；协议、状态机、可在 macOS 上验证的算法放 `windows/core` 并写单元测试。会话逻辑通过 `HostPlatform` / `ViewerPlatform` 两个 trait 与平台隔离，`probe` 和回环测试各有一份假实现，**改 trait 时三处一起改**。
7. 优先成熟库，不手写基础设施（TLS/DTLS 用 OpenSSL，PNG、Opus 等用成熟 crate）。新增依赖后运行 `python3 scripts/check-cargo-lock-age.py`，发布不满 7 天的版本用 `cargo update -p <名字> --precise <旧版本>` 回退。`Cargo.lock` 必须提交，构建一律带 `--locked`。
8. 可执行文件只能依赖 Windows 自带的库（`build-windows.sh` 会检查导入表）；需要新的系统库时把它加进脚本里的允许列表并说明来源。
9. 代码风格：`cargo fmt`；`cargo clippy --locked --all-targets -- -D warnings` 在本机目标和 `--target x86_64-pc-windows-gnullvm -p quietdesk-app` 两处都要干净。注释写英文，只解释“为什么”。界面文字与错误提示用简体中文。

**流程**

10. 开工前看 `git status`。`AppChecks/MediaImpairmentChecks.swift` 的未提交修改、`.idea/`、`.vscode/` 是用户的，**不要改动、暂存或提交**。只按明确路径 `git add`，不用 `git add .` / `-A`。
11. 每个 WP 至少执行：Rust 测试、`run-windows-interop-checks.sh`、`run-windows-wine-checks.sh`、两处 clippy、`build-windows.sh`。涉及 macOS 源码时再跑 `scripts/run-all-checks.sh`。
12. 互通检查要跟着功能一起扩充：每个新能力至少各有一项“Mac 控制端 → Windows 被控端”和“Windows 控制端 → Mac 被控端”的检查，用真实的 macOS 类型（`MediaSession`、`CursorPresentationState`、`ClipboardTransfer` 等）而不是自己再写一遍协议。
13. 检查不得采集真实屏幕以外的敏感内容、不得注入真实输入、不得读写真实剪贴板、不得占用 5908 端口、不得启动或打断用户正在运行的 QuietDesk。
14. 提交信息沿用 `feat:` / `fix:` / `chore:` / `docs:`，英文，说明原因。一个 WP 一个功能提交，文档可另起一个 `docs:` 提交。提交后确认在本地 `main` 上。**不推送**。
15. 每个 WP 结束时更新：本文件状态表、`docs/windows.md`（面向用户的范围与限制）、`BUILD-AND-CHECKS.md`（顶部加一节：做了什么、跑了什么、结果、没验证什么）。
16. 中间文件放 `work/`，交付物放 `outputs/`。macOS 上没有 `timeout` 命令，只在容器里用。Wine 检查偶尔卡住时先 `docker ps` 找到本次启动的容器再结束它，不要动别的容器。

**命令速查**

```sh
source scripts/windows-toolchain.sh          # 准备交叉工具链并设置 CARGO_TARGET_DIR
(cd windows && cargo fmt && cargo clippy --locked --all-targets -- -D warnings)
(cd windows && cargo clippy --locked --target x86_64-pc-windows-gnullvm -p quietdesk-app --all-targets -- -D warnings)
./scripts/run-windows-interop-checks.sh      # 加 --rust-only 只跑 Rust 部分
./scripts/run-windows-wine-checks.sh         # 需要 Docker
./scripts/build-windows.sh                   # outputs/windows/QuietDesk-<版本>-Windows-x64.zip
python3 scripts/check-cargo-lock-age.py
```

## 4. 工作包

依赖关系：`WP1 → WP2`，`WP1 → WP9 → WP10`；WP3、WP4、WP5、WP6、WP7、WP8、WP11、WP12 相互独立，可在 WP1 之后任意顺序或并行（并行时注意都会改 `host.rs` / `viewer.rs` / `messages.rs`，按文件分工或串行合并）。建议顺序：WP0、WP1、WP2、WP3、WP4、WP5、WP7、WP6、WP8、WP9、WP11、WP10、WP12、WP13、WP14。理由：WP1+WP2 解决用户已经反馈的光标问题；WP3–WP5 是日常可用性；WP7 决定画面流畅度；之后是体量大的传输与外围功能。

每个 WP 的“完成标准”都隐含第 3 节第 11–15 条。

### WP0 实机确认编码器修复（用户执行）

背景：实机日志显示 `encoder option … was not accepted: 参数错误 (0x80070057)`，且首个关键帧在第 18 帧才输出。原因是低延迟参数在 `SetOutputType` 之后才设置而被忽略，系统编码器压住约 17 帧；被控端只在画面变化时出帧，于是每次光标移动都要再等十几次变化才显示。`e8b0508` 把参数提前、码率模式改为 CBR，并在编码器仍压帧时重复送入当前画面把它推出来。

确认方法：用最新的 `outputs/windows/…zip` 做一次 Mac 控制 Windows，查看 `%LOCALAPPDATA%\QuietDesk\logs\`：

- 不应再出现 `was not accepted`；
- `the stream opens with a keyframe of … bytes after 1 captured frames`；
- 不应出现 `the encoder holds N frames back`（出现说明低延迟仍未生效，需要把日志交给做 WP7 的 agent）。

即使修复生效，视频里的光标仍要经过采集、转换、编码、网络、解码才显示，Mac 上会同时看到本机箭头和稍后跟上的远端光标。彻底解决靠 WP2。

### WP1 媒体会话接入（控制连接上的 `shared` 路径）

当前实现用同一个锁保护采集许可、帧代次和待确认数量。被控端异步等待采集线程收到关键帧请求后才放行首帧。控制端按解码提交记录区分旧版和媒体帧确认，Windows 平台用输出样本的时间戳核对媒体帧。下文保留最初的实施步骤，接手 WP2 时以当前代码接口为准。

**目标**：Windows 两个角色都用 macOS 的媒体会话传视频（`mediaFrame` + `mediaFeedback`），仍只走控制连接。这是独立光标（WP2）的前提：macOS 控制端只有在媒体流提交之后才请求独立光标，macOS 被控端在媒体流准备之前收到光标请求会直接断开（“光标功能未协商”）。

**macOS 参考（已核实）**：`MediaSessionProtocol.swift`（`MediaControl` 与校验）、`MediaProtocol.swift`（`MediaFrame`、`MediaFeedback`）、`MediaSession.swift`（`start`、`receiveMessage`、`receiveControl`、`sendFrame`、`beginSwitch`、`startHostPreparation`、`commitViewerTransaction`、`handleReceiveEvents`、`receiveFeedback`、`requestRecovery`、`setPaused`、`suspendForConfiguration` / `resumeAfterConfiguration`）、`MediaReassembly.swift`（整帧的 `receive` / `decoded`、发送端 `handle`）、`SessionDataChannel.swift`（旧版 `video` 始终可收）。协议细节见附录 A.1–A.4。

**已有基础**：`windows/core/src/media.rs` 已实现并测试：

- `MediaFrame`、`MediaFeedback`、`MediaControl`（含校验、base64 的 `token` / `datagramKey`）。
- `HostMedia`：`control()`（处理 request/prepare/ready/decodedReady/committed/abort，返回 `HostMediaEvent::{Send, Prepare, ProduceKeyFrame, Settled}`）、`prepared()`、`preparing()`、`frame()`（返回 `HostFrame::{Legacy, Media, Dropped}`）、`feedback()`、`interrupted()`、`paused()`、`recovery()`、`gate()`、`has_stream()`。
- `ViewerMedia`：`request()`、`control()`、`frame()`、`decoded()`、`deadline()` / `tick()`、`set_paused()`、`active()`，事件 `ViewerMediaEvent::{Send, Video, Committed}`。
- 只支持 H.264；`fast`、UDP、辅助通道一律不协商。

**要做的事**

1. `messages.rs`：`Hello` 增加 `media_transport_v1: Option<bool>`（JSON 名 `mediaTransportV1`）。`Hello { .. }` 目前在 `host.rs`（announce）和 `messages.rs` 的测试里各构造一次。
2. `host.rs`
   - Hello 声明 `mediaTransportV1: true`。
   - `FrameSink` 增加闸门（建议 `Arc<AtomicU8>`，取值对应 `media::Gate::{Open, Closed, One}`）：`has_credit()` 在 `Closed` 时为假；`submit()` 在 `One` 时把闸门原子地改回 `Closed`。原因：macOS 的采集端在一次流切换里只产出**一个**关键帧，然后等 `committed` 才继续；如果编码器在关键帧之后又前进了而那些帧没有发出去，控制端后续的预测帧就会花屏。
   - `HostPlatform` 增加 `fn request_key_frame(&mut self)`：下一帧必须是当前屏幕的关键帧。
   - 收到 `mediaControl` → `HostMedia::control(&control, self.paused)`，按事件处理：`Send` 直接发；`Prepare` 表示新流开始准备——**流已经启动时**立刻调用 `prepared()` 并发送返回的 `ready`，**流还没启动时**（控制端的 `prepare` 可能早于首次 `start()`）留到 `start()` 成功之后再调用；`ProduceKeyFrame` → 先 `platform.request_key_frame()`，再把闸门设为 `One`（顺序不能反）；`Settled(n)` → 未确认帧计数减 n。收到 `prepare` 被接受时，旧版 `unacknowledged` 列表里剩下的帧也要清掉并从计数里减去。
   - 每次媒体状态变化后把 `HostMedia::gate()` 同步到闸门，但**只在期望值发生变化时写入**；唯一的例外是“闸门为 `One` 时收到的不是关键帧”（它在关键帧请求生效前就已编码）——丢弃该帧并重新写入 `One`。不要在无关事件后重复写 `One`，否则会放行第二帧。
   - 发送帧：`HostMedia::frame(sequence, frame)`：`Legacy` 走旧版 `video`（并记入 `unacknowledged`）；`Media` 直接发送；`Dropped` 把该帧从未确认计数里减去。计数必须精确增减，不要 `store(0)`（通道里还有在途帧时会下溢）。
   - 收到 `mediaFeedback` → `HostMedia::feedback()`：返回的数量从计数里减去，返回的控制消息发出去。
   - 流被重启时（画质调整引起的 `start()`、暂停后恢复）：重启**之前**调用 `interrupted()`，发送返回的 `abort` / `recover`，同步闸门；`start()` 会换新的计数器，所以那次返回的数量忽略；恢复暂停不换计数器，返回的数量要减去。首次 `start()`（`state` 为空）不要调用 `interrupted()`，否则会把等待中的事务取消掉。
   - 暂停：调用 `HostMedia::paused()` 并发送返回的 `abort`；暂停期间收到的 `prepare` 由 `control(.., paused = true)` 拒绝。
   - 提醒：闸门因 `hold` 关闭而控制端迟迟不发 `prepare` 时，每秒重发一次 `HostMedia::recovery()`（在 `select!` 里加一个定时分支）。
3. `viewer.rs`
   - Hello 带 `mediaTransportV1 == true` 时创建 `ViewerMedia` 并发送 `ViewerMedia::request()`（不带任何可选能力，对端因此不会启用 UDP、FEC、快速恢复等）。
   - `mediaControl` / `mediaFrame` 交给 `ViewerMedia`；`Video(packet)` 交给平台解码；`Committed(stream)` 转成新的 `ViewerEvent`（WP2 要用）。未协商媒体会话时收到这两类消息按现有规则断开。
   - 平台回报“已解码”的序号时先问 `ViewerMedia::decoded(sequence)`：返回 `Some` 就发送它给出的 `mediaFeedback`（以及首帧的 `decodedReady`）；返回 `None` 说明是旧版帧，照旧发 `acknowledgement`。旧版 `video` 必须继续接受——macOS 被控端在第一次 `prepare` 之前仍发旧版视频。
   - `select!` 里加定时分支：`ViewerMedia::deadline()` 到时调用 `tick()`（8 秒无应答放弃并重试、被拒绝后 0.5 秒重试）。
   - 暂停结果到达时调用 `set_paused(result.paused, now)`。
4. `windows/app`：`pipeline.rs` 增加 `Command::KeyFrame` → `Stream::restart_from_key_frame()`；`WindowsHost` 实现 `request_key_frame`。控制端解码与显示不变（每个流以带参数集的 IDR 开始，解码器的 `MF_E_TRANSFORM_STREAM_CHANGE` 已处理）。
5. `probe`：`ReplayHost::request_key_frame` 把回放位置拨回 0（录像以关键帧开头）；控制端角色输出流提交事件；`tests/loopback.rs` 的 `FakeHost` 同步实现。`probe` 的被控端在会话期间不接受其他连接，macOS 控制端的辅助连接会一直挂到它自己的 5 秒握手超时，会话结束后才被当作失败的握手报告出来；改成像 `app.rs` 的 `serve_host` 那样在会话期间直接关闭其他连接。
6. `AppChecks/WindowsInteropChecks.swift`
   - `MacViewer` 夹具改用真实的 `MediaSession.viewer(control:key:host:port:settings:)`：`onVideo` 里解码后 `completion(true)`，`onCommitStream` 记录提交；收到的消息先交给 `media.receive(_:)`，它不处理的再走原有分支（应用里的顺序见 `SessionDataChannel.receive`）。注意：macOS 控制端收到 offer 后会尝试两条辅助 TCP 连接，Windows 端拒绝后它等到 1.5 秒的回退时间才开始 `shared` 切换，所以检查里前 1.5 秒收到的是旧版视频，这是预期行为。
   - `MacHost` 夹具已经在用 `MediaSession.host`，需要补上应用里的回调：`onPrepareStream`（直接 `completion(true)`）、`onProduceRecoveryFrame`（只送一个关键帧）、`onResumeFrames`（恢复出帧）。夹具必须像真实采集端那样在事务期间**停止出帧**：`MediaSession.sendFrame` 在事务的 producing 阶段收到非关键帧会中止事务。
   - 新增检查：两个方向都提交了 `shared` 流；提交后的帧经 `mediaFrame` 到达且与编码器输出逐字节一致；`mediaFeedback(decoded)` 释放帧窗口（停止回报后恰好停在窗口上限）；画质调整、暂停恢复各触发一次新的流并从关键帧开始；旧版对端（不声明 `mediaTransportV1`）行为不变。

**完成标准**：上述检查通过；`run-windows-wine-checks.sh` 里 Windows↔Windows 也走媒体会话；`docs/windows.md` 把“画面”一行改为“媒体会话（TCP 兼容模式）”。

**风险**：闸门与采集线程之间的竞态（见第 2 点的写入规则）；帧计数泄漏会让画面在几次切换后永久变慢——回环测试里要在多次流切换后断言计数回到 0。

### WP2 独立光标（本地即时光标）

**目标**：Mac 控制 Windows 时，Windows 被控端不再把光标画进视频，而是单独发送形状与位置，Mac 用本机光标即时显示；Windows 控制 Mac 时，Windows 控制端用本机光标显示 Mac 的光标形状。

**macOS 参考（已核实）**：`CursorProtocol.swift`（`CursorControl`、`CursorImage`、`CursorShape`、`CursorPosition`、`CursorPresentationState`）、`DeskModel.swift` 的 `applyHostCursorRequest`、`sendCursorRequest`、`onPrepareStream` 里的 binding、`handleViewer` 的 `cursorControl` / `cursorShape` / `cursorPosition` 分支、`RemoteCanvas.swift` 的 `resetCursorRects` / `updateCursorPresentation`、`HostCursorSampler.swift`，以及 `docs/independent-cursor.md`。线格式与时序见附录 A.5。

**要做的事**

1. `windows/core/src/cursor.rs`（新）：三种消息的编解码与校验；`CursorPresentationState` 的移植（`status` / `bind` / `commit` / `update`，待处理绑定与缓存数量有限）；PNG 编解码用成熟 crate（如 `png`），**解码前先核对长度、IHDR 尺寸与声明一致**（与 `CursorImage.init` 相同）。单元测试用附录 A.5 的字节布局。
2. Hello：两个角色都处理 `independentCursorV1`；被控端在实现完成后声明它。先不声明 `initialCursorNegotiationV1`（那是把光标选择并入首个画质请求的优化，可留到以后）。
3. 被控端（`host.rs` + `app`）
   - 收到 `cursorControl`：只接受 `request`，且要求 `HostMedia::has_stream()`，否则按 macOS 的做法断开。
   - 处理顺序与 macOS 一致：`interrupted()`（暂停出帧）→ 让采集端切换“是否把光标画进画面” → 光标代次加 1、形状修订号与位置序号归零 → 发 `status`（带 `requestID`、本会话固定的 `cursorID`、`epoch`、`enabled`；失败时 `reason: unavailable`，暂停中 `waitingForResume`）→ 开始发送形状与位置 → 发 `recover` 让控制端开新流。
   - 之后每次 `HostMediaEvent::Prepare` 都在 `ready` **之前**发 `binding`（`cursorID`、`epoch`、`enabled`、`stream`）——用 `HostMedia::preparing()` 取流。
   - 平台侧：`HostPlatform` 增加设置光标是否画入画面的方法和一条光标更新通道。`pipeline.rs` 里桌面复制路径停止调用 `draw_pointer`；GDI 路径停止 `DrawIconEx`。光标采样用 `GetCursorInfo`（句柄变化即形状变化，`ptScreenPos` 为位置，未设 `CURSOR_SHOWING` 视为不在显示器内），频率不超过每秒 60 次，只在变化时发送。形状用 `GetIconInfo` + `GetDIBits`（或向 32 位 DIB 上 `DrawIconEx`）取 BGRA；单色与反色光标（如文本光标）没有 alpha，需要转换成可见的 ARGB（例如黑色加白边），在 `core` 里实现并测试。尺寸上限 256×256、PNG 不超过 256 KiB；`logicalWidth/Height` = 像素 ÷（DPI÷96），热点用同一单位。位置是共享显示器内的 0…1 比例。
4. 控制端（`viewer.rs` + `canvas.rs`）
   - 首次 `Committed` 之后，若 Hello 有 `independentCursorV1`，发送 `request(enabled: true)`；25 秒无 `status` 时关闭连接并按可重试处理（macOS 的做法：`armViewerCursorTimeout`）。
   - `status` / `binding` / 形状 / 位置进 `CursorPresentationState`；流提交时 `commit(stream)` 决定是否启用。
   - `canvas.rs`：启用且本机正在画面内操作时，`WM_SETCURSOR` 设置由 PNG 生成的 `HCURSOR`（`CreateIconIndirect`，按逻辑尺寸×本机 DPI 缩放，热点同步缩放），未知形状用系统箭头；其余情况（未控制、指针在画面外）在画面上按位置叠加绘制远端光标。未启用时保持现状（隐藏本机光标，看视频里的光标）。
5. 检查：互通检查两个方向各一项，Mac 侧用真实的 `CursorPresentationState` / `CursorShape.decode` / `CursorPosition.decode`，核对“启用恰好发生在绑定的那个流提交时”、形状像素与热点、位置；`probe` 的被控端提供合成光标。Wine 里只能验证不崩溃。

**完成标准**：检查通过；实机上 Mac 控制 Windows 时只看到一个光标且无延迟（需用户确认）；`docs/windows.md` 更新。

**风险**：动画光标与自定义光标；光标隐藏状态协议里没有专门表示；高 DPI 下的尺寸换算。

### WP3 控制端断线自动重连与空闲暂停

**macOS 参考**：`Reliability.swift` 的 `RetryBackoff` 依次等待 1、2、4、8、16、30 秒，之后保持 30 秒。`DeskModel` 在收到有效 Hello 且连接稳定满 30 秒后重置退避。控制端关闭自动重连、主动断开、配对失败或收到被控端主动结束通知时终止重试。`SessionIdlePolicy.swift` 在窗口连续失焦或不可见满 10 分钟后暂停，重新关注窗口时恢复。Windows 保留原有的最小化立即暂停。

**要做的事**：`core` 已经给出 `ViewerEnd { reason, host_ended, retryable }`。在 `app.rs` 给 `run_viewer` 外面加重连循环：`retryable && !host_ended` 时按退避重连，被控端主动结束、配对失败、用户断开都不重连；`canvas.rs` 保留窗口与最后一帧并在标题显示“第 n 次重连，x 秒后重试”，提供“立即重试 / 取消”；重连成功后恢复之前选择的画质。设置里加“自动重连”开关（默认开）。可选：按 `SessionIdlePolicy` 的规则在窗口长时间不被关注时暂停（现在只有最小化时暂停）。退避与“是否重连”的判定放在 `core` 并写测试。

**完成标准**：`probe` 控制端加重连模式，互通检查覆盖“被控端重启后自动恢复”“被控端主动结束后不重连”“配对码错误不重连”。

### WP4 多显示器

**macOS 参考**：`DisplaySelection.swift`（已核实结构：`RemoteDisplayInfo { id, name(≤96 字符), width, height, isMain }`，最多 16 个；`DisplayControl`（消息 37）操作 `subscribe` / `state` / `select` / `result`，字段 `id`、`displayID`、`selectedDisplayID`、`displays`、`videoState`、`error`）；Hello 的 `displaySwitchingV1`、`displays`、`selectedDisplayID`；`DeskModel` 中 `scheduleHostDisplayHotUpdate`、`hostRemoteDisplays` 与控制端对 `displayControl` 的处理（待核实校验规则与时序）。

**要做的事**

- 被控端：枚举显示器（DXGI 输出与 `EnumDisplayMonitors` 对应起来，稳定的 `id`），`ScreenCapture::open` 接受目标显示器；Hello 带显示器列表；处理 `subscribe`（之后显示器变化时推 `state`）和 `select`（切换采集、按新尺寸重启编码、回 `result` 带新的 `videoState`；失败时回原显示器并带 `error`）。媒体会话存在时切换属于“流被重启”，走 WP1 的 `interrupted()`。输入坐标已经按所采集显示器的矩形换算。主窗口加“共享哪个显示器”的选择。处理热插拔与分辨率变化（现在是直接结束流）。
- 控制端：远程窗口菜单列出对端显示器；发 `select`、处理 `result` / `state`、按新尺寸重建画面。

**完成标准**：互通检查两个方向各一项（Mac 侧用真实的 `DisplayControl`）；Wine 里只有一个显示器，多屏靠实机。

### WP5 输入补全

各项相互独立，可拆成多个小提交。全部待核实，入口如下。

- **输入状态回馈与 Caps Lock**：双向支持 `InputFeedback { message, capsLocked }`（消息 10）、`independentCapsLock`、`toggleCapsLock` 和 `switchInputSource`。用户选择用 `Win+空格` 切换 Windows 的下一输入法。被控端只有观察到大写或前台键盘布局变化后才确认成功，无法确认时提示重新点击输入位置。
- **相对鼠标**（`relativeMouseV1`）：`RemoteInput.pointerDeltaX/Y`、`pointerSequence`、`relativeMouse`；被控端用 `MOUSEEVENTF_MOVE` 相对移动；控制端用 Raw Input 加指针锁定。面向游戏/3D 软件，优先级低。
- **触控板手势**（`trackpadGesturesV1`）：`magnify` / `rotate` / `smartMagnify`。已实现。Windows 被控端在共享屏的前台目标上合成双触点。Windows 控制端通过 Direct Manipulation 读取精密触控板的捏合，在支持相应触摸消息的设备上还可发送旋转和智能缩放。
- **滚动相位**：`scrollPhase` / `momentumPhase` 已实现。Windows 控制端区分手指滚动、惯性和结束，按像素发送。普通滚轮保留原有行增量。
- **设备身份**（消息 21 `deviceIdentity`，Hello 的 `deviceID` / `deviceIdentityExchange`）：已实现。主机在 Hello 里带持久 UUID，控制端在协商后回复自己的 UUID 和设备名。同一会话允许改名，UUID 变化会结束连接。Windows 以设备 UUID 和已验证的配对码共同匹配跨地址记录。

### WP6 自动剪贴板，图片与文件

**macOS 参考（待核实，体量大）**：`ClipboardTransfer.swift`（1478 行，协议与传输）、`ClipboardStorage.swift`、`ClipboardFileResult.swift`、应用侧 `ClipboardSync.swift`（1478 行）与 `ClipboardFilePrompt.swift`；检查脚本 `run-session-data-checks.sh`、`run-file-result-checks.sh`。已确认的事实：Hello 能力位 `clipboardSync`；消息 11 `clipboardSettings`（`ClipboardPreference { enabled, session, fileApproval, receivesAutomaticUpdates, chunkWindow, decoupledFileTransfer, onDemandClipboard }`）、12–17 `clipboardBegin/Entry/Chunk/End/Receipt/Cancel`、41 `clipboardManifest`、42 `clipboardPull`；内容种类 `text` / `png` / `files`；自动同步上限文字 16 MiB、图片 64 MiB，文件条目上限 200 000；修订号 `ClipboardRevision { counter, origin }`。

**建议分两步**

1. 文字与图片自动同步：`AddClipboardFormatListener` 监听；文字 `CF_UNICODETEXT`；图片在 PNG 与 `CF_DIBV5` 之间转换；按清单/拉取（on-demand）流程实现，回环抑制（自己写入的内容不再回传）；界面开关沿用现有“允许控制端读写剪贴板文字”并扩展。
2. 文件：用户已选择在接收端实际粘贴时才开始传输。Windows 接收端使用 OLE 延迟渲染，发送端读取 `CF_HDROP`。用户已授权为此修改 macOS 源码，使 Windows 发往 Mac 时也从接收端请求粘贴内容开始传输。两端协商新能力后使用该行为，保留与旧客户端的兼容。保留文件接收确认、会话目录与提示，校验路径、文件名、大小和条目数，拒绝越界路径。

**完成标准**：互通检查用真实的 `ClipboardTransfer` 对接；不读写真实剪贴板（`probe` 用内存里的假剪贴板）。

### WP7 视频性能

实机反馈会集中在这里。各项可分别提交，全部需要实机数据（帧率、每帧耗时、CPU 占用）才能下结论；先在 `pipeline.rs` 加每秒一次的统计日志（采集/转换/编码耗时、出帧数、丢弃数）。

- **GPU 缩放与色彩转换**：桌面复制得到的纹理直接进 `ID3D11VideoProcessor`（BGRA→NV12 加缩放），不再回读到 CPU。未启用独立光标时光标合成仍需 CPU 路径或额外的 GPU 混合——建议 GPU 路径只在独立光标启用时使用，否则回退现有路径。
- **硬件编码**：`MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE…)`，异步 MFT（事件驱动 `METransformNeedInput` / `METransformHaveOutput`），`IMFDXGIDeviceManager` 传纹理，低延迟、CBR、无 B 帧、按需关键帧；失败或不支持时回退软件编码器并记录日志。各厂商驱动对按需关键帧和低延迟的支持不一，必须保留 `pipeline.rs` 里“关键帧请求被拒绝则重建编码器”的兜底。
- **HEVC**：Hello 的 `hevcVideoV1`；`StreamSettingsRequest.codec` / `chromaSubsampling` 与 `StreamSettingsResult.codec` / `chromaSubsampling`（已核实字段存在，协商规则待核实，见 `LiveVideoSettings.swift` 与 `DeskModel` 的画质处理）。Rust 的 `VideoPacket` 已支持 HEVC 的封装位与 VPS；`media.rs` 目前拒绝非 H.264，需要补上 HEVC 的 IDR 判定（NAL 类型 16–21 为关键帧，VPS/SPS/PPS 类型 32/33/34，见 `MediaProtocol.swift` 的 `containsIDR` 与 `hevcType`）。Windows 解码 HEVC 依赖系统是否装有 HEVC 视频扩展，要做能力探测，只在两端都可用时协商。
- **60 fps 以上**：Hello 的 `higherFrameRateVideoV1` / `preferredHigherFrameRateSettings`，`docs/high-frame-rate.md`。控制端上限目前写死 60（`viewer.rs` 的 `supported()` 与画质回复校验）。
- **码率自适应**（`adaptiveVideoV1`）：被控端接受仅码率的变更而不重启流（`ICodecAPI` 动态设置 `CODECAPI_AVEncCommonMeanBitRate`），并在媒体 `stats` 里上报编码耗时与投递延迟；控制端侧见 `ViewerQualityPolicy.swift`、`MediaPathPolicy.swift` 与 `docs/udp-tcp-transport.md` 的“画质上限与实际值”。待核实。

### WP8 远端声音

**macOS 参考（待核实）**：`RemoteAudio.swift`（已确认：`RemoteAudioControl`（消息 38）操作 `request` / `status`，字段 `requestID`、`enabled`、`epoch`、`sampleRate`、`channels`、`framesPerPacket`、`magicCookie`(≤256 字节)、`redundantOpus`、`error`(≤240 字符)；参数 48 kHz、双声道、每包 960 帧（20 ms）、目标码率 96 kbps；`RemoteAudioPacket`（消息 39）头 16 字节、标志位 `0x01` 表示带上一包的冗余负载；另有 `RemoteAudioJitterBuffer`、`AudioLossConcealer`）；应用侧 `RemoteAudioStream.swift`、`DeskModel.applyHostAudioRequest` / `setRemoteAudioEnabled`；Hello 的 `remoteAudioV1`。

**要做的事**：Opus 用 libopus（选能随源码静态构建并能用 llvm-mingw 交叉编译的 crate，先做一次交叉编译验证）。被控端：WASAPI 回环采集默认输出设备 → 重采样到 48 kHz 双声道 → Opus → `audioFrame`（走控制连接；UDP 就绪后可改走数据报）。控制端：解码 → 抖动缓冲 → WASAPI 播放。`magicCookie` 是 macOS 编码器给解码器的配置，Windows 作为编码端时该字段如何填写、macOS 解码端是否要求它，必须先读 `status` 的校验与 `OpusAudioDecoder` 再定。默认关闭，由控制端开启。

### WP9 辅助 TCP 通道与 UDP 视频

体量最大，建议拆成 9a–9e 逐步交付，每步都保持 `shared` 路径可用作回退。全部待核实，除特别注明外。

- **9a 辅助 TCP 视频通道**：同一端口上按 ALPN 区分连接（已核实：`quietdesk-control/1`、`quietdesk-media/1`、`quietdesk-bulk/1`、`quietdesk-mapping/1`，见 `MediaSecureTransport.swift`）。现在 `tls.rs` 的接受端只接受控制协议。新连接发 `bind { sessionID, role, token }`，被控端核对 offer 里发出的 `token`（`MediaBindingGrant`，已核实有效期 15 秒；重复绑定等其余规则见 `receiveBinding`）后回 `bound`；之后 macOS 控制端会立即选择 `tcp` 路径，不再等 1.5 秒。好处是视频与控制消息不再互相排队。参考 `MediaSession.receiveBinding` / `acceptAuxiliary` / `openAuxiliary`。`app.rs` 的 `serve_host` 目前在会话期间直接丢弃其他连接，需要改为按 ALPN 分流。
- **9b UDP 与 DTLS**：DTLS 1.2、`TLS_PSK_WITH_AES_128_GCM_SHA256`，密钥是 offer 里的 `datagramKey`（32 字节），身份是会话 UUID 的字符串（已核实：`prepareListener` 用 `identifier.uuidString`，即大写形式，并在会话的同一端口号上监听 UDP）。OpenSSL 支持 DTLS-PSK，需要一层把 UDP 数据报接到 `SslStream` 的适配并处理多对端分流。数据报首字节为类型（已核实）：1 探测（共 1024 字节：类型 + 16 字节随机数 + 填充）、2 应答（原样回送，首字节改 2）、3 分片、4 反馈、5 补传的分片、6 光标位置、7 交互输入、8 奇偶校验、9 音频包、10 分组 FEC、11 恢复请求。类型字节之后的记录不超过 1100 字节。先做握手、探测验证、分片与重组、基于 `nack` 的补传。参考 `MediaSession.startUDP` / `sendPing` / `verifiedUDP`、`MediaProtocol.swift` 的 `MediaFragment`、`MediaReassembly.swift`。
- **9c 前向纠错**：单包 XOR 奇偶校验（`MediaFrameParity`）与 Cauchy Reed-Solomon 分组 FEC（`ReedSolomonFEC.swift`、`MediaFrameFECShard`）。GF(256) 运算用成熟 crate 前先确认生成矩阵与 macOS 完全一致，否则只能照搬实现并用 macOS 生成的向量做测试。
- **9d 路径策略与发送节奏**：`MediaPathPolicy.swift`（1253 行：UDP 试用、回退、恢复）、`VideoSendPacing.swift`、动态帧窗口（`dynamicFrameWindow`，上限 24）、快速恢复（`fastRecovery`）。
- **9e 数据报上的交互数据**：光标位置（6）、指针移动（7）、音频（9），对应 `datagramInteractive` / `datagramAudio`。

**检查**：macOS 仓库已有 `run-media-session-checks.sh`、`run-media-transport-checks.sh`、`run-media-impairment-checks.sh`、`run-media-blackhole-checks.sh`，互通检查应复用其中的丢包与黑洞夹具。总体说明见 `docs/udp-tcp-transport.md`。

### WP10 自托管中继

**macOS 参考（待核实）**：`docs/relay-protocol.md`、`docs/relay.md`、`docs/relay-requirements.md`；`RelayProtocol.swift`、`RelayTLSChannel.swift`、`RelayNodeCertificate.swift`（证书固定）、`RelayHostRegistration.swift`、`RelayViewerBridge.swift`、`RelayForwarding.swift`、`RelayPeerPath.swift`（打洞）；Hello 的 `relayTransportV1` / `relayDeviceID`；仓库里的 `relay/` 服务端与 `run-relay-*-checks.sh`。Windows 端需要：中继设置界面、被控端注册、控制端经中继连接、UDP 封装与打洞。依赖 WP9。

### WP11 会话工具

相互独立，全部待核实。

- **模拟键入**（`typeTextV1`，消息 46/47）：`RemoteTextTyping.swift`（`TypeTextRequest` 最多 512 个字符）、`HostTextTyper.swift`。Windows 被控端用 `SendInput` 的 `KEYEVENTF_UNICODE`；“仅允许观看”时拒绝。
- **桌面操作**（`desktopActionsV1`，消息 35/36）：`RemoteDesktopAction` 为 `previousSpace` / `nextSpace` / `missionControl`。Windows 被控端可映射为 `Ctrl+Win+←/→` 与 `Win+Tab`；Windows 控制端在菜单里提供这三项。
- **被控端效果**（`sessionEffects`、`sessionLockV1`、`displayDimmingV1`，消息 22/23）：`SessionEffectsState { muted, privacy, lockOnDisconnect, dimBuiltInDisplay }`，`SessionEffects.swift`、`HostSessionEffects.swift`。Windows 对应：静音用 `IAudioEndpointVolume` 并保证会话结束或进程异常退出后恢复（macOS 用了独立的看门狗进程，值得照做）；黑屏遮罩用置顶黑色窗口加 `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`（Windows 10 2004 起）；断开后锁屏用 `LockWorkStation`；调暗内建屏幕可不做（不声明 `displayDimmingV1`）。
- **自动解锁**（`sessionUnlockV1`，消息 32/33，`SessionUnlock.swift`，密码最多 128 个字符）：在锁屏界面输入需要 WP13 的服务形态，在此之前不要声明。
- **画质探测**（`qualityProbeV1`，消息 40，`QualityProbeControl { id, enabled, durationSeconds 5…120 }`）：被控端在静止桌面上持续产生测试帧，供 macOS 的线路测速使用。优先级低。

### WP12 端口映射

**macOS 参考（待核实）**：`PortMapping.swift`、`PortMappingHost.swift`、`PortMappingViewer.swift`、应用侧 `PortMappingManager.swift`；消息 43–45；独立的 ALPN `quietdesk-mapping/1`，其 PSK 由配对码派生（已核实 `MediaSecureTransport.tlsParameters`：身份 `quietdesk-mapping-v1`，密钥为以配对码为密钥对该身份做 HMAC-SHA256）；`run-port-mapping-checks.sh`。属于独立功能，排在远程桌面主体之后。

### WP13 以系统服务运行

现在的被控端以当前用户身份运行，UAC 提示、锁屏、管理员窗口都无法采集和控制。要支持它们需要：以 LocalSystem 运行的服务、在活动会话里用 winlogon 令牌启动的采集/注入进程、输入桌面切换（`OpenInputDesktop` / `SetThreadDesktop`）、`SendSAS`、安装与卸载、开机自启。这是权限最高、安全影响最大的一项，**开工前把方案（进程模型、令牌来源、服务与界面之间的通信及其鉴权、卸载路径）写出来交用户确认**，不要直接实现。

### WP14 工程化

- **ARM64 包**：`aarch64-pc-windows-gnullvm` 目标，llvm-mingw 已包含对应工具；`build-windows.sh` 增加架构参数与导入表检查。
- **CI 与发布**：现有工作流只构建 macOS，且推送 `main` 即发布。Windows 构建接入 CI、是否随同发布、产物命名，需要用户决定。
- **代码签名**：需要证书，由用户提供；未签名时 SmartScreen 会提示。
- **安装与更新**：单文件运行之外是否提供安装包、开机自启、托盘图标、防火墙规则；应用内更新参见 `UpdateManifest.swift` 与 macOS 的更新流程。
- **检查接入**：把 `run-windows-interop-checks.sh` 接入 `run-all-checks.sh`（需要 Rust 工具链，先确认 CI 环境）。
- **macOS 端文案**：若干提示默认对端是 Mac。属于 macOS 源码改动，需单独授权并走 macOS 的全量检查。
- **局域网发现与网络唤醒**：`BonjourDiscovery.swift`、`WakeOnLAN.swift`，可选。

## 5. 实机验收清单

每完成一批 WP，请用户在真实 Windows 10/11 上按相关条目确认，并附 `%LOCALAPPDATA%\QuietDesk\logs\` 的日志。

1. 启动：SmartScreen 提示后可运行；主窗口在 100%/150%/200% 缩放下文字不被截断。
2. Windows 被控：防火墙提示；Mac 能连接；日志里采集方式是桌面复制而不是 GDI；首个关键帧在第 1 帧；静止画面不出帧、动态画面的实际帧率。
3. 输入：字母、数字、符号、方向键、功能键、修饰键组合；`⌘C` / `⌘V`；鼠标单击、双击、拖拽、右键、滚轮；多显示器与高 DPI 下点击位置准确；失去焦点后不残留按键。
4. Windows 控制：连接 Mac；画面清晰度与延迟；`Alt+Tab`、Win 键等系统快捷键发往 Mac；`Ctrl+Alt+Enter` 全屏、`Ctrl+Alt+Esc` 释放；最小化暂停与恢复；断开提示。
5. 配对码：重启后仍在（DPAPI）；“重新生成”后旧码失效。
6. WP2 之后：两个方向都只看到一个光标且跟手；形状随上下文变化（箭头、文本、手形、缩放）。
7. WP3 之后：被控端重启、网络切换后自动恢复；被控端主动结束后不重连。
8. 之后各 WP 把自己的实机条目补到这里。

## 附录 A 已核实的协议笔记

以下内容逐行对照过 macOS 源码，可直接作为实现依据；行号可能随 macOS 代码变化，以函数名为准。

### A.1 媒体记录的字节布局（`MediaProtocol.swift`）

- 公共头 37 字节：`0x514D`（u16）、版本 `1`（u8）、记录类型（u8）、会话 UUID 16 字节（RFC 4122 字节序）、`transportEpoch`（u32）、`codecEpoch`（u32）、`frameID`（u64）、标志（u8，1 = 关键帧，大于 1 非法）。全部大端。
- `MediaFrame`（消息 27，记录类型 1）：头 + 长度（u32）+ 恰好该长度的 `VideoPacket` 编码。上限为 16 MiB − 37 − 5。头里的关键帧标志必须等于“AVCC 中含 IDR NAL（类型 5，且 `nal_ref_idc` 非 0）”；关键帧必须带 SPS（首字节 `& 0x9F == 7`）与 PPS（`== 8`）；非关键帧不得带任何参数集。
- `MediaFeedback`（消息 28，记录类型 3）：头 + 种类（u8：1 已重组、2 已解码、3 已过期、4 请求补传）+ 范围个数（u8，≤64）+ 每个范围 4 字节；只有种类 4 带范围。整条不超过 1100 字节。
- 仅 UDP 使用：分片（记录类型 2：头 + `packetSequence` u64 + `frameBytes` u32 + 序号 u16 + 总数 u16 + 负载）、奇偶校验（4）、FEC 分片（5）。

### A.2 `MediaControl`（消息 26，JSON，`MediaSessionProtocol.swift`）

- `operation`：`request`、`offer`、`bind`、`bound`、`prepare`、`ready`、`decodedReady`、`commit`、`committed`、`abort`、`recover`、`stats`。
- 字段（除 `operation` 外都可缺省）：`sessionID`、`token`（32 字节，base64）、`datagramKey`（32 字节，base64）、`role`、`transactionID`、`transportEpoch`、`codecEpoch`、`path`（`udp` / `tcp` / `shared`）、`mediaFailure`（仅 abort/recover）、`encodeMilliseconds` / `encodeIdle` / `mappedTransfer` / `deliveryMilliseconds`（仅 stats）、`relayRouting` / `datagramInteractive` / `dynamicFrameWindow` / `parityFEC` / `blockFEC` / `datagramAudio` / `fastRecovery`（仅 request/offer）、`receiveFrameWindow` / `markedRepairs` / `fecFragmentLimit`（仅 request）、`fast`（仅 prepare）。
- `request` 不得带会话与事务字段；`offer` 必须带 `sessionID`、`token`、`datagramKey`；事务类操作必须带 `sessionID`、`transactionID`、两个 epoch 与 `path`；`recover` 带 `sessionID` 与两个 epoch。
- Swift 的 JSON 编码省略空字段；UUID 为大写字符串（解码大小写均可）；`Data` 为 base64。

### A.3 流的建立与切换（`MediaSession.swift`）

控制端主导。每一步都带 `sessionID`、`transactionID`、`transportEpoch`、`codecEpoch`、`path`：

1. 控制端 `request` → 被控端生成会话 UUID、32 字节令牌与 32 字节数据报密钥，回 `offer`（`path` 为 `udp` 或 `tcp`，只重复已协商的可选能力）。
2. 控制端 `prepare`（两个 epoch 各加 1，从 1 开始）→ 被控端要求 epoch 都比已有的新、未暂停、路径可用，否则回 `abort`；接受后暂停出帧并准备。
3. 被控端 `ready` → 控制端建立该流的接收状态并回 `ready`。
4. 被控端产出**一个**关键帧，作为该流的 `frameID` 1 发出，然后停止出帧。
5. 控制端解码后发 `mediaFeedback(decoded)` 与 `decodedReady` → 被控端回 `commit` → 控制端回 `committed` 并开始显示 → 被控端恢复出帧，`frameID` 递增。

要点：

- 协商完成但还没有任何流时，被控端仍发旧版 `video`（`sendFrame`），控制端必须照旧接收并用旧版 `acknowledgement` 确认。
- macOS 控制端收到 offer 后先尝试辅助 TCP 连接，等不到就在 1.5 秒后选 `shared`；offer 的 `path` 为 `tcp` 时它不再尝试 UDP。
- 任一方 `abort` 取消同一事务；控制端 0.5 秒后重试；控制端 8 秒收不到应答自行放弃并重试。
- 被控端需要新流时（配置变化、暂停后恢复、对端报告帧过期）发 `recover`（带当前流的两个 epoch），控制端随即发起新的 `prepare`。请求间隔不小于 0.25 秒。
- 暂停：正在进行的事务被取消且不重试；恢复时双方都会触发新流。
- 事务期间被控端收到非关键帧会中止事务（`sendFrame`），所以采集端在事务里只能送一个关键帧。
- 不协商 `fastRecovery` 就不会出现缩短的恢复流程。

### A.4 整帧（TCP）下的可靠性语义（`MediaReassembly.swift`）

- 控制端：帧到达即回“已重组”，严格按 `frameID` 顺序逐帧解码，解码成功回“已解码”；流的第一帧必须是关键帧；收到比期望更旧的帧时重发上一帧的“已解码”。
- 被控端：“已解码”是累计确认，结算所有 `frameID` 不大于它的帧并释放帧窗口；“已重组”只延长期限；TCP 帧 5 秒未被结算即过期并触发恢复。
- 帧窗口：旧版为 3；`request` 里的 `receiveFrameWindow` 可声明更大的窗口（macOS 控制端声明 6），`dynamicFrameWindow` 协商后最多 24。

### A.5 独立光标（`CursorProtocol.swift`、`DeskModel.swift`、`RemoteCanvas.swift`）

- `CursorControl`（消息 29，JSON）：`operation`（`request` / `status` / `binding`）、`requestID`、`cursorID`、`epoch`、`enabled`、`stream { sessionID, transportEpoch, codecEpoch }`、`reason`（`unavailable` / `waitingForResume`）。`request` 只带 `requestID` 与 `enabled`；`status` 必带 `requestID`、`cursorID`、`epoch > 0`，不带 `stream`；`binding` 必带 `cursorID`、`epoch > 0`、`stream`（两个 epoch 都大于 0），不带 `requestID` 与 `reason`。
- 形状与位置的公共头：`43 55 01`、种类（1 形状，2 位置）、`cursorID` 16 字节、`epoch`（u32，>0）、序号（u64，>0；形状为修订号，位置为序号）。
- `CursorShape`（消息 30）：头 + 是否已知（u8，0/1）；已知时再跟像素宽、高（各 u16，1…256）、四个 f64 位模式（逻辑宽、逻辑高、热点 X、热点 Y；逻辑尺寸 0.5…256，热点在逻辑尺寸之内）、PNG 长度（u32）与 PNG（33 字节…256 KiB，IHDR 尺寸必须与声明一致）。整条不超过 256 KiB + 80 字节，不得有多余数据。未知形状表示“通用指针”，不是隐藏。
- `CursorPosition`（消息 31）：恰好 49 字节：头 + 是否在显示器内（u8）+ x、y（f64，0…1）。
- 控制端状态（`CursorPresentationState`）：`status` 只在 `epoch` 增大时接受并清空形状与位置；`binding` 记录“某个流对应的光标模式”，该流提交时才生效；形状与位置只接受 `cursorID` 与 `epoch` 匹配且序号递增的更新。
- 被控端处理请求的顺序：暂停媒体配置 → 切换采集是否包含光标 → `epoch` 加 1、序号归零 → 发 `status` → 开始采样并发送形状与位置 → 恢复媒体（触发 `recover`）→ 在随后的每次流准备里、`ready` 之前发 `binding`。
- 控制端在**第一个媒体流提交之后**才发请求；25 秒未确认则关闭连接并按可重试处理。
- macOS 控制端的呈现：模式启用且正在画面内操作时，本机光标换成远端形状（只有一个光标）；否则在画面上按位置叠加远端光标；未启用时显示本机箭头，远端光标在视频里。
- 被控端采样间隔为 1/60 秒（`startHostCursorSampler`），只在位置或形状变化时发送。控制端移动事件的合并节奏见 `PointerMovePacing.swift` 与 `docs/independent-cursor.md`（未逐行核对）。

## 附录 B macOS 源码索引

| 主题 | 协议与逻辑（`Sources/QuietDeskCore`） | 应用侧（`Sources/QuietDesk`） |
| --- | --- | --- |
| 连接与帧 | `Transport.swift`、`Protocol.swift` | `DeskModel.swift`（`accept`、`handleHost`、`handleViewer`） |
| 画质协商 | `LiveVideoSettings.swift`、`ViewerQualityPolicy.swift` | `DeskModel.swift`、`SessionQualityView.swift` |
| 视频编解码 | `Video.swift`、`VideoDecoder.swift`、`VideoSendPacing.swift` | `Capture.swift` |
| 媒体会话 | `MediaSession.swift`、`MediaSessionProtocol.swift`、`MediaProtocol.swift`、`MediaReassembly.swift`、`MediaPathPolicy.swift`、`MediaSecureTransport.swift`、`ReedSolomonFEC.swift` | `DeskModel.swift`、`SessionDataChannel.swift` |
| 光标 | `CursorProtocol.swift` | `HostCursorSampler.swift`、`RemoteCanvas.swift`、`PrivacyCursorHider.swift` |
| 输入 | `Protocol.swift`（`RemoteInput`）、`Keyboard.swift`、`PointerMovePacing.swift`、`ScrollAccumulator.swift`、`SystemShortcutRouting.swift` | `Capture.swift`（`InputInjector`）、`RemoteCanvas.swift`、`CapsLockMonitor.swift`、`InputSources.swift` |
| 显示器 | `DisplaySelection.swift` | `DeskModel.swift` |
| 剪贴板 | `ClipboardTransfer.swift`、`ClipboardStorage.swift`、`ClipboardFileResult.swift` | `ClipboardSync.swift`、`ClipboardFilePrompt.swift` |
| 声音 | `RemoteAudio.swift` | `RemoteAudioStream.swift` |
| 暂停、结束、重连 | `SessionIdlePolicy.swift`、`SessionTermination.swift`、`Reliability.swift` | `DeskModel.swift` |
| 会话工具 | `SessionEffects.swift`、`SessionUnlock.swift`、`DesktopActions.swift`、`RemoteTextTyping.swift` | `HostSessionEffects.swift`、`HostScreenUnlocker.swift`、`HostTextTyper.swift` |
| 中继 | `Relay*.swift` | `RelaySettingsView.swift`、`DeskModel.swift` |
| 端口映射 | `PortMapping*.swift` | `PortMappingManager.swift` |
| 其他 | `BonjourDiscovery.swift`、`WakeOnLAN.swift`、`UpdateManifest.swift`、`RouteQualityBenchmark*.swift` | 对应的视图与控制器 |

相关说明文档：`docs/udp-tcp-transport.md`、`docs/independent-cursor.md`、`docs/high-frame-rate.md`、`docs/caps-lock-confirmation.md`、`docs/relay-protocol.md`、`docs/security.md`。

## 附录 C 消息编号与 Windows 端现状

| 编号 | 名称 | Windows 端 |
| --- | --- | --- |
| 1–6 | hello、video、acknowledgement、input、ping、pong | 已实现 |
| 7–9 | clipboard、requestClipboard、releaseInput | 已实现（手动文字剪贴板） |
| 10 | inputStatus | WP5 已接入键盘动作状态回馈 |
| 11–17 | clipboardSettings、clipboardBegin/Entry/Chunk/End/Receipt/Cancel | WP6 |
| 18–20 | streamSettingsRequest、streamSettingsResult、controlStatus | 已实现 |
| 21 | deviceIdentity | WP5 已实现，控制端在支持交换的已配对连接中发送 |
| 22–23 | sessionEffectsRequest、sessionEffectsResult | WP11 |
| 24–25 | sessionPauseRequest、sessionPauseResult | 已实现 |
| 26–28 | mediaControl、mediaFrame、mediaFeedback | WP1 已接入两个角色的控制连接 |
| 29–31 | cursorControl、cursorShape、cursorPosition | WP2 已接入两个角色的控制连接 |
| 32–33 | sessionUnlockRequest、sessionUnlockResult | WP11（依赖 WP13） |
| 34 | sessionTermination | 已实现 |
| 35–36 | desktopActionRequest、desktopActionResult | WP11 |
| 37 | displayControl | WP4 已接入两端的屏幕选择与状态更新 |
| 38–39 | audioControl、audioFrame | WP8 |
| 40 | qualityProbeControl | WP11 |
| 41–42 | clipboardManifest、clipboardPull | WP6 |
| 43–45 | mappingControl、mappingData、mappingEOF | WP12 |
| 46–47 | typeTextRequest、typeTextResult | WP11 |

Hello 能力位（`Protocol.swift` 的 `Hello`）与对应 WP：`inputActions`（WP5）、`clipboardSync`（WP6）、`deviceID` / `deviceIdentityExchange`（WP5）、`sessionEffects` / `sessionLockV1` / `displayDimmingV1` / `builtInDisplayDimmable`（WP11）、`mediaTransportV1`（WP1）、`independentCursorV1` / `initialCursorNegotiationV1`（WP2）、`relayTransportV1` / `relayDeviceID`（WP10）、`adaptiveVideoV1` / `higherFrameRateVideoV1` / `preferredHigherFrameRateSettings` / `hevcVideoV1` / `hevc444VideoV1`（WP7）、`sessionUnlockV1` / `screenLocked`（WP11）、`desktopActionsV1` / `typeTextV1` / `qualityProbeV1`（WP11）、`displaySwitchingV1` / `displays` / `selectedDisplayID`（WP4）、`remoteAudioV1`（WP8）、`relativeMouseV1` / `trackpadGesturesV1`（WP5）。已实现并声明的见 2.1 节。
