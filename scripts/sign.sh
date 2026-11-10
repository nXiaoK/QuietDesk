#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT_DIR/dist/QuietDesk.app}"
REQUIRE_CERT="${QUIETDESK_REQUIRE_CERT:-0}"
if [[ "${2:-}" == "--require-cert" ]]; then
    REQUIRE_CERT=1
fi

CONFIG_FILE="${QUIETDESK_SIGNING_CONFIG:-$HOME/.config/QuietDesk/signing.env}"
if [[ -z "${SIGNING_IDENTITY:-}" && -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

resolve_identity() {
    if [[ "${QUIETDESK_ADHOC_SIGNING:-0}" == "1" ]]; then
        printf '%s\n' "-"
        return 0
    fi
    if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
        printf '%s\n' "$SIGNING_IDENTITY"
        return 0
    fi
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    local candidate
    for candidate in "QuietDesk Self-Signed Code Signing" "RDesk Self-Signed Code Signing"; do
        local match
        match="$(printf '%s\n' "$identities" | awk -v name="\"$candidate\"" '$0 ~ name { print $2; exit }')"
        if [[ -n "$match" ]]; then
            printf '%s\n' "$match"
            return 0
        fi
    done
    printf '%s\n' "-"
}

IDENTITY="$(resolve_identity)"

if [[ "$IDENTITY" == "-" ]]; then
    if [[ "$REQUIRE_CERT" == "1" ]]; then
        echo "HUMAN-ACTION: 未在钥匙串中找到本地代码签名证书；请先运行 ./scripts/setup-cert.sh 生成并信任证书。" >&2
        exit 1
    fi
    codesign --force --sign - "$APP"
elif [[ "$IDENTITY" == Developer\ ID* ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
"$ROOT_DIR/scripts/check-cert-pin.sh" "$APP"
