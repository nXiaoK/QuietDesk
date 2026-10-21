# QuietDesk 自托管中继节点

节点使用 Go 标准库，可编译成 Linux 单一可执行文件，不在 Mac 客户端引入 Go 或第三方运行时。当前协议版本为 1。两端配置和连接策略见 [Mac 中继指南](../docs/relay.md)；独立安装包内按下文配置节点，再在两台 Mac 的“中继设置”保存同一节点地址和接入码。

## Docker 单命令部署（推荐）

准备一台双方可访问的 Linux 服务器（amd64 或 arm64）、Docker Engine 和 Docker Compose v2.20+，在云安全组和防火墙放行 **7443/TCP 与 7443/UDP**。可直接使用固定公网 IP，无需域名或提前申请证书。部署脚本不修改防火墙。

### 拉取已发布镜像

GitHub Actions 在 `main` 推送后自动构建并发布双架构镜像 `ghcr.io/nxiaok/quietdesk-relay`，服务器无需克隆仓库或编译。首次工作流成功后即可使用；如果 GHCR 包初始为 Private，仓库维护者需在 GitHub Packages 的 `quietdesk-relay` 包设置中将可见性改为 **Public**，之后服务器可匿名拉取。保持私有时，先由部署者按 GHCR 的方式登录 Docker。

服务器只下载两个很小的部署文件：

```sh
mkdir -p quietdesk-relay
cd quietdesk-relay
curl -fsSL https://raw.githubusercontent.com/nXiaoK/QuietDesk/main/relay/compose.image.yaml -o compose.image.yaml
curl -fsSL https://raw.githubusercontent.com/nXiaoK/QuietDesk/main/relay/deploy.sh -o deploy.sh
sh deploy.sh --ip 你的服务器IP
```

脚本自动拉取适合服务器架构的镜像，配置身份并等待健康检查。部署目录中无需 Dockerfile、Go 源码或编译器。也可下载并解压发行版的 `QuietDesk-Relay-版本-Docker-Deploy.tar.gz`，在解压目录执行同一命令。

镜像标签与固定版本：

- `latest`、`main`：最近一次通过节点检查、双架构构建及已发布镜像部署检查的 main 镜像。
- `sha-完整提交号`：对应源码提交的构建。工作流摘要提供具体镜像 digest；严格固定镜像内容时使用 `ghcr.io/nxiaok/quietdesk-relay@sha256:…`，因为重新构建同一提交可能更新基础镜像。

```sh
QUIETDESK_RELAY_IMAGE=ghcr.io/nxiaok/quietdesk-relay:sha-完整提交号 sh deploy.sh --ip 你的服务器IP
```

固定提交时，下载 URL 中的 `main` 也替换成相同提交号，以便配置与镜像配套。首次发布未完成或拉取失败时，脚本会在配置身份和重启服务之前停止。每次部署先拉取一次选定镜像，准备与服务启动均禁止再次拉取，避免同一脚本因再次拉取移动标签而使用不同版本。

### 从源码构建

原有 `QuietDesk-Relay-版本-Docker.tar.gz` 包和仓库内的源码构建方式继续可用：

```sh
./deploy.sh --ip 你的服务器IP
```

在完整源码目录中，`deploy.sh` 默认仍使用 `compose.yaml` 构建本机架构镜像；在仓库根目录使用 `./relay/deploy.sh`，参数相同。加 `--pull`（例如 `./relay/deploy.sh --pull --ip 服务器IP`）可显式切换到已发布镜像。只有部署文件的目录会自动使用 `compose.image.yaml` 拉取镜像。

两种方式都不要求服务器安装 Go、Swift 或 Python；源码方式需要下载构建基础镜像，镜像方式只下载运行镜像。不将宿主机目录或 Docker socket 挂进容器。

### 身份与客户端配置

将 IP 参数替换为实际 IPv4 或 IPv6 地址，不附端口，IPv6 不加方括号。首次生成有效期 365 天、RSA 3072/SHA-256、包含该 IP SAN 和 serverAuth 用途的自签 TLS 证书；私钥仅保留在私有 tls 卷内。终端输出公开的 SHA-256 证书指纹，**不输出私钥和接入码**。重复执行会复用原证书；IP 不匹配、证书过期或证书/私钥缺一时拒绝自动替换。已有接入码或登记表但整个 TLS 身份丢失时，也拒绝重新发证；须恢复备份，或明确提供新证书并在客户端重新核对信任。

以下运维示例使用镜像部署的 `compose.image.yaml`；源码构建部署时改用 `compose.yaml`。在服务器终端查看指纹，或只导出公开证书供客户端导入：

```sh
docker compose -f compose.image.yaml exec -T relay openssl x509 -in /etc/quietdesk-relay/fullchain.pem -noout -fingerprint -sha256
docker compose -f compose.image.yaml exec -T relay openssl x509 -in /etc/quietdesk-relay/fullchain.pem -outform PEM > node-certificate.pem
```

两台 Mac 使用支持节点证书信任的 QuietDesk 版本，填写 `tls://你的服务器IP:7443`（IPv6 写作 `tls://[IPv6地址]:7443`），在“中继设置”导入该公开证书，或获取证书后与服务器终端的 SHA-256 指纹核对，再保存信任。无需导入系统钥匙串或修改系统信任。地址、证书有效期和保存的节点证书仍会校验；接入码和 Mac 配对认证仍独立执行。

已有域名/证书的部署方式继续可用，例如：

```sh
sh deploy.sh /etc/letsencrypt/live/relay.example.com/fullchain.pem \
  /etc/letsencrypt/live/relay.example.com/privkey.pem
```

证书链须匹配实际 IP 或域名，私钥不带密码，执行账户需有读取权限。路径允许使用证书管理器创建的符号链接；脚本通过标准输入传入证书。在部署目录中，**使用私人终端**获取节点接入码：

```sh
docker compose -f compose.image.yaml exec -T relay cat /var/lib/quietdesk-relay/access.key
```

两台 Mac 的“中继设置”均填写相同节点地址与此接入码。被控端开启共享，控制端选择“仅中继”，填写被控端设备标识和原有 Mac 配对码。接入码不能代替 Mac 配对码。

### 端口与运维

如需公网端口 443，在每次部署或运维前设置同一环境变量；它同时映射 TCP 和 UDP，容器内仍监听 7443：

```sh
export QUIETDESK_RELAY_PORT=443
sh deploy.sh --ip 你的服务器IP
```

此时客户端地址端口也改成 443。普通 HTTP/Nginx `location` 反向代理不能转发此协议。健康端点只在容器回环监听，没有向宿主机发布 9091 端口：

```sh
docker compose -f compose.image.yaml ps
docker compose -f compose.image.yaml logs --tail 100 relay
docker compose -f compose.image.yaml exec -T relay wget -qO- http://127.0.0.1:9091/healthz
docker compose -f compose.image.yaml stop relay
docker compose -f compose.image.yaml start relay
```

容器以固定 UID/GID `65532:65532` 运行，根文件系统只读且移除 Linux capabilities。首次创建的 Docker 命名卷自动使用正确属主与私有权限：`quietdesk-relay_state` 保存接入密钥和 `devices.json`，`quietdesk-relay_tls` 保存证书链与私钥；不写入镜像或安装包。日志自动轮转。默认项目名固定为 `quietdesk-relay`，换目录升级或在源码/镜像模式间切换仍复用原卷；如使用 `COMPOSE_PROJECT_NAME` 隔离多个节点，后续所有命令必须保持相同项目名。

**更新、证书续期与回退：**先停止服务并备份这两个命名卷（含属主和权限），记录旧镜像 digest 并保留其配套部署文件。镜像部署重跑 `sh deploy.sh --ip 服务器IP` 即会拉取当前选择的镜像并重建容器；源码方式更新源码后重跑。两者保留已有证书、接入密钥和登记表；手动传入新证书时才替换证书。重建和重启会中断中继会话。证书管理器续期不会自动更新容器里的证书副本，需再次执行部署命令。证书不匹配、过期、密钥丢失且仍有登记表、状态损坏或不兼容会报错，不自动清空旧状态。

镜像部署可用 `docker compose -f compose.image.yaml images` 查实际使用的镜像，再用 `docker image inspect 镜像 --format '{{json .RepoDigests}}'` 保存 digest。回退时使用旧版部署文件，把 `QUIETDESK_RELAY_IMAGE` 指向保留的旧 digest，重跑部署命令。源码方式可用 `docker image tag quietdesk-relay:local quietdesk-relay:previous` 保留旧镜像，再使用旧版配置和 `QUIETDESK_RELAY_IMAGE=quietdesk-relay:previous docker compose up -d --no-build --force-recreate --wait relay` 回退。

同一状态格式可继续使用原卷；跨格式回退必须遵循对应版本迁移说明。`docker compose down` 保留卷；**不要执行 `down -v`、删除卷或清空登记表来排障**。从原 systemd 安装迁移时，先停旧节点，将原接入密钥和登记表一起导入 state 卷，保持目录 `0700`、文件 `0600`、属主 `65532:65532`，再部署；不要用全新节点覆盖旧身份数据。

镜像也可在源码 `relay/` 中用 Buildx 交叉构建：`docker buildx build --platform linux/amd64,linux/arm64 -o type=oci,dest=quietdesk-relay.oci.tar .`。Actions 使用仓库的 `GITHUB_TOKEN` 和仅镜像发布 job 的 `packages: write` 权限发布到 GHCR，不需要添加 Docker Hub 密码或将任何节点证书、接入码上传到 GitHub。

## 构建

开发环境需 Go 1.25+。在仓库根目录执行：

```sh
./scripts/build-relay.sh
./scripts/run-relay-server-checks.sh
```

默认在 `outputs/relay/` 生成 Linux amd64、arm64 两份静态程序，以及各架构的 `.tar.gz` 安装包、Docker 源码包、Docker 轻量部署包和 `SHA256SUMS.txt`。程序归档包含程序、部署说明、systemd 模板、许可证和含程序 SHA-256 的清单；Docker 源码包包含独立构建所需的 Go 源码、Compose 和部署脚本；`Docker-Deploy` 轻量包只含拉取镜像的部署文件、说明和清单。均不包含证书、私钥、接入码或设备状态。程序包解压后可将 `quietdesk-relay` 安装到模板指定位置。构建使用 Python 3 打包，服务器运行只需要程序本身。编译缓存保留在 `work/relay-build/`。只构建节点不需要 Swift。只构建原有 Mac 客户端不需要 Go。

## 配置与启动

服务器需有两端可访问的 IP 或域名、匹配地址且被客户端信任的有效服务器证书，以及同一数字端口的 TCP、UDP。TCP 用于服务鉴权、设备登记与独立可靠转发通道；UDP 用于转发带鉴权封装的端到端 DTLS 密文。示例使用 `7443`，也可部署到 `443`；仅开放 TCP 时仍应由客户端使用可靠传输兜底。

使用独立 Linux 服务账户运行，准备其私有状态目录，并把证书链、私钥放到仓库外。以下命令在准备好的私有目录中生成独立的节点接入密钥，不输出密钥内容：

```sh
umask 077
mkdir -p relay-state
chmod 700 relay-state
openssl rand -hex 32 > relay-state/access.key
chmod 600 relay-state/access.key
./quietdesk-relay \
  --listen :7443 \
  --cert /etc/quietdesk-relay/fullchain.pem \
  --key /etc/quietdesk-relay/privkey.pem \
  --access-key-file relay-state/access.key \
  --state relay-state/devices.json
```

密钥文件需为当前服务账户拥有的普通文件，权限 `0600`；拒绝符号链接、硬链接和其他账户可读的密钥文件。设备状态目录权限需为 `0700`。节点接入密钥只控制谁能使用此节点，**不是 Mac 配对码**；节点不得配置或接收 Mac 配对码。

需放行服务端口的 TCP 和 UDP。Mac 双方只需主动出站访问节点，不需为各自配置入站映射。普通 HTTP 反向代理不能直接转发此协议；如使用网关，应保持 TCP 字节流与 UDP 数据报边界，且客户端验证的服务身份必须正确。仅使用端口 443 不保证所有企业代理均兼容。

默认健康检查仅监听 `127.0.0.1:9091`：

```sh
curl --fail http://127.0.0.1:9091/healthz
```

返回真实的活动连接、在线登记、待接通/活动隧道、UDP 会话、协商了打洞的 UDP 会话（`assistedLeases`）与转发字节计数，不返回设备列表、地址、密钥或业务内容。`--health ''` 可关闭；程序拒绝把此端点绑定到非回环地址。

## 身份与隐私边界

- 服务 TLS 验证节点身份；内层桌面 TLS/DTLS 仍由两台 Mac 完成。节点转发内层密文，不解码、转码或终止桌面配对认证。
- 设备标识只用于寻址。设备首次登记时绑定独立登记密钥的 SHA-256 摘要；重复在线登记或不同登记密钥接管相同标识会被拒绝。摘要保存到私有状态文件，临时在线状态和路由令牌不持久化。
- 可靠隧道的绑定令牌只对当前在线登记和单次待接通请求有效，存在明确超时。登记断开会关闭其转发会话。
- UDP 路由使用每个会话、每个方向角色独立的路由凭据、方向标记及有界重放窗口。仅新鲜且通过校验的封包能更新 NAT 端点。数据报上限为 1152 字节的内层记录，额外路由封装 64 字节；不会把视频密钥交给节点。
- 节点能观察网络地址、连接时间和流量规模，不能声称其完全看不到元数据。默认不记录业务数据、设备标识、远端地址或接入凭据。
- 中继打洞是可选能力：双方都声明并都同意后，节点才把各自观察到的来源地址和对方自报的网卡地址转告对方；节点不参与直连封包，也拿不到直连密钥。打洞依赖节点看到客户端的真实来源地址：默认 rootful Docker 的端口发布满足，rootless Docker、userland-proxy 或改写来源地址的负载均衡会让打洞失败（视频保持中继）。详见[中继打洞](../docs/relay.md#中继打洞)。

## 运行与升级

可使用随附 `quietdesk-relay.service` 模板运行。按实际安装路径和端口调整，在启用前由部署者准备专用 Linux 账户、证书、私钥、接入密钥及正确权限。模板不自动申请证书，也不改路由器或防火墙。

`--max-connections`、`--max-devices` 是可配置的节点套接字和持久登记表技术资源边界，不是用户套餐、并发控制人数或每日流量配额。达到资源边界会明确拒绝新增分配，不覆盖现有登记。已有桌面单控制会话的规则仍由 Mac 执行。

升级前备份设备状态和节点接入密钥，保留旧程序。停止并替换程序后重新启动；重启会中断中继会话，客户端需重新连接。保持设备状态文件不变，已有登记身份不会因服务重启而被其他凭据接管。未知或损坏的状态文件会阻止启动，程序不会自动重置或覆盖。

证书续期后需安排重启载入新证书。若 Mac 的设备登记凭据丢失，应恢复该 Mac 的凭据备份或明确使用新设备标识；不要为此清空整个节点的登记表。配对凭据失效、系统权限和节点连接故障是不同问题，不能互相替代授权。

## 验证范围

服务端检查使用临时证书与凭据和本机回环，包含鉴权、设备接管拒绝、状态保留、可靠字节流双向转发、故障清理、UDP 鉴权/重放/重绑定、打洞能力协商与候选交换、资源边界和竞态检查。Linux 两架构交叉编译不等于已在真实 Linux 节点部署，更不等于双机公网画面和输入已验收。

## 停止与回退

使用 systemd 安装后，`sudo systemctl stop quietdesk-relay` 停止服务，`sudo systemctl restart quietdesk-relay` 载入替换后的程序和证书；运行状态用 `systemctl status` 与回环健康端点核对。回退时停止服务、恢复保留的旧程序，再使用同一设备状态和接入密钥启动。不要删除 `devices.json` 来处理网络问题。协议 v1 的未知状态格式会阻止启动；升级涉及状态格式时须先按对应版本的迁移说明执行，不能直接覆盖生产状态。

安装包清单记录源码提交和构建时工作树是否含未提交内容；候选构建的脏状态不能当作某个干净提交的正式发布。
