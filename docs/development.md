# 开发指南

[返回首页](../README.md) · [历史构建记录](../BUILD-AND-CHECKS.md)

## 环境

- macOS 14+、Apple Command Line Tools、Swift 5.9+、Python 3。
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

- **CI**：PR 面向 `main` 时运行 Python 版本检查、`QuietDeskChecks`、Universal 构建及应用元数据检查，也支持手动运行。它没有运行下方全部独立 App 检查脚本，也不发布安装包。
- **Build and release macOS**：推送 `main` 会触发；手动运行仅从 `main` 发布。它执行版本与 Core 检查、Universal 构建、打包，随后创建标签并发布 Release。默认仍为临时签名、未公证。

自动发布按正式版本标签分配版本：`auto` 首次使用配置的版本下限，之后递增补丁号；手动运行可选 `patch`、`minor`、`major`。构建号由基础值加工作流运行序号生成。流程串行执行，同次运行重跑会复用已分配标签；文件先上传到草稿后公开。发布前若 `main` 已有更新提交，旧任务跳过正式发布，由新提交继续处理。

## 运行检查

```sh
swift run --disable-sandbox QuietDeskChecks
./scripts/run-app-checks.sh
./scripts/run-input-checks.sh
./scripts/run-session-effects-checks.sh
./scripts/run-traffic-checks.sh
python3 -m unittest discover -s scripts/tests -v
```

| 检查 | 范围 |
| --- | --- |
| `QuietDeskChecks` | 协议、兼容、视频、剪贴板传输、画质、流量及空闲策略；网络检查仅使用 `127.0.0.1` |
| `run-app-checks.sh` | 实际 `ClipboardSync` 配合内存剪贴板和临时目录，验证焦点与传输顺序 |
| `run-input-checks.sh` | 构造 CGEvent 并由假提交器收集，不向系统注入输入 |
| `run-session-effects-checks.sh` | 假音频、假遮罩及会话退出屏障，验证取消和恢复顺序 |
| `run-traffic-checks.sh` | 临时目录中的设备身份、历史保存及错误处理 |
| Python 检查 | 版本分配、参数校验及重跑规则 |

跳过 Core 中的本机网络检查可用 `swift run --disable-sandbox QuietDeskChecks --skip-network`；这仍会运行合成视频检查。运行环境须允许所需的本机网络和系统视频服务，受限环境中的失败应与业务缺陷区分。

独立 App 检查按当前主机架构编译，可通过 `QUIETDESK_CHECK_BUILD_DIR` 指定隔离缓存，例如：

```sh
QUIETDESK_CHECK_BUILD_DIR="$PWD/.build/clipboard-checks" ./scripts/run-app-checks.sh
```

这些自动检查不操作真实系统剪贴板、钥匙串或登录项，不录屏，也不实际开启静音或防窥。它们不能代替真实两台 Mac 上的权限延续、屏幕采集、输入、文件粘贴、自启及网络测试；Universal 编译通过也不等于已在 Intel 或 macOS 14 实机验证。

本页说明运行方法，不记录本轮执行结果。[BUILD-AND-CHECKS.md](../BUILD-AND-CHECKS.md) 保留的是 0.6.1 等历史记录，不能作为当前源码或本地候选版的验收结论；已发布包及 CI 结果以对应 Releases、Actions 记录为准。
