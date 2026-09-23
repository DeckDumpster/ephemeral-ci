#!/usr/bin/env bash
#
# Destroy an ephemeral GitHub Actions runner VM via the Proxmox HTTP API.
# Exits zero if the VM is already gone — teardown runs under if: always()
# and must be idempotent, or every cancelled run reports a spurious failure.
#
# Usage:
#   teardown.sh <vmid>
#
# Guards, applied in order:
#   1. Empty or non-numeric argument → exit non-zero, API is never called.
#      A provision job that dies before emitting its output leaves the caller's
#      vmid variable empty; without this guard teardown runs with no id.
#   2. VMID equals TEMPLATE_VMID → exit non-zero, unconditionally.
#   3. VM does not exist (API returns 404) → exit 0. This guard runs before the
#      ownership guards so a second teardown call, after the first destroyed the
#      VM, exits 0 rather than 1 — teardown.sh must be safe to call twice
#      (db-1c4). A connection error or auth failure is NOT treated as 404; those
#      propagate as failures so a broken API does not silently claim everything
#      is already gone.
#   3b. VM config carries template:1 → exit non-zero, unconditionally. The id
#       in TEMPLATE_VMID is configuration and can be wrong (db-69kx: the real
#       template was 9100 while the default was 101). The Proxmox template flag
#       is a fact about the VM written by the hypervisor itself and cannot be
#       falsified by a misconfigured environment variable.
#   4. VM name does not match gh-runner-<vmid> → exit non-zero. A clone that
#      failed and left the id pointing at an unrelated VM must not be purged.
#      Name is read from the API config JSON fetched in guard 3, not by parsing
#      qm output, and needs no extra API call — so it runs before guard 5.
#   4b. VM description does not contain the ownership token ($VM_TOKEN) stamped
#      at provision time → exit non-zero (db-ogjn). The name guard above is
#      vacuous for recycled VMIDs: both the stale and the current VM are named
#      gh-runner-<vmid>, so name alone passes trivially. The token is unique per
#      provision and unknown to any caller that did not participate in that
#      specific clone, closing the recycling window regardless of VMID reuse.
#   5. VM is not a member of PVE_POOL → exit non-zero. Read from the hypervisor
#      via GET /pools/<pool>. This replaced a ledger file on the local
#      filesystem, which could not work once provision and teardown became
#      separate jobs on separate ephemeral runners: the file provision wrote
#      never existed here, so every teardown refused. Pool membership cannot go
#      stale, cannot vanish with a runner, and cannot be forged by anything
#      this workflow controls.
#
# Environment variables:
#   TEMPLATE_VMID          — source VM template id; required, no default
#   PVE_POOL               — pool every runner VM must belong to
#                            (default: ephemeral-ci)
#   CRED_FILE              — credential file to source
#                            (default: /etc/gh-ephemeral-runner/token)
#   PVE_NODE               — Proxmox node name (required)
#   PVE_TOKEN_ID           — API token id, e.g. gh-runner@pve!teardown (required)
#   PVE_TOKEN_SECRET       — API token secret UUID (required)
#   VM_TOKEN               — ownership token emitted by provision.sh (optional);
#                            when set, must match vmtoken= in the VM description
#                            (guard 4b). When unset and the VM carries no token,
#                            degrades to name-only check with a loud warning
#                            (db-rzdr). When unset but the VM carries a token,
#                            refuses — a new-provision/old-teardown pair.
#   PVE_API_HOST           — Proxmox API hostname or IP (default: localhost)
#   PVE_API_PORT           — Proxmox API port (default: 8006)
#   STOP_TIMEOUT           — seconds to wait for orderly stop before escalating
#                            to a force-stop (default: 60)
#   STOP_POLL_INTERVAL     — seconds between stop-task status polls (default: 2)
#   FORCE_STOP_WAIT        — seconds to wait after force-stop before checking
#                            whether the VM actually stopped (default: 5)
#   PVAPI_SH               — path to pvapi.sh; defaults to the directory
#                            containing this script (used by tests to inject a
#                            mock without touching the real API)
#   CRED_FILE              — credential file to source (default:
#                            /etc/gh-ephemeral-runner/token); sourced before
#                            the defaults below so TEMPLATE_VMID set there
#                            overrides the compiled-in default of 101.

set -euo pipefail

CRED_FILE="${CRED_FILE:-/etc/gh-ephemeral-runner/token}"
if [ -f "$CRED_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CRED_FILE"
fi

PVE_POOL="${PVE_POOL:-ephemeral-ci}"
CRED_FILE="${CRED_FILE:-/etc/gh-ephemeral-runner/token}"
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"
STOP_POLL_INTERVAL="${STOP_POLL_INTERVAL:-2}"
FORCE_STOP_WAIT="${FORCE_STOP_WAIT:-5}"
JOURNAL_TIMEOUT="${JOURNAL_TIMEOUT:-30}"
JOURNAL_POLL_INTERVAL="${JOURNAL_POLL_INTERVAL:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pvapi.sh
. "${PVAPI_SH:-${SCRIPT_DIR}/pvapi.sh}"

# Source credentials. Fail fast with a named cause before calling pvapi() --
# an unset variable and a dead API look the same at the curl layer.
if [ -f "$CRED_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CRED_FILE"
fi

_require_env() {
    local var="$1"
    if [ -z "${!var:-}" ]; then
        echo "teardown.sh: $var is not set" >&2
        exit 1
    fi
}
for _v in PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET TEMPLATE_VMID; do
    _require_env "$_v"
done

if [ $# -ne 1 ]; then
    echo "Usage: teardown.sh <vmid>" >&2
    exit 1
fi

VMID="$1"

# Guard 1: argument must be a non-empty integer.
if [ -z "$VMID" ] || ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    echo "teardown.sh: refusing empty or non-numeric VMID: '$VMID'" >&2
    exit 1
fi

# Guard 2: refuse the template unconditionally.
if [ "$VMID" -eq "$TEMPLATE_VMID" ]; then
    echo "teardown.sh: refusing to destroy template VMID $TEMPLATE_VMID" >&2
    exit 1
fi

# Extract a field from PVAPI_BODY (.data.<field>).
_body_field() {
    local field="$1"
    printf '%s' "$PVAPI_BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('data', {}).get('$field', ''))
" 2>/dev/null || true
}
# Extract PVAPI_BODY .data when it is a plain string (e.g. UPID from stop).
_body_data_str() {
    printf '%s' "$PVAPI_BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin).get('data', '')
print(d if isinstance(d, str) else '')
" 2>/dev/null || true
}

# Pull the guest journal over the qemu-guest-agent before the VM is stopped.
# Must never return non-zero — a leaked VM costs more than a missing diagnostic.
# Bounded by JOURNAL_TIMEOUT seconds because the guest may be wedged.
_capture_journal() {
    local timeout="${JOURNAL_TIMEOUT:-30}" poll_interval="${JOURNAL_POLL_INTERVAL:-1}"
    echo "teardown.sh: capturing guest journal from VM $VMID (timeout ${timeout}s)" >&2

    pvapi POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/exec" \
        --data-urlencode "command=/bin/sh" \
        --data-urlencode "command=-c" \
        --data-urlencode "command=journalctl -b --no-pager | tail -n 500" || {
        echo "teardown.sh: guest-agent exec call failed (HTTP ${PVAPI_STATUS:-none}) — journal unavailable" >&2
        return 0
    }
    if [ "$PVAPI_STATUS" != "200" ]; then
        echo "teardown.sh: guest-agent exec returned HTTP $PVAPI_STATUS — journal unavailable" >&2
        return 0
    fi

    local pid
    pid="$(printf '%s' "$PVAPI_BODY" | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("data",{}).get("pid",""))' \
        2>/dev/null || true)"
    if [ -z "$pid" ]; then
        echo "teardown.sh: guest-agent returned no pid — journal unavailable" >&2
        return 0
    fi

    local _deadline
    _deadline=$(( $(date +%s) + timeout ))
    while true; do
        pvapi GET "/nodes/${PVE_NODE}/qemu/${VMID}/agent/exec-status?pid=${pid}" || {
            echo "teardown.sh: exec-status poll failed — journal unavailable" >&2
            return 0
        }
        if [ "$PVAPI_STATUS" = "200" ]; then
            local _exited
            _exited=$(printf '%s' "$PVAPI_BODY" | python3 -c \
                'import json,sys; print(json.load(sys.stdin).get("data",{}).get("exited",0))' \
                2>/dev/null || echo 0)
            if [ "$_exited" = "1" ]; then
                echo "teardown.sh: --- guest journal ---" >&2
                printf '%s' "$PVAPI_BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data", {})
for k in ("out-data", "err-data"):
    if d.get(k):
        sys.stdout.write(d[k])
' >&2 || true
                echo "teardown.sh: --- end guest journal ---" >&2
                return 0
            fi
        fi
        if [ "$(date +%s)" -ge "$_deadline" ]; then
            echo "teardown.sh: guest-agent timed out after ${timeout}s — journal unavailable" >&2
            return 0
        fi
        sleep "$poll_interval"
    done
}

# Guard 3: check host state before the ownership guards.
# A 404 means the VM is already gone — idempotent exit.
# A connection error or non-404 HTTP error is not "already gone"; it propagates.
pvapi GET "/nodes/${PVE_NODE}/qemu/${VMID}/config" || {
    echo "teardown.sh: API connection failed — cannot determine VM state" >&2
    exit 1
}

if [ "$PVAPI_STATUS" = "404" ]; then
    echo "teardown.sh: VM $VMID not found via API — already gone" >&2
    exit 0
fi

if [ "$PVAPI_STATUS" != "200" ]; then
    echo "teardown.sh: GET config returned HTTP $PVAPI_STATUS — refusing" >&2
    exit 1
fi

CONFIG_BODY="$PVAPI_BODY"

# Guard 3b: refuse any VM whose config reports template:1, regardless of
# TEMPLATE_VMID. The id is configuration and can be wrong; the template flag
# is a fact about the VM written by Proxmox itself when the VM was converted.
IS_TEMPLATE=$(printf '%s' "$CONFIG_BODY" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('data', {}).get('template', 0))
" 2>/dev/null || echo 0)
if [ "${IS_TEMPLATE:-0}" = "1" ]; then
    echo "teardown.sh: VM $VMID has template:1 in its config — refusing unconditionally" >&2
    exit 1
fi

# Guard 4: VM name must match what provision.sh set. Read from the config
# already fetched above -- no extra API call, so it runs before the pool check.
EXPECTED_NAME="gh-runner-${VMID}"
ACTUAL_NAME=$(printf '%s' "$CONFIG_BODY" | python3 -c "
import json, sys
print(json.load(sys.stdin).get('data', {}).get('name', ''))
" 2>/dev/null || true)
if [ "$ACTUAL_NAME" != "$EXPECTED_NAME" ]; then
    echo "teardown.sh: VM $VMID name is '$ACTUAL_NAME', expected '$EXPECTED_NAME' — refusing" >&2
    exit 1
fi

# Guard 4b: ownership token in the VM description must match $VM_TOKEN.
#
# The name check above is vacuous for a recycled VMID: Proxmox allocates the
# lowest free id, so a VM freed by the reaper and reallocated to a new run gets
# the same name as the old one (gh-runner-<vmid>), and the stale teardown from
# the cancelled run passes trivially. The token is a random hex value written
# into the VM description at provision time; teardown must hold the same token
# to prove it participated in that specific clone (db-ogjn).
#
# Degradation (db-rzdr): VM_TOKEN is optional at the action level so that the
# action remains a drop-in on @v1 for consumers that have not yet wired the
# new output. Three cases:
#   • VM_TOKEN set and matches STORED_TOKEN → allow.
#   • VM_TOKEN set, doesn't match (or VM has no token) → refuse.
#   • VM_TOKEN unset, VM HAS a token → refuse: new VM, unupgraded caller.
#   • VM_TOKEN unset, VM has no token → degrade to name-only check, warn loudly.
STORED_TOKEN=$(printf '%s' "$CONFIG_BODY" | python3 -c "
import json, re, sys
desc = json.load(sys.stdin).get('data', {}).get('description', '')
m = re.search(r'vmtoken=([a-f0-9]+)', desc)
print(m.group(1) if m else '')
" 2>/dev/null || true)
if [ -n "${VM_TOKEN:-}" ]; then
    if [ "$STORED_TOKEN" != "$VM_TOKEN" ]; then
        echo "teardown.sh: VM $VMID ownership token does not match — refusing" >&2
        exit 1
    fi
elif [ -n "$STORED_TOKEN" ]; then
    echo "teardown.sh: VM $VMID carries an ownership token but VM_TOKEN is unset — refusing (db-rzdr)" >&2
    exit 1
else
    echo "teardown.sh: WARNING: no ownership token on VM $VMID or in caller; falling back to name-only check. Wire vm-token from provision to teardown to enable full ownership verification (db-rzdr)." >&2
fi

# Guard 5: pool membership, read from the hypervisor.
#
# This replaced a ledger file on the local filesystem. That worked while all
# three scripts ran on the hypervisor and shared it; it cannot work now that
# provision and teardown are separate jobs on separate ephemeral runners, so
# the file provision wrote no longer exists here and every teardown refused.
#
# Pool membership is strictly stronger than the ledger was: it cannot go stale,
# cannot vanish with a runner, and cannot be forged by anything this workflow
# controls. The API token's ACL is already scoped to this pool, so a VM outside
# it is unreachable regardless -- this turns that into an explicit refusal with
# a readable message rather than a 403 from whatever call happens to run first.
pvapi GET "/pools/${PVE_POOL}" || {
    echo "teardown.sh: API connection failed reading pool $PVE_POOL" >&2
    exit 1
}
if [ "$PVAPI_STATUS" != "200" ]; then
    echo "teardown.sh: GET /pools/$PVE_POOL returned HTTP $PVAPI_STATUS — refusing" >&2
    exit 1
fi
IN_POOL=$(printf '%s' "$PVAPI_BODY" | VMID="$VMID" python3 -c "
import json, os, sys
want = int(os.environ['VMID'])
members = json.load(sys.stdin).get('data', {}).get('members', []) or []
print('yes' if any(m.get('vmid') == want for m in members) else 'no')
" 2>/dev/null || echo no)
if [ "$IN_POOL" != "yes" ]; then
    echo "teardown.sh: VM $VMID is not a member of pool $PVE_POOL — refusing" >&2
    exit 1
fi

# Pull the guest journal before the VM is gone. Must not fail teardown.
_capture_journal || true

# --- Stop ---
#
# POST returns a UPID immediately; it does not wait for the guest to halt.
# Poll the task until it is done, then confirm the VM's own status is stopped
# before calling DELETE. Calling DELETE on a running VM is refused by the API,
# so a guest that ignores ACPI shutdown (wedged kernel, mid-build runner) must
# be force-stopped rather than passed straight to destroy.
echo "teardown.sh: stopping VM $VMID" >&2
pvapi POST "/nodes/${PVE_NODE}/qemu/${VMID}/status/stop" || {
    echo "teardown.sh: stop API call failed" >&2
    exit 1
}
if [ "$PVAPI_STATUS" != "200" ]; then
    echo "teardown.sh: stop request returned HTTP $PVAPI_STATUS" >&2
    exit 1
fi
UPID=$(_body_data_str)

# Poll task status.
_deadline=$(( $(date +%s) + STOP_TIMEOUT ))
echo "teardown.sh: waiting for VM $VMID to stop (timeout ${STOP_TIMEOUT}s)" >&2
while true; do
    pvapi GET "/nodes/${PVE_NODE}/tasks/${UPID}/status" || true
    if [ "$PVAPI_STATUS" = "200" ]; then
        TASK_STATUS=$(_body_field status)
        if [ "$TASK_STATUS" = "stopped" ]; then
            TASK_EXIT=$(_body_field exitstatus)
            [ "$TASK_EXIT" = "OK" ] || echo "teardown.sh: stop task exitstatus='$TASK_EXIT'" >&2
            break
        fi
    fi
    if [ "$(date +%s)" -ge "$_deadline" ]; then
        echo "teardown.sh: stop timed out after ${STOP_TIMEOUT}s — escalating to force-stop" >&2
        pvapi POST "/nodes/${PVE_NODE}/qemu/${VMID}/status/stop" '{"forceStop":1}' || true
        sleep "$FORCE_STOP_WAIT"
        break
    fi
    sleep "$STOP_POLL_INTERVAL"
done

# Confirm the VM is actually stopped before issuing DELETE.
pvapi GET "/nodes/${PVE_NODE}/qemu/${VMID}/status/current" || {
    echo "teardown.sh: could not read VM status before destroy" >&2
    exit 1
}
VM_STATUS=$(_body_field status)
if [ "$VM_STATUS" != "stopped" ]; then
    echo "teardown.sh: VM $VMID is '$VM_STATUS' after stop — refusing destroy" >&2
    exit 1
fi

# --- Destroy ---
echo "teardown.sh: destroying VM $VMID" >&2
pvapi DELETE "/nodes/${PVE_NODE}/qemu/${VMID}?purge=1" || {
    echo "teardown.sh: destroy API call failed" >&2
    exit 1
}
if [ "$PVAPI_STATUS" != "200" ]; then
    echo "teardown.sh: destroy returned HTTP $PVAPI_STATUS" >&2
    exit 1
fi

echo "teardown.sh: VM $VMID destroyed" >&2
