#!/bin/sh
set -eu
umask 077

staging="$(mktemp -d)"
temporary_key=''
state=/var/lib/quietdesk-relay
trap 'rm -rf "$staging"; if [ -n "$temporary_key" ]; then rm -f "$temporary_key"; fi' EXIT
if [ "$#" -eq 2 ] && [ "$1" = --ip ]; then
    case "$2" in
        ''|*[!0-9a-fA-F:.]*) echo 'Expected an IPv4 or IPv6 address.' >&2; exit 1 ;;
    esac
    if [ -e /etc/quietdesk-relay/fullchain.pem ] && [ -e /etc/quietdesk-relay/privkey.pem ]; then
        cp /etc/quietdesk-relay/fullchain.pem /etc/quietdesk-relay/privkey.pem "$staging/"
    elif [ -e /etc/quietdesk-relay/fullchain.pem ] || [ -e /etc/quietdesk-relay/privkey.pem ]; then
        echo 'Incomplete TLS identity; restore both certificate and private key.' >&2
        exit 1
    else
        if [ -e "$state/access.key" ] || [ -L "$state/access.key" ] || [ -e "$state/devices.json" ] || [ -L "$state/devices.json" ]; then
            echo 'Existing relay state has no TLS identity; restore it or provide a replacement certificate explicitly.' >&2
            exit 1
        fi
        openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
            -subj '/CN=QuietDesk Relay' -addext "subjectAltName=IP:$2" \
            -addext 'basicConstraints=critical,CA:FALSE' \
            -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
            -addext 'extendedKeyUsage=serverAuth' \
            -keyout "$staging/privkey.pem" -out "$staging/fullchain.pem" 2> "$staging/generation.log" || {
                echo 'Cannot generate certificate; verify the IPv4 or IPv6 address.' >&2
                exit 1
            }
    fi
    openssl x509 -in "$staging/fullchain.pem" -noout -checkip "$2" >/dev/null || {
        echo 'Saved certificate does not match this IP; provide a replacement certificate explicitly.' >&2
        exit 1
    }
elif [ "$#" -eq 0 ]; then
    tar -xf - -C "$staging"
else
    echo 'Usage: provision-relay [--ip SERVER_IP]' >&2
    exit 1
fi
openssl x509 -in "$staging/fullchain.pem" -noout -checkend 0 >/dev/null
openssl x509 -in "$staging/fullchain.pem" -pubkey -noout > "$staging/cert-public.pem"
openssl pkey -in "$staging/privkey.pem" -passin pass: -pubout > "$staging/key-public.pem"
if ! cmp -s "$staging/cert-public.pem" "$staging/key-public.pem"; then
    echo 'Certificate and private key do not match.' >&2
    exit 1
fi

if [ ! -e "$state/access.key" ] && [ ! -L "$state/access.key" ]; then
    if [ -e "$state/devices.json" ] || [ -L "$state/devices.json" ]; then
        echo 'Device registry exists without an access key; restore the original access key first.' >&2
        exit 1
    fi
    openssl rand -hex 32 > "$staging/access.key"
    # Publish without replacing a credential created by another deployment.
    temporary_key="$(mktemp "$state/.access-key.XXXXXX")"
    cp "$staging/access.key" "$temporary_key"
    ln "$temporary_key" "$state/access.key"
    rm "$temporary_key"
    temporary_key=''
fi

cp "$staging/fullchain.pem" /etc/quietdesk-relay/fullchain.pem
cp "$staging/privkey.pem" /etc/quietdesk-relay/privkey.pem
chmod 600 /etc/quietdesk-relay/fullchain.pem /etc/quietdesk-relay/privkey.pem
echo 'Relay certificate installed; existing access key and device registry retained.'
openssl x509 -in /etc/quietdesk-relay/fullchain.pem -noout -fingerprint -sha256
