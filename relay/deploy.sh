#!/bin/sh
set -eu
umask 077

pull=false
if [ "${1:-}" = --pull ]; then
    pull=true
    shift
fi
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 [--pull] --ip SERVER_IP | [--pull] /path/to/fullchain.pem /path/to/privkey.pem" >&2
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
if [ ! -f "$deployment/compose.yaml" ]; then pull=true; fi
configuration=compose.yaml
if [ "$pull" = true ]; then configuration=compose.image.yaml; fi
if [ ! -r "$deployment/$configuration" ]; then
    echo "Missing $configuration; download the matching deployment configuration first." >&2
    exit 1
fi
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
if [ "$pull" = true ]; then
    docker compose -f "$configuration" pull relay
else
    docker compose -f "$configuration" build relay
fi
# Provision only after a complete archive has been created successfully.
if [ "$automatic" = true ]; then
    docker compose -f "$configuration" run --rm --no-deps --pull never -T provision --ip "$2" < /dev/null
else
    COPYFILE_DISABLE=1 tar -cf "$staging/tls.tar" -C "$staging" fullchain.pem privkey.pem
    docker compose -f "$configuration" run --rm --no-deps --pull never -T provision < "$staging/tls.tar"
fi
docker compose -f "$configuration" up -d --no-build --pull never --force-recreate --wait --wait-timeout 60 relay
echo 'Relay is healthy. Retrieve the access key privately with:'
echo "  docker compose -f \"$deployment/$configuration\" exec -T relay cat /var/lib/quietdesk-relay/access.key"
