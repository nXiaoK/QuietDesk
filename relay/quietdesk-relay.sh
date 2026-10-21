#!/bin/sh
# QuietDesk relay node manager for Linux servers with Docker: install, upgrade, roll back,
# show connection details and uninstall the deployment described by compose.image.yaml.
# Run as root, for example: sudo sh quietdesk-relay.sh
QUIETDESK_RELAY_MANAGER=1
set -eu
umask 077

raw_base="${QUIETDESK_RELAY_RAW_BASE:-https://raw.githubusercontent.com/nXiaoK/QuietDesk}"
ref="${QUIETDESK_RELAY_REF:-main}"
project="${COMPOSE_PROJECT_NAME:-quietdesk-relay}"
image="${QUIETDESK_RELAY_IMAGE:-ghcr.io/nxiaok/quietdesk-relay:latest}"
directory="${QUIETDESK_RELAY_DIR:-/opt/quietdesk-relay}"
previous="$project:previous"
command=''
ip=''
port=''
purge=false
assume_yes=false
container=''
detected_ip=''
detected_from=''

say() { printf '%s\n' "$*"; }
warn() { printf '提示：%s\n' "$*" >&2; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
QuietDesk 中继节点一键管理

用法：sudo sh quietdesk-relay.sh [命令] [选项]

命令：
  install     安装节点：自动识别公网 IP，完成后显示服务地址、接入码和证书指纹；已安装时改为升级
  upgrade     升级到最新节点镜像：先备份数据，新版本启动失败时自动回退
  info        再次显示服务地址、接入码、证书指纹和运行状态
  rollback    回到最近一次升级前的版本
  uninstall   卸载节点：默认保留接入码、证书和设备登记，重装后沿用
  不带命令时显示菜单。

选项：
  --ip IP       服务器公网 IPv4 或 IPv6，跳过自动识别（首次安装时使用）
  --port PORT   服务端口，TCP 和 UDP 同时使用，默认 7443（首次安装时使用）
  --dir DIR     部署目录，需为新的或空目录，默认 /opt/quietdesk-relay
  --purge       与 uninstall 同用：同时永久删除接入码、证书、设备登记、备份和部署目录
  -y, --yes     不再询问确认
  -h, --help    显示本帮助
EOF
}

# Prompts read the terminal directly so the script still asks when piped into sh.
interactive() { [ "$assume_yes" = false ] && (exec </dev/tty) 2>/dev/null; }

ask() {
    printf '%s' "$1" > /dev/tty
    answer=''
    IFS= read -r answer < /dev/tty || answer=''
    printf '%s' "$answer"
}

confirm() {
    [ "$assume_yes" = true ] && return 0
    interactive || die "需要确认：$1。请在终端中运行，或加 --yes"
    case "$(ask "$1？[y/N] ")" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time "${2:-60}" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T "${2:-60}" "$1"
    else
        return 1
    fi
}

is_ipv4() {
    printf '%s\n' "$1" | awk -F. 'NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255) exit 1 }'
}

is_ipv6() {
    case "$1" in *:*:*) ;; *) return 1 ;; esac
    case "$1" in *[!0-9a-fA-F:.]*) return 1 ;; esac
}

is_public_ipv4() {
    is_ipv4 "$1" || return 1
    printf '%s\n' "$1" | awk -F. '{ a = $1 + 0; b = $2 + 0
        if (a == 0 || a == 10 || a == 127 || a >= 224) exit 1
        if (a == 100 && b >= 64 && b <= 127) exit 1
        if (a == 169 && b == 254) exit 1
        if (a == 172 && b >= 16 && b <= 31) exit 1
        if (a == 192 && b == 168) exit 1 }'
}

# Global unicast only (2000::/3); link-local, unique-local, mapped and loopback addresses are not reachable.
is_public_ipv6() {
    is_ipv6 "$1" || return 1
    case "$1" in [23][0-9a-fA-F]*) return 0 ;; *) return 1 ;; esac
}

detect_public_ip() {
    for source in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://4.ipw.cn; do
        candidate="$(fetch "$source" 6 2>/dev/null | head -n 1 | tr -d ' \t\r\n')" || candidate=''
        if is_public_ipv4 "$candidate"; then detected_ip="$candidate"; detected_from="$source"; return 0; fi
    done
    for source in https://api6.ipify.org https://ipv6.icanhazip.com https://6.ipw.cn; do
        candidate="$(fetch "$source" 6 2>/dev/null | head -n 1 | tr -d ' \t\r\n')" || candidate=''
        if is_public_ipv6 "$candidate"; then detected_ip="$candidate"; detected_from="$source"; return 0; fi
    done
    if command -v ip >/dev/null 2>&1; then
        candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')" || candidate=''
        if is_public_ipv4 "$candidate"; then detected_ip="$candidate"; detected_from='本机网卡'; return 0; fi
    fi
    return 1
}

choose_public_ip() {
    if detect_public_ip; then
        say "检测到公网 IP：$detected_ip（来源：$detected_from）"
        ip="$detected_ip"
        if interactive; then
            answer="$(ask '直接回车使用该地址，或输入其他 IP：')"
            [ -z "$answer" ] || ip="$answer"
        fi
    elif interactive; then
        ip="$(ask '无法自动识别公网 IP，请输入服务器公网 IP：')"
    else
        die '无法自动识别公网 IP，请用 --ip 指定服务器公网地址'
    fi
    validate_ip
}

validate_ip() {
    is_ipv4 "$ip" || is_ipv6 "$ip" || die "IP 地址无效：$ip（只填 IP，不带端口；IPv6 不加方括号）"
    if ! is_public_ipv4 "$ip" && ! is_public_ipv6 "$ip"; then
        warn "$ip 不是公网地址，只有同一内网的 Mac 能连接此节点"
    fi
}

validate_port() {
    case "$port" in ''|*[!0-9]*) die "端口无效：$port" ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "端口无效：$port"
}

require_root() { [ "$(id -u)" -eq 0 ] || die '请使用 root 运行，例如：sudo sh quietdesk-relay.sh'; }
require_linux() { [ "$(uname -s)" = Linux ] || die '一键脚本只支持 Linux 服务器'; }

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        [ "$1" = install ] || die '未找到 Docker'
        confirm '未检测到 Docker，是否使用 Docker 官方安装脚本（get.docker.com）安装 Docker' \
            || die '请先安装 Docker 和 Docker Compose 插件后重试'
        fetch https://get.docker.com 300 > "$work/get-docker.sh" || die '无法下载 Docker 安装脚本'
        sh "$work/get-docker.sh" || die 'Docker 安装失败'
        if command -v systemctl >/dev/null 2>&1; then systemctl enable --now docker >/dev/null 2>&1 || true; fi
    fi
    docker info >/dev/null 2>&1 || die 'Docker 服务未运行，请先启动 Docker（例如 systemctl start docker）'
    docker compose version >/dev/null 2>&1 || die '未找到 Docker Compose 插件，请安装 docker-compose-plugin 后重试'
    if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        warn 'Docker 以 rootless 模式运行，节点可能看不到客户端的真实来源地址，中继打洞会失败（视频仍可经中继传输）'
    fi
}

compose() {
    QUIETDESK_RELAY_IMAGE="$image" QUIETDESK_RELAY_PORT="$port" COMPOSE_PROJECT_NAME="$project" \
        docker compose -f "$directory/compose.image.yaml" "$@"
}

start_relay() { compose up -d --no-build --pull never --force-recreate --wait --wait-timeout 90 relay; }

relay_container() {
    docker ps -aq --filter "label=com.docker.compose.project=$project" \
        --filter label=com.docker.compose.service=relay | head -n 1
}

container_port() {
    docker inspect --format '{{range $p, $b := .HostConfig.PortBindings}}{{if eq $p "7443/tcp"}}{{range $b}}{{.HostPort}} {{end}}{{end}}{{end}}' \
        "$1" | awk '{ print $1 }'
}

container_running() { [ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; }

# Runs a read-only command against the installed identity, even while the relay is stopped.
in_relay() {
    if container_running; then
        docker exec "$container" "$@"
    else
        entry="$1"; shift
        docker run --rm --network none --entrypoint "$entry" \
            -v "${project}_state:/var/lib/quietdesk-relay:ro" -v "${project}_tls:/etc/quietdesk-relay:ro" \
            "$(docker inspect --format '{{.Image}}' "$container")" "$@"
    fi
}

certificate_address() {
    sed -n 's/.*IP Address:\([0-9A-Fa-f:.]*\).*/\1/p; s/.*DNS:\([^, ]*\).*/\1/p' | head -n 1
}

env_value() {
    [ -f "$directory/.env" ] || return 0
    sed -n "s/^$1=//p" "$directory/.env" | tail -n 1
}

write_env() {
    {
        say '# quietdesk-relay.sh 生成；docker compose 会读取这些值'
        say "QUIETDESK_RELAY_PORT=$port"
        [ -z "$ip" ] || say "QUIETDESK_RELAY_PUBLIC_ADDRESS=$ip"
    } > "$directory/.env.new"
    mv "$directory/.env.new" "$directory/.env"
}

script_directory() {
    [ -f "$0" ] && grep -q '^QUIETDESK_RELAY_MANAGER=1$' "$0" 2>/dev/null || return 0
    (CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
}

# The deployment directory holds only what this script writes. Anything else means a shared directory
# such as /opt, whose permissions must stay as they are and which uninstall --purge must never remove.
require_dedicated_directory() {
    case "$directory" in /?*) ;; *) die '--dir 需要绝对路径，且不能是 /' ;; esac
    [ -e "$directory" ] || [ -L "$directory" ] || return 0
    [ -d "$directory" ] || die "$directory 不是目录，请用 --dir 指定新的或空目录"
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        case "${entry##*/}" in
            compose.image.yaml|compose.image.yaml.new|quietdesk-relay.sh|quietdesk-relay.sh.new|.env|.env.new|backups) ;;
            *) die "$directory 中已有其他文件，不能用作部署目录；请用 --dir 指定新的或空目录" ;;
        esac
    done
}

# Deployment files come from next to this script (release package or source checkout), otherwise from
# GitHub at the same ref as the image tag documentation. The installed copy refreshes them on upgrade.
prepare_directory() {
    require_dedicated_directory
    mkdir -p "$directory/backups"
    chmod 700 "$directory" "$directory/backups"
    here="$(script_directory)"
    target="$(CDPATH='' cd -- "$directory" && pwd -P)"
    if [ -n "$here" ] && [ "$here" != "$target" ] && [ -f "$here/compose.image.yaml" ]; then
        cp "$here/compose.image.yaml" "$directory/compose.image.yaml.new"
    elif fetch "$raw_base/$ref/relay/compose.image.yaml" > "$directory/compose.image.yaml.new" 2>/dev/null \
        && grep -q 'quietdesk-relay' "$directory/compose.image.yaml.new"; then
        :
    elif [ -f "$directory/compose.image.yaml" ]; then
        rm -f "$directory/compose.image.yaml.new"
        warn '无法下载最新部署配置，继续使用部署目录中的现有配置'
    else
        rm -f "$directory/compose.image.yaml.new"
        die "无法下载部署配置：$raw_base/$ref/relay/compose.image.yaml"
    fi
    [ ! -f "$directory/compose.image.yaml.new" ] || mv "$directory/compose.image.yaml.new" "$directory/compose.image.yaml"
    chmod 644 "$directory/compose.image.yaml"
    if [ -n "$here" ] && [ "$here" = "$target" ]; then
        :
    elif [ -n "$here" ]; then
        cp "$0" "$directory/quietdesk-relay.sh.new"
    elif ! { fetch "$raw_base/$ref/relay/quietdesk-relay.sh" > "$directory/quietdesk-relay.sh.new" 2>/dev/null \
        && grep -q '^QUIETDESK_RELAY_MANAGER=1$' "$directory/quietdesk-relay.sh.new"; }; then
        rm -f "$directory/quietdesk-relay.sh.new"
        warn '无法保存管理脚本副本，之后请重新下载脚本来升级或卸载'
    fi
    # Rename keeps a running copy of this script readable while it is replaced.
    if [ -f "$directory/quietdesk-relay.sh.new" ]; then
        chmod 755 "$directory/quietdesk-relay.sh.new"
        mv "$directory/quietdesk-relay.sh.new" "$directory/quietdesk-relay.sh"
    fi
}

check_port_free() {
    command -v ss >/dev/null 2>&1 || return 0
    if [ -n "$(ss -ltn "sport = :$port" 2>/dev/null | tail -n +2)" ] || [ -n "$(ss -lun "sport = :$port" 2>/dev/null | tail -n +2)" ]; then
        die "端口 $port 已被其他程序占用，请用 --port 指定其他端口"
    fi
}

backup_volumes() {
    stamp="$(date +%Y%m%d-%H%M%S)"
    docker run --rm --network none --user 0:0 --entrypoint sh \
        -v "${project}_state:/backup-source/state:ro" -v "${project}_tls:/backup-source/tls:ro" \
        -v "$directory/backups:/backup" "$1" \
        -c 'umask 077 && tar -czf "/backup/relay-$1.tar.gz" -C /backup-source state tls' sh "$stamp" \
        || die '数据备份失败，节点未做任何改动'
    printf '%s\n' "$1" > "$directory/backups/relay-$stamp.image"
    say "已备份接入码、证书和设备登记：$directory/backups/relay-$stamp.tar.gz"
}

show_info() {
    container="$(relay_container)"
    [ -n "$container" ] || die '未找到已安装的中继节点，请先运行 install'
    port="$(container_port "$container")"
    status="$(docker inspect --format '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' "$container")"
    revision="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$container" 2>/dev/null)" || revision=''
    case "$revision" in ''|'<no value>') revision='本地构建（无提交号）' ;; *) revision="$(printf '%.7s' "$revision")" ;; esac
    address="$(env_value QUIETDESK_RELAY_PUBLIC_ADDRESS)"
    [ -n "$address" ] || address="$(in_relay openssl x509 -in /etc/quietdesk-relay/fullchain.pem -noout -ext subjectAltName 2>/dev/null | certificate_address)" || address=''
    fingerprint="$(in_relay openssl x509 -in /etc/quietdesk-relay/fullchain.pem -noout -fingerprint -sha256 | sed 's/^.*=//')"
    expiry="$(in_relay openssl x509 -in /etc/quietdesk-relay/fullchain.pem -noout -enddate | sed 's/^notAfter=//')"
    case "$address" in *:*) url="tls://[$address]:$port" ;; '') url="tls://服务器IP:$port" ;; *) url="tls://$address:$port" ;; esac
    say ''
    say '==================== QuietDesk 中继节点 ===================='
    say "运行状态  $status"
    say "节点版本  $revision"
    say "服务地址  $url"
    if [ "${1:-}" = full ]; then
        say "接入码    $(in_relay cat /var/lib/quietdesk-relay/access.key)"
    else
        say '接入码    未变化（运行 info 可再次查看）'
    fi
    say "证书指纹  $fingerprint"
    say "证书到期  $expiry"
    if container_running; then
        health="$(docker exec "$container" wget -qO- -T 3 http://127.0.0.1:9091/healthz 2>/dev/null)" || health=''
        devices="$(printf '%s' "$health" | sed -n 's/.*"onlineDevices": *\([0-9]*\).*/\1/p')"
        sessions="$(printf '%s' "$health" | sed -n 's/.*"datagramSessions": *\([0-9]*\).*/\1/p')"
        assisted="$(printf '%s' "$health" | sed -n 's/.*"assistedLeases": *\([0-9]*\).*/\1/p')"
        if [ -z "$health" ]; then
            say '当前统计  健康端点无响应'
        elif [ -n "$assisted" ]; then
            say "当前统计  在线被控端 ${devices:-0} · UDP 视频会话 ${sessions:-0}（协商打洞 $assisted）"
        else
            say "当前统计  在线被控端 ${devices:-0} · 此版本不支持中继打洞，请运行 upgrade"
        fi
    fi
    say '==========================================================='
    if ! in_relay openssl x509 -in /etc/quietdesk-relay/fullchain.pem -noout -checkend 2592000 >/dev/null 2>&1; then
        warn '节点证书 30 天内到期或已过期，到期后两台 Mac 将无法连接'
    fi
    if [ "${1:-}" = full ]; then
        say '在两台 Mac 的 QuietDesk“中继设置”中：启用中继，填写上面的服务地址和接入码；'
        say '再点“获取并核对指纹…”，与上面的证书指纹逐项核对一致后勾选信任并保存。'
        say "云服务器还需在安全组或防火墙放行 TCP 和 UDP $port 端口。"
        say '接入码相当于节点密码，只发给你自己的 Mac，不要发到群聊或公开场合。'
    fi
    say "之后可运行 sudo sh $directory/quietdesk-relay.sh 选择升级、查看接入信息或卸载。"
}

cmd_install() {
    require_root
    require_linux
    [ -z "$ip" ] || validate_ip
    require_dedicated_directory
    ensure_docker install
    if [ -n "$(relay_container)" ]; then
        say '检测到已安装的中继节点，改为执行升级；接入码、证书和设备登记保持不变。'
        cmd_upgrade
        return
    fi
    [ -n "$port" ] || port="$(env_value QUIETDESK_RELAY_PORT)"
    port="${port:-7443}"
    validate_port
    check_port_free
    # A kept identity (uninstall without --purge) already names its address in the certificate.
    retained=false
    if docker volume inspect "${project}_tls" >/dev/null 2>&1; then retained=true; fi
    if [ -z "$ip" ] && [ "$retained" = false ]; then choose_public_ip; fi
    prepare_directory
    say "正在拉取节点镜像 $image ……"
    compose pull relay || die '拉取节点镜像失败，请检查服务器能否访问 ghcr.io'
    if [ -z "$ip" ]; then
        ip="$(docker run --rm --network none --entrypoint openssl -v "${project}_tls:/tls:ro" "$image" \
            x509 -in /tls/fullchain.pem -noout -ext subjectAltName 2>/dev/null | certificate_address)" || ip=''
        if [ -n "$ip" ]; then say "发现保留的节点证书，沿用原地址 $ip 和原接入码"; else choose_public_ip; fi
    fi
    write_env
    say '正在生成证书和接入码……'
    compose run --rm --no-deps --pull never -T provision --ip "$ip" < /dev/null \
        || die '证书或接入码初始化失败。若保留的证书属于其他 IP，请用 --ip 指定原地址，或运行 uninstall --purge 后重新安装（两台 Mac 需重新填写接入码并核对指纹）'
    say '正在启动节点……'
    start_relay || die "节点启动失败，可查看日志：docker compose -f $directory/compose.image.yaml logs --tail 100 relay"
    say '安装完成。'
    show_info full
}

cmd_upgrade() {
    require_root
    require_linux
    ensure_docker upgrade
    container="$(relay_container)"
    [ -n "$container" ] || die '未找到已安装的中继节点，请先运行 install'
    # The certificate and both Macs are bound to the installed address and port; an upgrade keeps them,
    # including for a node first deployed with deploy.sh.
    [ -z "$ip$port" ] || warn '升级不会更改地址或端口，已忽略 --ip/--port'
    port="$(container_port "$container")"
    port="${port:-7443}"
    ip="$(env_value QUIETDESK_RELAY_PUBLIC_ADDRESS)"
    [ -n "$ip" ] || ip="$(in_relay openssl x509 -in /etc/quietdesk-relay/fullchain.pem -noout -ext subjectAltName 2>/dev/null | certificate_address)" || ip=''
    old="$(docker inspect --format '{{.Image}}' "$container")"
    prepare_directory
    write_env
    say '正在检查新版本……'
    compose pull relay || die '拉取节点镜像失败，节点未做任何改动'
    new="$(docker image inspect --format '{{.Id}}' "$image")"
    if [ "$new" = "$old" ] && container_running; then
        say '已是最新版本，节点无需重启。'
        show_info
        return
    fi
    backup_volumes "$old"
    docker tag "$old" "$previous"
    say '正在启动新版本（当前中继连接会断开，两台 Mac 会自动或手动重新连接）……'
    if ! start_relay; then
        warn '新版本未能正常启动，正在回退到升级前的版本……'
        image="$previous"
        start_relay || die "回退也失败了。数据备份在 $directory/backups，可查看日志：docker compose -f $directory/compose.image.yaml logs --tail 100 relay"
        die '升级失败，已回退到升级前的版本，接入码和证书未改变'
    fi
    say '升级完成。'
    show_info
}

cmd_rollback() {
    require_root
    require_linux
    ensure_docker rollback
    container="$(relay_container)"
    [ -n "$container" ] || die '未找到已安装的中继节点'
    docker image inspect "$previous" >/dev/null 2>&1 || die '没有可回退的版本：只有通过本脚本升级后才会保留上一版本'
    port="$(container_port "$container")"
    port="${port:-7443}"
    [ -f "$directory/compose.image.yaml" ] || prepare_directory
    confirm '将回退到最近一次升级前的版本，当前中继连接会断开，是否继续' || { say '已取消'; return 0; }
    image="$previous"
    start_relay || die "回退失败，可查看日志：docker compose -f $directory/compose.image.yaml logs --tail 100 relay"
    say '已回退到上一版本。之后运行 upgrade 会再次升级到最新版本。'
    show_info
}

cmd_info() {
    require_root
    ensure_docker info
    show_info full
}

cmd_uninstall() {
    require_root
    require_linux
    ensure_docker uninstall
    confirm '确认卸载 QuietDesk 中继节点（当前中继连接会断开）' || { say '已取消'; return 0; }
    if [ "$purge" = false ] && interactive && confirm '是否同时永久删除接入码、证书、设备登记、备份和部署目录（默认保留，重装后沿用）'; then
        purge=true
    fi
    if [ "$purge" = true ] && [ "$assume_yes" = false ]; then
        if [ "$(ask '此操作不可恢复，重装后两台 Mac 需重新填写接入码并核对指纹。输入 DELETE 确认：')" != DELETE ]; then
            say '未输入 DELETE，只卸载容器，数据保留。'
            purge=false
        fi
    fi
    containers="$(docker ps -aq --filter "label=com.docker.compose.project=$project")"
    # The IDs are word-split on purpose; Docker prints one ID per line.
    [ -z "$containers" ] || docker rm -f $containers >/dev/null
    docker network rm "${project}_default" >/dev/null 2>&1 || true
    for reference in "$image" "$previous"; do docker image rm "$reference" >/dev/null 2>&1 || true; done
    if [ "$purge" = true ]; then
        for volume in "${project}_state" "${project}_tls"; do
            if docker volume inspect "$volume" >/dev/null 2>&1; then
                docker volume rm "$volume" >/dev/null || warn "无法删除数据卷 $volume，请手动检查"
            fi
        done
        # Remove only what this script wrote, in a directory it recognises by its generated .env, and the
        # directory itself once nothing else is left in it.
        case "$directory" in /?*) ;; *) die "拒绝删除目录：$directory" ;; esac
        if [ -f "$directory/.env" ] && grep -q '^# quietdesk-relay.sh' "$directory/.env"; then
            for entry in backups compose.image.yaml compose.image.yaml.new quietdesk-relay.sh quietdesk-relay.sh.new .env.new .env; do
                rm -rf -- "$directory/$entry"
            done
            rmdir -- "$directory" 2>/dev/null || warn "$directory 中还有其他文件，已保留这些文件和该目录"
        elif [ -d "$directory" ]; then
            warn "$directory 不是本脚本创建的部署目录，未删除"
        fi
        say '已卸载节点，并永久删除了接入码、证书、设备登记、备份和部署文件。Docker 本身保留。'
    else
        say '已卸载节点容器。Docker 本身保留。'
        say "接入码、证书和设备登记保留在 Docker 数据卷 ${project}_state、${project}_tls，备份在 $directory/backups；重新运行 install 会沿用它们。"
        say "如需永久删除：sudo sh $directory/quietdesk-relay.sh uninstall --purge"
    fi
}

menu() {
    interactive || { usage; exit 1; }
    say 'QuietDesk 中继节点一键管理'
    say '  1) 安装    2) 升级    3) 查看接入信息    4) 卸载    5) 回退到上一版本    0) 退出'
    case "$(ask '请选择 [0-5]：')" in
        1) command=install ;;
        2) command=upgrade ;;
        3) command=info ;;
        4) command=uninstall ;;
        5) command=rollback ;;
        *) exit 0 ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        install|upgrade|info|rollback|uninstall)
            [ -z "$command" ] || die '一次只能执行一个命令'
            command="$1" ;;
        --ip) [ "$#" -ge 2 ] || die '--ip 需要地址'; ip="$2"; shift ;;
        --ip=*) ip="${1#--ip=}" ;;
        --port) [ "$#" -ge 2 ] || die '--port 需要端口'; port="$2"; shift ;;
        --port=*) port="${1#--port=}" ;;
        --dir) [ "$#" -ge 2 ] || die '--dir 需要目录'; directory="$2"; shift ;;
        --dir=*) directory="${1#--dir=}" ;;
        --purge) purge=true ;;
        -y|--yes) assume_yes=true ;;
        -h|--help|help) usage; exit 0 ;;
        *) die "未知参数：$1（查看帮助：sh quietdesk-relay.sh --help）" ;;
    esac
    shift
done
[ -n "$command" ] || menu
[ "$purge" = false ] || [ "$command" = uninstall ] || die '--purge 只能与 uninstall 一起使用'
directory="${directory%/}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
case "$command" in
    install) cmd_install ;;
    upgrade) cmd_upgrade ;;
    info) cmd_info ;;
    rollback) cmd_rollback ;;
    uninstall) cmd_uninstall ;;
esac
