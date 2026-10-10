#!/usr/bin/env bash
# covers: scripts/tailnet.sh
#
# tailnet.sh against a stubbed Tailscale API (curl on PATH). Checks the auth key
# request is single-use, ephemeral, pre-approved and tagged tag:round-vm; that
# only spill-* tag:round-vm devices are listed or deleted; and device-absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAILNET="$SCRIPT_DIR/tailnet.sh"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
ko() { echo "FAIL: $1"; fail=$((fail+1)); }

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
CALLS="$SCRATCH/calls"; : > "$CALLS"
cat > "$SCRATCH/curl" <<'STUB'
#!/bin/sh
# Record "METHOD URL BODY"; answer by URL.
method=GET; body=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift ;;
        --data) body="$2"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
echo "$method $url $body" >> "$CALLS"
case "$url" in
    */oauth/token) echo '{"access_token":"tok"}' ;;
    */keys) echo '{"key":"tskey-auth-XYZ"}' ;;
    */devices*) cat "$DEVICES_JSON" ;;
    */device/*) echo '{}' ;;
esac
STUB
chmod +x "$SCRATCH/curl"
export CALLS PATH="$SCRATCH:$PATH" TS_OAUTH_CLIENT_ID=cid TS_OAUTH_SECRET=sec
DEVICES_JSON="$SCRATCH/devices.json"; export DEVICES_JSON
cat > "$DEVICES_JSON" <<'JSON'
{"devices":[
 {"id":"1","hostname":"spill-aaaa","tags":["tag:round-vm"],"created":"2026-10-01T00:00:00Z"},
 {"id":"2","hostname":"round-vm-local","tags":["tag:round-vm"],"created":"2026-10-01T00:00:00Z"},
 {"id":"3","hostname":"spill-bbbb","tags":["tag:ci"],"created":"2026-10-01T00:00:00Z"}
]}
JSON

. "$TAILNET"

key="$(tailnet_mint_key)"
[ "$key" = "tskey-auth-XYZ" ] && ok "mint returns the key" || ko "mint returned '$key'"
req="$(grep ' /api/v2/tailnet/-/keys\| https://api.tailscale.com/api/v2/tailnet/-/keys' "$CALLS" | head -1)"
python3 - "$req" <<'PY' && ok "key is single-use, ephemeral, preauthorized, tag:round-vm" || ko "key request wrong: $req"
import json, sys
body = json.loads(sys.argv[1].split(" ", 2)[2])
c = body["capabilities"]["devices"]["create"]
assert c == {"reusable": False, "ephemeral": True, "preauthorized": True, "tags": ["tag:round-vm"]}, c
assert body["expirySeconds"] <= 900
PY

list="$(tailnet_list_spill_devices)"
[ "$(printf '%s\n' "$list" | awk '{print $2}')" = "spill-aaaa" ] \
    && ok "only spill-* tag:round-vm devices are listed" || ko "listed: $list"

: > "$CALLS"
n="$(tailnet_remove_by_hostname spill-aaaa)"
if [ "$n" = "1" ] && grep -q '^DELETE .*/api/v2/device/1 ' "$CALLS"; then ok "remove_by_hostname deletes the matching device"
else ko "remove_by_hostname n=$n calls=$(cat "$CALLS")"; fi

: > "$CALLS"
n="$(tailnet_remove_by_hostname round-vm-local)"
if [ "$n" = "0" ] && ! grep -q '^DELETE' "$CALLS"; then ok "a non-spill tag:round-vm device is never deleted"
else ko "non-spill device touched: n=$n calls=$(cat "$CALLS")"; fi

bash "$TAILNET" device-absent spill-aaaa >/dev/null 2>&1 && ko "device-absent passed for a present device" \
    || ok "device-absent fails while the device exists"
bash "$TAILNET" device-absent spill-gone >/dev/null 2>&1 && ok "device-absent passes when the device is gone" \
    || ko "device-absent failed for an absent device"

echo ""; echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
