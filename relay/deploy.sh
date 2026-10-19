#!/bin/sh
set -eu
umask 077

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 --ip SERVER_IP | /path/to/fullchain.pem /path/to/privkey.pem" >&2
    exit 1
fi
automatic=false
if [ "$1" = --ip ]; then
    automatic=true
    case "$2" in
        ''|*[!0-9a-fA-F:.]*) echo 'Expected an IPv4 or IPv6 address without brackets or port.' >&2; exit 1 ;;
    esac
fi
if [ "$automatic" = false ]; then
for source in "$1" "$2"; do
    if [ ! -f "$source" ] || [ ! -r "$source" ]; then
        echo 'Certificate and private key must be readable files.' >&2
        exit 1
    fi
done
fi

deployment="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
mkdir -p "$deployment/../work"
staging="$(mktemp -d "$deployment/../work/relay-deploy.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
# Follow certificate-manager symlinks on the host; no host directory is mounted.
if [ "$automatic" = false ]; then
    cp -L "$1" "$staging/fullchain.pem"
    cp -L "$2" "$staging/privkey.pem"
    chmod 600 "$staging/fullchain.pem" "$staging/privkey.pem"
fi
cd "$deployment"
docker compose version >/dev/null
docker info >/dev/null
docker compose -f compose.yaml build relay
# Provision only after a complete archive has been created successfully.
if [ "$automatic" = true ]; then
    docker compose -f compose.yaml run --rm --no-deps -T provision --ip "$2" < /dev/null
else
    tar -cf "$staging/tls.tar" -C "$staging" fullchain.pem privkey.pem
    docker compose -f compose.yaml run --rm --no-deps -T provision < "$staging/tls.tar"
fi
docker compose -f compose.yaml up -d --no-build --force-recreate --wait --wait-timeout 60 relay
echo 'Relay is healthy. Retrieve the access key privately with:'
echo "  docker compose -f \"$deployment/compose.yaml\" exec -T relay cat /var/lib/quietdesk-relay/access.key"
