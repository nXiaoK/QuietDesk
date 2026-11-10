#!/usr/bin/env bash
set -euo pipefail

APP="${1:-dist/QuietDesk.app}"
REQ_OUT="$(codesign -d -r- "$APP" 2>&1 || true)"
echo "$REQ_OUT"

EXPECTED_SHA1="${QUIETDESK_SIGNING_LEAF_SHA1:-}"
if [[ -n "$EXPECTED_SHA1" ]]; then
    NORMALIZED_SHA1="$(printf '%s' "$EXPECTED_SHA1" | tr -d ': ' | tr '[:upper:]' '[:lower:]')"
    if ! printf '%s\n' "$REQ_OUT" | tr '[:upper:]' '[:lower:]' | grep -q "$NORMALIZED_SHA1"; then
        echo "ERROR: Certificate leaf SHA1 does not match QUIETDESK_SIGNING_LEAF_SHA1 ($EXPECTED_SHA1)" >&2
        exit 1
    fi
fi
echo "  [OK] Certificate pin check completed."
