#!/usr/bin/env bash
set -euo pipefail
set +x

STATE_DIR="${QUIETDESK_CI_CERT_STATE:-}"
KEYCHAIN_PATH="${QUIETDESK_CI_KEYCHAIN:-}"

if [[ -n "$STATE_DIR" && -f "$STATE_DIR/previous-keychains.txt" ]]; then
    PREVIOUS_KEYCHAINS=()
    while IFS= read -r item; do
        [[ -n "$item" ]] && PREVIOUS_KEYCHAINS+=("$item")
    done < "$STATE_DIR/previous-keychains.txt"
    if [[ ${#PREVIOUS_KEYCHAINS[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${PREVIOUS_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    fi
fi

if [[ -n "$KEYCHAIN_PATH" ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi

if [[ -n "$STATE_DIR" && -d "$STATE_DIR" ]]; then
    rm -rf "$STATE_DIR"
fi
