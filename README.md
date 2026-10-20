# QuietDesk

**简体中文** · [English](README.en.md)

原生 macOS 远程桌面，让两台 Mac 共用一张书桌。无需账号或中转服务，支持局域网直连与自行配置的公网连接。

**macOS 14+ · Apple 芯片与 Intel · MIT**

[下载发行版](https://github.com/nXiaoK/QuietDesk/releases/latest) · [构建状态](https://github.com/nXiaoK/QuietDesk/actions) · [使用指南](docs/usage.md)

> 以下功能与截图对应当前源码，已发布安装包以 Releases 为准。截图使用演示数据，应用界面目前为中文。

![连接与最近使用的设备](docs/images/connection.png)

## 功能

| 功能 | 说明 |
| --- | --- |
| 远程控制 | 鼠标、键盘、拖拽、滚动与全屏悬浮设置 |
| 自托管中继 | 单节点全会话转发，设备标识连接；支持直连控制与中继视频分开选择 |
| 视频传输 | 新版双方优先加密 UDP，自动恢复或回退 TCP，键鼠控制始终可靠传输 |
| 即时光标 | 新版双方分离视频与光标，减少移动时的双指针跟随；支持关闭 |
| 画质调节 | 手动选择作为新版自动调节上限；帧率上限 60 fps、目标码率最高 100 Mbps |
| 复制粘贴 | 文字与图片按焦点同步；文件和文件夹逐次确认后传输 |
| 键盘与权限 | 全屏系统快捷键、Caps Lock 切换输入法、拖拽应用图标授权引导 |
| 连接与省流 | 最近连接、断线重连、10 分钟空闲暂停，返回窗口恢复 |
| 后台共享 | 登录后启动、后台共享、显示器变化自动恢复 |
| 应用内更新 | 配置签名更新源后，按需检查、下载校验、确认安装与重启 |
| 地址流量 | 按网址/IP＋端口累计发送与接收，不同地址或端口分别统计 |
| 会话设置 | 被控端静音与屏幕黑色遮罩，默认关闭；开启后记住，新连接自动开启 |

<details>
<summary>展开更多功能截图</summary>

| 共享与后台设置 | 全屏控制 |
| --- | --- |
| <img src="docs/images/sharing.png" width="420" alt="共享端的权限、显示器和后台设置"> | <img src="docs/images/fullscreen.png" width="420" alt="全屏画面与悬浮控制菜单"> |
| **画质与连接** | **文件接收确认** |
| <img src="docs/images/quality.png" width="420" alt="原分辨率、60 fps 与 100 Mbps 设置"> | <img src="docs/images/clipboard.png" width="420" alt="文件名称、大小及接收确认"> |
| **键盘与快捷键** | **历史流量（截图为旧版界面）** |
| <img src="docs/images/keyboard.png" width="420" alt="系统快捷键与 Caps Lock 设置"> | <img src="docs/images/traffic.png" width="420" alt="历史流量（旧版按设备统计界面）"> |
| **静音与黑屏遮罩** | **空闲暂停** |
| <img src="docs/images/effects.png" width="420" alt="被控端静音与软件黑屏遮罩开关"> | <img src="docs/images/idle.png" width="420" alt="空闲暂停与恢复画面入口"> |
| **拖拽授权引导** | |
| <img src="docs/images/permissions.png" width="420" alt="将应用图标拖入系统权限列表的引导"> | |

截图展示界面与演示状态，不代表真实双机性能或权限测试。

</details>

## 快速开始

1. 两台 Mac 均安装 QuietDesk，并先移到“应用程序”。
2. **被控 Mac**：选择“共享这台 Mac”，授予屏幕录制和辅助功能权限，开启共享并复制配对码。
3. 需要免 Mac 入站映射时，可先通过 [Docker 单命令部署中继](relay/README.md#docker-单命令部署推荐)，再按[中继指南](docs/relay.md)使用设备标识连接；原有直连步骤如下。
4. **控制 Mac**：填写被控端地址、端口和配对码后连接。局域网直接填内网 IP，默认端口 `5908`；公网映射需将同一个外部端口的 TCP、UDP 都转发到被控端同一个监听端口。只有 TCP 可达时自动使用 TCP。
5. 点按画面开始操作。`⌃⌥Esc` 释放控制，`⌃⌘F` 切换全屏；系统快捷键与 Caps Lock 功能还需控制端的辅助功能、输入监控权限。

配对码等同控制凭据，请仅通过可信渠道传递。[权限与常见问题 →](docs/usage.md#permissions)

## 更新应用

首次安装带更新器的版本仍需从 [Releases](https://github.com/nXiaoK/QuietDesk/releases/latest) 手动下载。当前仓库的更新公钥表为空，应用内更新入口保持关闭；维护者配置公钥并发布后，才会启用此功能。

启用后，首次启动会询问是否自动检查；同意后每天最多自动检查一次，不会自动下载或安装。也可从应用菜单或菜单栏选择“检查更新…”。下载显示实际进度，校验完成后仍需确认“安装并重新启动”。这台 Mac 正被远程控制时不能安装；无法替换应用时提供手动安装入口。[更新与权限说明 →](docs/usage.md#应用内更新)

发布版继续使用临时签名，**每次更新后都需要在本机重新授予屏幕录制、辅助功能和输入监控权限**，请安排能在被控 Mac 本机操作时更新。

## 需要知道

- 新功能需两端支持；一次共享一个显示器、接受一个控制连接。不传输声音，也不支持登录窗口或 FileVault 解锁。
- 原分辨率仍使用有损 H.264；实际帧率受设备与网络影响。黑屏为软件遮罩，不保证覆盖系统安全界面等内容。[安全与边界 →](docs/security.md)
- “画质与连接”显示实际传输方式和生效画质，可选择“仅使用 TCP（下次连接生效）”。界面 RTT 是控制链路往返时间，FPS 也不等于实际上屏帧率。[UDP/TCP 传输说明 →](docs/udp-tcp-transport.md)
- 默认构建使用临时签名，未经过 Apple 公证；授权后可能需重开，每次更新后需要重新授权，以应用检测到的实际状态为准。

## 文档与开发

[详细使用](docs/usage.md) · [UDP/TCP 传输](docs/udp-tcp-transport.md) · [自托管中继](docs/relay.md) · [安全说明](docs/security.md) · [构建与检查](docs/development.md)

已安装 Apple 命令行开发工具、Swift 5.9+ 和 Python 3 后，可在仓库中构建：

```sh
./build-app.sh universal
```

输出：`dist/QuietDesk.app`。采用 [MIT 许可证](LICENSE)。
