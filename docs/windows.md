# Windows 版（第一版）

QuietDesk for Windows 让 Mac 可以远程控制 Windows 电脑，也让 Windows 电脑可以远程控制 Mac。它是独立的原生 Win32 程序（Rust 编写，单个 `QuietDesk.exe`，不需要安装运行库），与 macOS 版使用同一套配对码和基线协议，**macOS 版无需改动或升级即可互通**。

> 这一版在 macOS 上交叉编译，并经过与 macOS 实现的回环互通检查和 Wine 下的冒烟检查，**尚未在真实 Windows 电脑上运行过**。首次实机使用请按文末“实机验收”逐项确认，遇到问题请附上日志。

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

远程窗口获得键盘焦点后，`Alt+Tab`、Win 键等系统快捷键也会发往 Mac。`Ctrl+Alt+Enter` 切换全屏，`Ctrl+Alt+Esc` 释放控制（之后点击画面继续）。窗口菜单可发送或获取剪贴板文字、切换画质、断开连接；最小化窗口时会暂停画面传输，还原后恢复。

## 这一版包含与不包含

| 包含 | 说明 |
| --- | --- |
| 配对与加密 | 与 macOS 版相同的 TLS 1.2 / PSK / AES-128-GCM，配对码通用 |
| 画面 | H.264，经控制连接传输（macOS 版称为“TCP 兼容模式”）；被控端不变化时不出帧 |
| 画质 | 控制端可调分辨率、帧率（最高 60 fps）与码率；Windows 被控端另有“画质上限” |
| 键鼠 | 键盘、鼠标移动/点击/拖拽/双击、滚轮与触控板滚动、侧键；失去焦点时释放按键 |
| 其他 | 被控端“允许控制”开关即时生效、手动文字剪贴板、空闲暂停、被控端结束通知 |

暂不包含（对端提供时也不会启用）：UDP 视频与前向纠错、自托管中继、独立光标、远端声音、自动剪贴板与图片/文件传输、多显示器切换、HEVC、端口映射、模拟键入、自动解锁、黑屏遮罩与静音、断线自动重连、应用内更新。

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

- 互通检查用 Windows 端的同一份协议代码（`windows/core`，经无界面的 `quietdesk-probe`）对接本机的 `Peer`、`Hello`、画质协商、VideoToolbox 编解码、`MediaSession` 与输入注入器：配对、能力字段、三帧确认窗口、画质调整与失败回退、暂停恢复、键位与修饰键、点击计数、滚轮、剪贴板文字、结束通知、错误配对码。不采集屏幕、不注入真实输入、不使用 5908 端口。
- Wine 检查运行交叉编译出的 Windows 程序本身：GDI 采集、Media Foundation 编码与解码、Windows 被控端与 Windows 控制端互连出画。Wine 的桌面复制未实现、编解码由 GStreamer 提供，**不等同于 Windows 自带组件的行为**。

## 实机验收（尚未进行）

以下只能在真实 Windows 电脑上确认：桌面复制采集与光标绘制、系统 H.264 编码器的低延迟与按需关键帧、解码与 Direct2D 显示、`SendInput` 键鼠与高 DPI/多显示器坐标、键盘钩子与全屏、防火墙提示、DPAPI 读写、界面在不同缩放比例下的排版，以及两个方向的实际延迟与帧率。
