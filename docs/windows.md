# Windows 版

QuietDesk for Windows 让 Mac 可以远程控制 Windows 电脑，也让 Windows 电脑可以远程控制 Mac。它是独立的原生 Win32 程序（Rust 编写，单个 `QuietDesk.exe`，不需要安装运行库），与 macOS 版使用同一套配对码和基线协议，**macOS 版无需改动或升级即可互通**。

> 第一版已在 Windows 被控端试用。此次更新的独立光标、控制连接上的媒体会话及编码器启动延迟仍待 Windows 10/11 实机确认。

## 获取

```sh
./scripts/build-windows.sh
```

在 macOS 上生成 `outputs/windows/QuietDesk-<版本>-Windows-x64.zip`（内含 `QuietDesk.exe` 与许可证）及其 SHA-256。首次运行会下载固定版本并校验过摘要的 llvm-mingw 交叉工具链到 `work/toolchains/`。程序面向 Windows 10 / 11 x64，只依赖系统自带的库；未做代码签名，首次运行时 SmartScreen 可能提示“未知发布者”。

## Mac 控制 Windows

1. 在 Windows 上运行 `QuietDesk.exe`，在“共享这台电脑”中点“开始共享”。首次共享会生成配对码；Windows 防火墙询问时请允许访问。
2. 在 Mac 的 QuietDesk 中填写这台电脑的地址、端口（默认 `5908`）和配对码后连接，与连接另一台 Mac 的步骤相同。

Mac 键盘的修饰键可在 Windows 端“Mac 键盘”中选择：

| 选项 | ⌘ | ⌃ | ⌥ | 右 ⌘ |
| --- | --- | --- | --- | --- |
| ⌘ 与 ⌃ 都作为 Ctrl（默认） | Ctrl | Ctrl | Alt | Win 键 |
| 标准 | Win 键 | Ctrl | Alt | Win 键 |

默认选项让 `⌘C`、`⌘V` 等 Mac 习惯直接对应 `Ctrl+C`、`Ctrl+V`。其余按键按键位对应，字符由 Windows 当前的键盘布局决定。Mac 上的 F13 / F14 / F15 对应 Print Screen / Scroll Lock / Pause。

## Windows 控制 Mac

1. 在被控 Mac 上按原有步骤开启共享并复制配对码。
2. 在 Windows 的“控制另一台电脑”中填写地址、端口和配对码后点“连接”。连接成功后会记入“最近连接”，配对码用当前 Windows 账户加密保存（DPAPI）。

PC 键盘的修饰键可在“键盘”中选择：

| 选项 | Ctrl | Alt | Win 键 |
| --- | --- | --- | --- |
| 标准（默认，与 Apple 对 PC 键盘的约定一致） | ⌃ | ⌥ | ⌘ |
| 左 Ctrl 作为 ⌘ | 左 Ctrl 为 ⌘，右 Ctrl 仍为 ⌃ | ⌥ | ⌘ |

远程窗口获得键盘焦点后，`Alt+Tab`、Win 键等系统快捷键也会发往 Mac。`Ctrl+Alt+Enter` 切换全屏，`Ctrl+Alt+Esc` 释放控制，点击画面可继续。窗口菜单可发送或获取剪贴板文字、切换画质和断开连接。

主窗口的“断线后自动重连”默认开启。网络中断时，远程窗口保留最后一帧，标题显示第几次重试和剩余时间。可以在窗口中点“立即重试”或“取消重连”。重新连接后沿用上次选择的画质。配对码错误、自己断开或收到被控端主动结束通知时，会话结束。

远程窗口最小化时立即暂停画面。窗口连续十分钟处于后台也会暂停，返回窗口时恢复。暂停传输需要被控端支持会话暂停。

## 这一版包含与不包含

| 包含 | 说明 |
| --- | --- |
| 配对与加密 | 与 macOS 版相同的 TLS 1.2 / PSK / AES-128-GCM，配对码通用 |
| 画面 | H.264 媒体会话（TCP 兼容模式）。支持该能力的两端通过现有加密控制连接传输视频，确认新流的首个关键帧后继续出帧。与旧版连接时自动使用原视频协议 |
| 光标 | 两端都支持时，Windows 控制端在首个视频流提交后请求独立光标。操作画面时本机显示远端指针形状；仅观看时在画面上叠加远端位置。连接旧版或协商失败时沿用实际的采集模式 |
| 画质 | 控制端可调分辨率、帧率（最高 60 fps）与码率；Windows 被控端另有“画质上限” |
| 键鼠 | 键盘、鼠标移动/点击/拖拽/双击、滚轮与触控板滚动、侧键；失去焦点时释放按键 |
| 其他 | 断线自动重连、空闲暂停、被控端结束通知、允许控制开关即时生效、手动文字剪贴板 |

暂不包含（对端提供时也不会启用）：UDP 视频与前向纠错、自托管中继、远端声音、自动剪贴板与图片/文件传输、多显示器切换、HEVC、端口映射、模拟键入、自动解锁、黑屏遮罩与静音、应用内更新。

这些功能的实施顺序、协议依据与验收方法见 [Windows 版后续实施方案](windows-plan.md)。

Windows 被控端的已知限制：

- 只共享主显示器。显示器旋转或桌面复制不可用时改用 GDI 采集，占用更高。
- 以当前用户身份运行：UAC 提示、锁屏和以管理员身份运行的窗口无法被控制，出现这些界面时画面会暂停更新。
- 缩放与色彩转换在 CPU 上进行，使用系统自带的软件 H.264 编码器；4K 屏幕缩小后 60 fps 可能达不到，实际帧率会自动降低。
- Windows N / KN 版需先安装“媒体功能包”，否则没有 H.264 编解码器。

## 日志

`%LOCALAPPDATA%\QuietDesk\logs\quietdesk*.log`（按大小轮转，保留 3 份）。日志不记录配对码、地址、剪贴板内容或按键。设置保存在 `%APPDATA%\QuietDesk\settings.json`。

## 检查

```sh
./scripts/run-windows-interop-checks.sh   # Windows 端协议代码 ↔ macOS 实现，回环 TLS，双向
./scripts/run-windows-wine-checks.sh      # Windows 可执行文件在 Wine 容器中的冒烟检查，需要 Docker
```

- 互通检查用 Windows 协议代码对接 macOS 的 `Peer`、VideoToolbox、`MediaSession` 和光标协议实现，覆盖双向建流、视频内容、确认窗口、画质切换、暂停恢复及旧版兼容。合成光标用于核对透明像素、逻辑尺寸、热点、位置和生效时机。
- Wine 检查运行 Windows 可执行文件，覆盖 GDI 采集、Media Foundation 编解码、原生光标像素和热点，以及 Windows 双端互连。Wine 使用虚拟桌面和 GStreamer，系统编码器和显卡驱动的实际表现须在 Windows 上验证。

## 实机验收

用 Mac 控制 Windows，再用 Windows 控制 Mac。每个方向先确认静止桌面有首帧，再打开会持续变化的窗口、切换一次分辨率、暂停并恢复，确认画面都能继续更新。

- Mac 控制 Windows 时，在 Windows 日志中查找 `host committed shared media stream`。首个关键帧日志里的 `after 1 captured frames` 可用于核对编码器启动时机。
- Windows 控制 Mac 时，查找 `viewer committed shared media stream`。两个方向都应在建流、分辨率切换和恢复后看到对应角色的提交记录，后两次记录里的代次应递增。
- 用 Mac 控制 Windows，在文本框、链接和窗口边缘之间移动鼠标，确认只看到一个跟手的指针，形状和点击热点随上下文变化。反向连接时，在 Windows 的 100%、150%、200% 缩放下复查热点，并在释放控制、指针移出画面、暂停和恢复后检查远端指针位置。
- 用 Windows 连接 Mac，选择画质后临时中断网络再恢复。观察同一窗口中的倒计时和恢复后的画质，再分别验证“立即重试”、取消、主窗口关闭自动重连和被控端主动结束。

以下只能在真实 Windows 电脑上确认：桌面复制采集与光标绘制、系统 H.264 编码器的低延迟与按需关键帧、解码与 Direct2D 显示、`SendInput` 键鼠与高 DPI/多显示器坐标、键盘钩子与全屏、防火墙提示、DPAPI 读写、界面在不同缩放比例下的排版，以及两个方向的实际延迟与帧率。
