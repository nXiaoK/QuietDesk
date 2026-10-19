#!/bin/sh
set -eu
umask 077

staging="$(mktemp -d)"
temporary_key=''
trap 'rm -rf "$staging"; if [ -n "$temporary_key" ]; then rm -f "$temporary_key"; fi' EXIT
tar -xf - -C "$staging"
openssl x509 -in "$staging/fullchain.pem" -noout -checkend 0 >/dev/null
openssl x509 -in "$staging/fullchain.pem" -pubkey -noout > "$staging/cert-public.pem"
openssl pkey -in "$staging/privkey.pem" -passin pass: -pubout > "$staging/key-public.pem"
if ! cmp -s "$staging/cert-public.pem" "$staging/key-public.pem"; then
    echo 'Certificate and private key do not match.' >&2
    exit 1
fi

state=/var/lib/quietdesk-relay
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
