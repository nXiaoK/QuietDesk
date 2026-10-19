# 开发指南

[返回首页](../README.md) · [历史构建记录](../BUILD-AND-CHECKS.md) · [审查修复记录](review-fixes.md) · [配对码文件存储](local-credentials.md) · [权限引导](permission-flow.md)

## 环境

- macOS 14+、Apple Command Line Tools、Swift 5.9+、Python 3。
- 全项目检查及中继 Linux 包需 Go 1.25+；只构建 Mac 应用不需要 Go。CI 使用 macOS runner 自带 Go，打印实际版本，模块声明约束最低版本。
- 原生 SwiftUI/AppKit 项目，使用 Swift Package Manager，不依赖第三方运行时包；不要求安装完整 Xcode。
- `Sources/QuietDesk` 为应用界面、采集和输入，`Sources/QuietDeskCore` 为协议、传输、编解码及可测试逻辑。

尚未安装命令行开发工具时，可运行 `xcode-select --install`。以下命令均在仓库根目录执行。

## 构建应用

```sh
./build-app.sh
```

默认生成包含 `arm64` 和 `x86_64` 的 Universal 应用：`dist/QuietDesk.app`。构建不会安装或启动应用。只构建单一架构时使用：

```sh
./build-app.sh arm64
./build-app.sh x86_64
```

图标来自 `Resources/QuietDesk.icns`。生成文件及缓存位于已忽略的 `dist/`、`.build/`。

## 本地签名

未设置 `SIGNING_IDENTITY` 时使用 ad-hoc 临时签名，未经过 Apple 公证。使用本机钥匙串中有效的签名身份时，例如：

```sh
SIGNING_IDENTITY='Developer ID Application: …' ./build-app.sh
```

请将示例替换为实际身份。证书、私钥、密码、描述文件及私人签名配置保存在仓库外，不提交或加入源码包。指定身份只改变签名方式，不会自动完成 Apple 公证；开发签名也不等于 Developer ID 分发签名。

保持签名身份、bundle ID 和安装路径稳定有助于系统识别应用，但不能保证更新后免于重新授权。构建脚本会执行严格签名校验。

## 打包

构建后执行：

```sh
python3 scripts/package-app.py
```

`dist/` 中会生成 DMG、应用 ZIP、源码 ZIP 和 SHA-256 校验文件。DMG 内含应用与“应用程序”快捷方式；脚本会检查签名、架构、图标、镜像及 ZIP 完整性，不会上传或发布。

源码 ZIP 依据 **`git ls-files` 的跟踪文件清单**收录当前工作区内容。新增源码、文档和截图资源须纳入 Git 跟踪，否则不会进入源码包；打包前核对清单与工作区状态。源码包中的 `version.json` 使用实际应用包的版本及构建号。

## 版本与 GitHub Actions

查看本地构建将使用的版本：

```sh
python3 scripts/version.py current
```

默认值来自 `version.json`；检出带正式版本标签的提交时，可读取该标签及其注释中的构建号。环境变量 `QUIETDESK_VERSION`（三段数字版本）与 `QUIETDESK_BUILD_NUMBER`（正整数）可显式覆盖。本地自定义版本不会自动创建标签或 GitHub Release；本地候选包不代表该版本已发布。

工作流分为：

- **CI**：PR 面向 `main` 时运行 Python 版本检查、`QuietDeskChecks`、下方独立 App 检查、Universal 构建及应用元数据检查，也支持手动运行，不发布安装包。
- **Build and release macOS**：推送 `main` 会触发；手动运行仅从 `main` 发布。它执行版本、Core 与独立 App 检查、Universal 构建、打包，随后创建标签并发布 Release。默认仍为临时签名、未公证。

自动发布按正式版本标签分配版本：`auto` 首次使用配置的版本下限，之后递增补丁号；手动运行可选 `patch`、`minor`、`major`。构建号由基础值加工作流运行序号生成。流程串行执行，同次运行重跑会复用已分配标签；文件先上传到草稿后公开。发布前若 `main` 已有更新提交，旧任务跳过正式发布，由新提交继续处理。

## 运行检查

```sh
swift run --disable-sandbox QuietDeskChecks
./scripts/run-app-checks.sh
./scripts/run-input-checks.sh
./scripts/run-video-checks.sh
./scripts/run-cursor-checks.sh
./scripts/run-session-data-checks.sh
./scripts/run-session-effects-checks.sh
./scripts/run-traffic-checks.sh
./scripts/run-log-checks.sh
./scripts/run-credential-checks.sh
./scripts/run-permission-checks.sh
python3 -m unittest discover -s scripts/tests -v
```

| 检查 | 范围 |
| --- | --- |
| `QuietDeskChecks` | 协议、兼容、视频、剪贴板传输、画质、流量及空闲策略；网络检查仅使用 `127.0.0.1` |
| `run-app-checks.sh` | 实际 `ClipboardSync` 配合内存剪贴板和临时目录，验证焦点与传输顺序 |
| `run-input-checks.sh` | 验证真实 AppKit 鼠标、滚轮事件到远程输入的转换，以及被控端 CGEvent 字段；使用离屏画布与假提交器，不向系统注入输入 |
| `run-video-checks.sh` | 编码丢帧恢复、三帧窗口和画质/暂停边界，CoreMedia 数据持有与合成 H.264 编解码；不采集屏幕 |
| `run-cursor-checks.sh` | 假光标、位置与显示器提供者，验证坐标、热点、图片边界、形状变化、未知回退及停止隔离；不读取真实光标 |
| `run-session-data-checks.sh` | 后台数据路由、解码确认、新画面令牌、旧会话隔离与并发指标聚合 |
| `run-session-effects-checks.sh` | 假音频、假遮罩及会话退出屏障，验证取消和恢复顺序 |
| `run-traffic-checks.sh` | 临时目录中的地址/端口统计、旧设备历史保留、历史保存及错误处理 |
| `run-log-checks.sh` | 临时目录中的日志轮转、并发聚合、隐私字段、文件权限与导出错误恢复 |
| `run-credential-checks.sh` | 临时目录中的凭据往返、权限、损坏保留、原子写入失败、并发更新及连接记录匹配；不访问真实凭据或钥匙串 |
| `run-permission-checks.sh` | 独立 bundle ID 的透明面板与合成权限，验证引导自动关闭、切换及手动关闭；检查设置入口不调用主动授权 API |
| Python 检查 | 版本分配、参数校验及重跑规则 |

跳过 Core 中的本机网络检查可用 `swift run --disable-sandbox QuietDeskChecks --skip-network`；这仍会运行合成视频检查。运行环境须允许所需的本机网络和系统视频服务，受限环境中的失败应与业务缺陷区分。

独立 App 检查按当前主机架构编译，可通过 `QUIETDESK_CHECK_BUILD_DIR` 指定隔离缓存，例如：

```sh
QUIETDESK_CHECK_BUILD_DIR="$PWD/.build/clipboard-checks" ./scripts/run-app-checks.sh
```

这些自动检查不操作真实系统剪贴板、钥匙串或登录项，不录屏，也不实际开启静音或防窥。它们不能代替真实两台 Mac 上的权限延续、屏幕采集、输入、文件粘贴、自启及网络测试；Universal 编译通过也不等于已在 Intel 或 macOS 14 实机验证。

本页说明运行方法，不记录本轮执行结果。[BUILD-AND-CHECKS.md](../BUILD-AND-CHECKS.md) 保留的是 0.6.1 等历史记录，不能作为当前源码或本地候选版的验收结论；已发布包及 CI 结果以对应 Releases、Actions 记录为准。

## 中继开发与检查

`./scripts/run-all-checks.sh` 也运行节点 vet/race、连接记录隔离和原生端到端回环测试；需要允许本机回环端口及系统视频服务。可单独执行：

```sh
./scripts/run-relay-server-checks.sh
./scripts/run-relay-connection-checks.sh
./scripts/run-relay-certificate-checks.sh
./scripts/run-relay-client-checks.sh
./scripts/run-relay-client-checks.sh --udp-blocked
./scripts/run-relay-client-checks.sh --private-udp-port
./scripts/run-relay-client-checks.sh --mixed
./scripts/run-relay-client-checks.sh --mixed-blocked
./scripts/build-relay.sh
```

Docker 部署检查需要已运行的 Docker Engine、Compose v2.20+、Python 3 和 OpenSSL：

```sh
python3 scripts/check-relay-docker.py
python3 scripts/check-relay-docker.py --self-signed
```

`--self-signed` 使用 `deploy.sh --ip 127.0.0.1` 自动发证，并检查重复部署保留原证书、错误 IP 不会覆盖身份。Python 检查还会把实际 provisioner 的两个卷路径隔离到临时目录，使用真实 OpenSSL 检查 IPv4/IPv6、证书有效期、缺失身份与接入码、私钥不匹配和凭据不输出。这组检查需要支持 `x509 -checkip` 的 OpenSSL，优先使用 PATH 中的工具，否则尝试已安装的 Homebrew `openssl@3`；只有系统 LibreSSL 且没有等价工具时会明确跳过。Docker 镜像内使用 OpenSSL，不依赖宿主机 LibreSSL。

`run-relay-certificate-checks.sh` 使用临时自签的非 CA 服务端证书和独立偏好域，检查 PEM/DER、SHA-256、IP/域名、有效期、服务端用途、按节点保存与损坏拒绝。原生回环检查增加证书获取、替换拒绝、取消及使用固定证书的控制/视频/数据路径；混合路径和 UDP 受阻模式也使用固定证书。不会更改系统信任或访问真实应用的偏好/凭据。系统信任服务、回环端口或视频服务受限时须单独报告限制。

它使用随机项目名、临时自签名证书和独立命名卷，检查非 root 运行、TLS/接入鉴权、TCP 与 UDP 双向转发、重复部署后的登记归属和接入码保留，以及无效证书拒绝。结束只删除该测试项目的卷和镜像，不接触正式节点；端口使用临时空闲端口。CI 和发布流程复用 Linux Docker 检查，发布任务在检查通过后继续；另用 Buildx/QEMU 交叉构建 Linux amd64、arm64 镜像，不自动发布镜像。模拟证书仅用于本机回环，不能用于正式客户端。

`build-relay.sh` 除两份 Linux 程序包外，还会生成独立的 `QuietDesk-Relay-版本-Docker.tar.gz`。Docker 包只从 Git 跟踪清单选入中继 Go 源码、公开部署文件和许可证，包含各文件的 SHA-256、版本、源码提交及脏状态；证书、接入码、卷数据、构建缓存和本机配置不进入包。解压后无需完整 Mac 项目即可执行部署脚本。

`--build-only` 只编译原生测试，不运行网络。混合路径测试的专用密文代理仅通过 ClientHello 中的 ALPN 区分视频角色，不持有桌面密钥；丢弃真实 TLS 视频记录，控制和可靠数据仍由真实 Peer 处理。节点测试只在显式临时 fixture 目录下生成测试证书与凭据，结束清理服务；不要把该目录放进源码包。

实现位于 `relay/`、Core 的 `Relay*` 传输桥，以及可选的媒体能力协商。所有新增媒体字段可选，默认不启用混合恢复；业务模型只在显式配置并匹配目标标识后提供候选。协议细节见 [中继协议](relay-protocol.md)。
