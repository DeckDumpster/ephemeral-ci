#!/usr/bin/env bash
# Tailnet helpers for EC2 spill runners (sp-7330sk).
#
# Sourced by provision.sh, teardown.sh and reap.sh; also runnable:
#   tailnet.sh device-absent <hostname>     exit 0 when no device has that name
#
# An EC2 spill runner that asks for the tailnet joins it as tag:round-vm under
# the hostname spill-<vmtoken>. That hostname is the whole contract between the
# three scripts: provision mints a key for it, teardown deletes it by name, and
# the reaper deletes any spill-* device whose instance is gone. The prefix is
# also what keeps the reaper away from tag:round-vm devices that are not spill
# runners (Spira's own round VMs carry the same tag).
#
# Environment:
#   TS_OAUTH_CLIENT_ID, TS_OAUTH_SECRET  the Tailscale OAuth client. Its scopes
#                                        must include auth_keys (write) and
#                                        devices:core (write) with tag:round-vm.
#   TAILNET_API                          default https://api.tailscale.com
set -uo pipefail

TAILNET_API="${TAILNET_API:-https://api.tailscale.com}"
TAILNET_HOST_PREFIX="spill-"
TAILNET_TAG="tag:round-vm"

tailnet_hostname() { printf '%s%s' "$TAILNET_HOST_PREFIX" "$1"; }

# curl wrapper: print the response body on 2xx; otherwise name the HTTP status
# and the API's own message on stderr and fail. curl -f would discard the body,
# leaving a policy fault (a 400 naming the tag or scope) to read as a JSON
# decode error downstream.
_tailnet_curl() {
    local what="$1" out code body msg
    shift
    out="$(curl -sS --max-time 30 -w '\n%{http_code}' "$@")" || return 1
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"
    case "$code" in
        2??) printf '%s' "$body"; return 0 ;;
    esac
    msg="$(printf '%s' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    print(json.loads(raw).get("message") or raw.strip()[:300])
except Exception:
    print(raw.strip()[:300])' 2>/dev/null)"
    printf 'tailnet.sh: %s failed: HTTP %s: %s\n' "$what" "$code" "$msg" >&2
    return 1
}

# Print a short-lived API access token for the OAuth client.
_tailnet_access_token() {
    : "${TS_OAUTH_CLIENT_ID:?TS_OAUTH_CLIENT_ID is not set}"
    : "${TS_OAUTH_SECRET:?TS_OAUTH_SECRET is not set}"
    _tailnet_curl "OAuth token request" "${TAILNET_API}/api/v2/oauth/token" \
        --data-urlencode "client_id=${TS_OAUTH_CLIENT_ID}" \
        --data-urlencode "client_secret=${TS_OAUTH_SECRET}" \
        --data-urlencode "grant_type=client_credentials" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# Authenticated API call: _tailnet_api METHOD PATH [JSON-BODY]
_tailnet_api() {
    local method="$1" path="$2" body="${3:-}" token
    token="$(_tailnet_access_token)" || return 1
    if [ -n "$body" ]; then
        _tailnet_curl "$method $path" -X "$method" "${TAILNET_API}${path}" \
            -H "Authorization: Bearer ${token}" \
            -H 'Content-Type: application/json' --data "$body"
    else
        _tailnet_curl "$method $path" -X "$method" "${TAILNET_API}${path}" \
            -H "Authorization: Bearer ${token}"
    fi
}

# Print a single-use, ephemeral, pre-approved tag:round-vm auth key that
# expires in 15 minutes whether or not it is used.
tailnet_mint_key() {
    local body
    body="$(python3 -c '
import json
print(json.dumps({
    "expirySeconds": 900,
    "capabilities": {"devices": {"create": {
        "reusable": False, "ephemeral": True, "preauthorized": True,
        "tags": ["tag:round-vm"]}}}}))')"
    _tailnet_api POST /api/v2/tailnet/-/keys "$body" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])'
}

# Print one "<id> <hostname> <created-epoch>" line per tag:round-vm device
# whose hostname carries the spill prefix.
tailnet_list_spill_devices() {
    _tailnet_api GET '/api/v2/tailnet/-/devices?fields=default' \
        | python3 -c '
import json, sys
from datetime import datetime
for d in json.load(sys.stdin).get("devices", []):
    host = d.get("hostname", "")
    if "'"$TAILNET_TAG"'" not in (d.get("tags") or []) or not host.startswith("'"$TAILNET_HOST_PREFIX"'"):
        continue
    try:
        created = int(datetime.fromisoformat(d["created"].replace("Z", "+00:00")).timestamp())
    except Exception:
        created = 0
    print(d["id"], host, created)'
}

tailnet_delete_device() { _tailnet_api DELETE "/api/v2/device/$1" >/dev/null; }

# Delete every spill device with this hostname. Prints how many were removed.
tailnet_remove_by_hostname() {
    local host="$1" id name created n=0 list
    list="$(tailnet_list_spill_devices)" || return 1
    while read -r id name created; do
        [ "$name" = "$host" ] || continue
        tailnet_delete_device "$id" || return 1
        n=$(( n + 1 ))
    done <<< "$list"
    printf '%s' "$n"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        device-absent)
            list="$(tailnet_list_spill_devices)" || exit 2
            if printf '%s\n' "$list" | awk -v h="${2:?hostname required}" '$2==h{f=1} END{exit !f}'; then
                echo "tailnet device $2 is still present" >&2
                exit 1
            fi
            ;;
        *) echo "usage: tailnet.sh device-absent <hostname>" >&2; exit 2 ;;
    esac
fi
