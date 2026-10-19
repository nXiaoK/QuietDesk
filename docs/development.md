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

仓库默认发布继续使用临时签名，每次更新后需要在本机重新授予屏幕录制、辅助功能和输入监控权限。自行签名时，保持身份、bundle ID 和安装路径稳定有助于系统识别应用，但也不能保证更新后免于重新授权。构建脚本会执行严格签名校验。

## 打包

构建后执行：

```sh
python3 scripts/package-app.py
```

`dist/` 中会生成 DMG、应用 ZIP、源码 ZIP 和 SHA-256 校验文件。DMG 内含应用与“应用程序”快捷方式；脚本会检查签名、架构、图标、镜像及 ZIP 完整性，不会上传或发布。

源码 ZIP 依据 **`git ls-files` 的跟踪文件清单**收录当前工作区内容，脚本要求工作树及暂存区干净，也拒绝未忽略的未跟踪文件。新增源码、文档和截图资源须纳入 Git 跟踪，否则不会进入源码包；打包前核对清单与工作区状态。用户另有未提交或未跟踪的本地配置时，在干净的隔离检出中打包，保留原工作区。源码包中的 `version.json` 使用实际应用包的版本及构建号。

## 版本与 GitHub Actions

查看本地构建将使用的版本：

```sh
python3 scripts/version.py current
```

默认值来自 `version.json`；检出带正式版本标签的提交时，可读取该标签及其注释中的构建号。环境变量 `QUIETDESK_VERSION`（三段数字版本）与 `QUIETDESK_BUILD_NUMBER`（正整数）可显式覆盖。本地自定义版本不会自动创建标签或 GitHub Release；本地候选包不代表该版本已发布。

工作流分为：

- **CI**：PR 面向 `main` 时运行 Python 检查、`QuietDeskChecks`、下方独立 App 检查、Universal 构建及应用元数据检查；另生成临时更新密钥，在独立 bundle ID 下构建，并对实际 ZIP 执行 sign → verify。也支持手动运行，不接触正式签名 secret 或发布安装包。
- **Build and release macOS**：推送 `main` 会触发；手动运行仅从 `main` 发布。分配版本后先检查更新签名配置，再执行 Core 与独立 App 检查、Universal 构建、打包。既有资产上传草稿后，生成并复验更新清单，最后上传清单并公开 Release。公钥表为空时 warning 并跳过清单；默认仍为临时签名、未公证。

该推送流程也在 Linux 节点检查通过后调用 **Publish relay image**，用 `GITHUB_TOKEN` 和镜像 job 的 `packages: write` 权限向 GHCR 发布 Linux amd64、arm64 镜像。镜像名按仓库路径转成小写并追加 `-relay`，本仓库为 `ghcr.io/nxiaok/quietdesk-relay`。先发布 `sha-完整提交号`，再以构建产物的 digest 拉取，使用仅两个部署文件的临时目录验证手动证书、自签证书、TCP/UDP、身份保留和失败路径；全部通过后才把同一镜像标为 `latest` 与 `main`。摘要记录源码提交和可固定使用的 digest。源码提交标签表示构建来源，重新构建可能更新基础镜像，严格固定内容应使用 digest。

镜像发布与 Mac 构建是同一推送流程中独立的后续 job，都等待原有节点检查；镜像 job 失败不绕过检查去更新 `latest`，也不改变 Mac job 原有的依赖和发布条件。PR CI 只检查，不登录 GHCR 或发布镜像。首次发布后如果包默认私有，维护者需在 GitHub Packages 设置为 Public 才能匿名拉取；已有同名包则需授予此仓库写入该包的 Actions 权限。无需增加 Docker Hub 密码或上传部署节点的私密材料。

自动发布按正式版本标签分配版本：`auto` 首次使用配置的版本下限，之后递增补丁号；手动运行可选 `patch`、`minor`、`major`。构建号由基础值加工作流运行序号生成。流程串行执行，同次运行重跑会复用已分配标签；文件先上传到草稿后公开。发布前若 `main` 已有更新提交，旧任务跳过正式发布，由新提交继续处理。

## 更新签名与发布

更新器完全使用系统框架：URLSession、CryptoKit、Security 与 `ditto`。`QuietDeskUpdateTool` 是依赖 Core 的开发工具，不放入 `.app`。`Resources/update-feed.json` 指定固定 GitHub Release 清单地址和公钥表；`build-app.sh` 校验配置后通过 `plutil` 写入 `QuietDeskUpdateFeedURL`、`QuietDeskUpdatePublicKeys`。当前公钥表为空，更新入口、首次询问和自动网络检查均关闭；发布流程只发 warning 并跳过签名清单。首个启用更新器的版本需用户手动安装一次。

正式密钥必须由维护者本人生成、保存和设置，不能让实现或排障过程读取正式私钥。以下为维护者在自己机器上执行的命令示例；输出只有公钥和 keyID，私钥写在仓库外，文件权限为 `0600`，工具拒绝覆盖已有文件或写进 Git 仓库目录：

```sh
install -d -m 700 "$HOME/.config/QuietDesk"
swift run --disable-sandbox QuietDeskUpdateTool generate-key \
  --out "$HOME/.config/QuietDesk/update-signing.key"
```

把命令输出的公钥对象复制到 `Resources/update-feed.json` 的 `publicKeys` 数组中，例如 `[{"id":"<输出的 keyID>","key":"<输出的 base64 公钥>"}]`。公钥可以提交；私钥、密码和签名私有配置不能提交、加入源码包或输出到日志。维护者自行设置 Actions secret（Fork 请替换仓库）：

```sh
gh secret set QUIETDESK_UPDATE_SIGNING_KEY --repo nXiaoK/QuietDesk \
  < "$HOME/.config/QuietDesk/update-signing.key"
```

私钥内容是 base64 编码的 32 字节 Ed25519 原始私钥，需由维护者离线备份两份。丢失后，已安装客户端无法信任新密钥，必须手动安装一次内置新公钥的版本。轮换时先发布同时内置新旧公钥、仍由旧私钥签名的版本，待用户升级后再切换 secret 使用新私钥；不要直接删除旧公钥并期望旧客户端自动接受新签名。工具默认以年月生成 keyID，同月生成轮换密钥时，需在公钥配置中为新密钥指定不同的唯一 `id`；签名工具会按公钥匹配并采用配置中的 `id`。

发布前置检查放在版本分配之后、项目检查与构建之前，早于标签、草稿和发布。公钥非空但 secret 缺失或不匹配时直接失败，按提示设置正确 secret 后重跑。`check-key --config Resources/update-feed.json` 只输出“匹配 / 不匹配 / 缺失”，不输出私钥。签名步骤取草稿 Release 说明并截断到 4000 字符，`sign --app ... --archive ... --tag ... --repository ... --out ...` 生成 `QuietDesk-update.json`，再用 `verify --app ... --archive ... --manifest ...` 对照构建内公钥、应用元数据与 ZIP 大小/SHA-256 复验。签名失败的新 Release 保持草稿；全部验证成功后才上传清单并标记 latest。若已有更新的 `main` 提交，输出跳过标志并跳过后续签名/发布。

测试覆盖可直接运行：

```sh
swift build --product QuietDeskUpdateTool
python3 scripts/check-update-tool.py \
  --tool "$(swift build --show-bin-path)/QuietDeskUpdateTool" \
  --work "$PWD/work/update-tool-checks"
./scripts/run-update-checks.sh
```

工具检查自行生成仓库外临时密钥，结束后删除，不需要正式 secret。安装检查使用 `work/update-checks` 下的临时“Applications”、独立 bundle ID `local.quietdesk.checks.updater` 和合成 ad-hoc 小型应用，验证安装器流程；它不是完整 QuietDesk 界面的本地更新演练。不启动或替换生产应用，不安装到 `/Applications`，不授予或重置系统权限。端到端用例通过 LaunchServices 打开合成新版。仓库位于 `~/Documents`、`~/Desktop`、`~/Downloads` 等受“文件和文件夹”保护的目录时，macOS 会为检查 bundle 弹出访问授权，进程在响应前阻塞，未及时响应会超时失败。不要为了通过检查而授予权限；请在不受保护的检出目录或 CI 中运行此脚本。

对实际打包的 ZIP 复验结构、解压后应用元数据、架构和代码签名，可运行 `./scripts/run-update-checks.sh --validate-archive <ZIP 绝对路径> <参考 .app 绝对路径>`；这条命令只验证，不启动应用。

预览构建可用 `QUIETDESK_BUNDLE_IDENTIFIER` 指定独立标识，默认没有更新源和公钥。`QUIETDESK_UPDATE_FEED_URL`、`QUIETDESK_UPDATE_PUBLIC_KEYS` 仅接受非正式 bundle ID，显式设置为匹配的临时公钥和 `http://127.0.0.1:<临时端口>/...` 或 `http://localhost:<临时端口>/...` 才启用回环演练；将两个变量同时设为空字符串可禁用，公钥非空而源为空会报配置错误。正式 bundle ID `local.quietdesk.app` 拒绝这两个覆盖变量，正式发布工作流也不得设置它们。预览输出与缓存通过 `QUIETDESK_DIST_DIR`、`QUIETDESK_BUILD_DIR` 放进 `work/`；演练版本可配合 `QUIETDESK_VERSION`、`QUIETDESK_BUILD_NUMBER`，不得指向正式应用安装路径。配置规则和故障排查见 [使用指南](usage.md#应用内更新) 与 [安全边界](security.md#应用内更新)。

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
./scripts/run-update-controller-checks.sh
./scripts/run-update-checks.sh
python3 -m unittest discover -s scripts/tests -v
```

| 检查 | 范围 |
| --- | --- |
| `QuietDeskChecks` | 协议、兼容、视频、剪贴板传输、画质、流量、空闲策略，以及更新清单签名、版本/URL 规则、首次询问与安装可用性纯逻辑；网络检查仅使用 `127.0.0.1` |
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
| `run-update-controller-checks.sh` | 独立 bundle ID、隔离偏好与回环服务，检查更新控制器、首次询问时机、自动检查间隔及清单获取边界 |
| `run-update-checks.sh` | 独立 bundle ID、临时目录、合成签名应用和回环服务；检查更新下载、暂存、独立安装进程、重启与故障恢复 |
| Python 检查 | 版本分配、参数校验、打包、更新构建配置、plist 注入及发布前置顺序等规则；更新工具另用临时密钥检查签名与篡改拒绝 |

跳过 Core 中的本机网络检查可用 `swift run --disable-sandbox QuietDeskChecks --skip-network`；这仍会运行合成视频检查。运行环境须允许所需的本机网络和系统视频服务，受限环境中的失败应与业务缺陷区分。

独立 App 检查按当前主机架构编译，可通过 `QUIETDESK_CHECK_BUILD_DIR` 指定隔离缓存，例如：

```sh
QUIETDESK_CHECK_BUILD_DIR="$PWD/.build/clipboard-checks" ./scripts/run-app-checks.sh
```

这些自动检查不操作真实系统剪贴板、钥匙串或登录项，不录屏，也不实际开启静音或防窥。它们不能代替真实两台 Mac 上的权限重新授权、屏幕采集、输入、文件粘贴、自启及网络测试；Universal 编译通过也不等于已在 Intel 或 macOS 14 实机验证。更新的“App 管理”拦截、非管理员账户、DMG/Translocation、macOS 14/15/26 与 Intel 实机、更新后实际 TCC/登录项状态和自动共享恢复，仍需分别验收。

本页说明运行方法，不记录本轮执行结果。[BUILD-AND-CHECKS.md](../BUILD-AND-CHECKS.md) 按功能或版本记录实际检查范围，旧版本记录不能作为当前源码或本地候选版的验收结论；已发布包及 CI 结果以对应 Releases、Actions 记录为准。

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
python3 scripts/check-relay-docker.py --self-signed --image ghcr.io/nxiaok/quietdesk-relay@sha256:镜像摘要
```

`--self-signed` 使用 `deploy.sh --ip 127.0.0.1` 自动发证，并检查重复部署保留原证书、错误 IP 不会覆盖身份。Python 检查还会把实际 provisioner 的两个卷路径隔离到临时目录，使用真实 OpenSSL 检查 IPv4/IPv6、证书有效期、缺失身份与接入码、私钥不匹配和凭据不输出。这组检查需要支持 `x509 -checkip` 的 OpenSSL，优先使用 PATH 中的工具，否则尝试已安装的 Homebrew `openssl@3`；只有系统 LibreSSL 且没有等价工具时会明确跳过。Docker 镜像内使用 OpenSSL，不依赖宿主机 LibreSSL。

`run-relay-certificate-checks.sh` 使用临时自签的非 CA 服务端证书和独立偏好域，检查 PEM/DER、SHA-256、IP/域名、有效期、服务端用途、按节点保存与损坏拒绝。原生回环检查增加证书获取、替换拒绝、取消及使用固定证书的控制/视频/数据路径；混合路径和 UDP 受阻模式也使用固定证书。不会更改系统信任或访问真实应用的偏好/凭据。系统信任服务、回环端口或视频服务受限时须单独报告限制。

Docker 检查使用随机项目名、临时自签名证书和独立命名卷，检查非 root 运行、TLS/接入鉴权、TCP 与 UDP 双向转发、重复部署后的登记归属和接入码保留，以及无效证书拒绝。默认从源码构建；`--image` 只复制 `deploy.sh` 和 `compose.image.yaml`，实际拉取指定镜像并验证无需 Go 源码。结束只删除该测试项目的卷，本地构建时还删除其测试镜像；外部传入的镜像保留，不接触正式节点。端口使用临时空闲端口。CI 和发布流程复用 Linux Docker 检查；PR 仍用 Buildx/QEMU 交叉构建两架构检查，main 的镜像发布由上面的独立 job 执行。模拟证书仅用于本机回环，不能用于正式客户端。

`build-relay.sh` 除两份 Linux 程序包外，还会生成含 Go 源码的 `QuietDesk-Relay-版本-Docker.tar.gz` 和仅含部署文件的 `QuietDesk-Relay-版本-Docker-Deploy.tar.gz`，四个归档均进入 `SHA256SUMS.txt`。源码 Docker 包从 Git 跟踪清单选择公开部署文件和中继 Go 源码；轻量包仅含 `deploy.sh`、`compose.image.yaml`、README、许可证与清单。清单包含文件 SHA-256、版本、源码提交及脏状态。证书、接入码、卷数据、构建缓存和本机配置不进入包。轻量目录默认拉取镜像；完整源码目录默认本地构建，加 `--pull` 可使用镜像。拉取在初始化身份前完成，失败不会重建服务；后续 run/up 禁止再次拉取。默认项目/卷名保持一致，模式切换保留状态。

`--build-only` 只编译原生测试，不运行网络。混合路径测试的专用密文代理仅通过 ClientHello 中的 ALPN 区分视频角色，不持有桌面密钥；丢弃真实 TLS 视频记录，控制和可靠数据仍由真实 Peer 处理。节点测试只在显式临时 fixture 目录下生成测试证书与凭据，结束清理服务；不要把该目录放进源码包。

实现位于 `relay/`、Core 的 `Relay*` 传输桥，以及可选的媒体能力协商。所有新增媒体字段可选，默认不启用混合恢复；业务模型只在显式配置并匹配目标标识后提供候选。协议细节见 [中继协议](relay-protocol.md)。
