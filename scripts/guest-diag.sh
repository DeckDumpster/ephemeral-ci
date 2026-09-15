#!/usr/bin/env bash
#
# guest-diag.sh <vmid>
#
# Dumps the state of a runner guest through the qemu guest agent. Intended to
# run when a runner fails to register, BEFORE teardown destroys the VM.
#
# WHY THIS EXISTS. A registration failure is otherwise completely blind: the VM
# is on an internal bridge with no inbound SSH, the job that provisioned it has
# already exited, and teardown removes the machine seconds later. Every earlier
# failure in this system was diagnosed by rebuilding the VM by hand and looking
# — which cost hours each time and is not available to CI at all.
#
# Reads only. Never destroys, never registers, never returns non-zero for a
# guest that is simply broken: the caller is already failing and this must not
# mask the original error.
set -uo pipefail

VMID="${1:-}"
[ -n "$VMID" ] || { echo "guest-diag.sh: no VMID given" >&2; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pvapi.sh
. "${PVAPI_SH:-${SCRIPT_DIR}/pvapi.sh}"

CRED_FILE="${CRED_FILE:-/etc/gh-ephemeral-runner/token}"
[ -f "$CRED_FILE" ] && . "$CRED_FILE"
: "${PVE_NODE:?PVE_NODE not set}"

# Run a command in the guest and print its output.
#
# agent/exec returns a pid, not output. The result has to be collected from
# agent/exec-status, and it is not ready immediately — treating the pid as the
# answer is why an earlier attempt at this returned nothing useful.
_guest() {
    local label="$1"; shift
    local args=() a pid i
    for a in "$@"; do args+=(--data-urlencode "command=$a"); done

    printf '\n===== %s =====\n' "$label"
    if ! pvapi POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/exec" "${args[@]}" >/dev/null; then
        printf '(exec call failed: HTTP %s)\n' "${PVAPI_STATUS:-none}"
        return 0
    fi
    pid="$(printf '%s' "$PVAPI_BODY" | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("data",{}).get("pid",""))' 2>/dev/null)"
    [ -n "$pid" ] || { printf '(no pid returned)\n'; return 0; }

    for i in $(seq 1 15); do
        pvapi GET "/nodes/${PVE_NODE}/qemu/${VMID}/agent/exec-status?pid=${pid}" >/dev/null || break
        printf '%s' "$PVAPI_BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin).get("data", {})
if not d.get("exited"):
    raise SystemExit(3)
for k in ("out-data", "err-data"):
    if d.get(k):
        print(d[k])
print("(exit code %s)" % d.get("exitcode", "?"))
' && return 0
        sleep 1
    done
    printf '(command did not finish within 15s)\n'
}

printf 'guest-diag: VM %s on node %s\n' "$VMID" "$PVE_NODE"

_guest "is the injected file there, and who owns it" \
    /bin/sh -c 'ls -l /run/gh-runner-init 2>&1; echo "---"; sed "s/=.*/=<set>/" /run/gh-runner-init 2>&1'

_guest "is the delivered script there, and is it runnable" \
    /bin/sh -c 'ls -l /home/runner/start-runner.sh 2>&1; echo "---"; head -3 /home/runner/start-runner.sh 2>&1'

_guest "units" \
    /bin/sh -c 'systemctl is-active ephemeral-runner.path 2>&1; systemctl is-enabled ephemeral-runner.path 2>&1; systemctl is-active ephemeral-runner.service 2>&1'

_guest "runner journal" \
    /bin/sh -c 'journalctl -u ephemeral-runner --no-pager -n 60 2>&1'

_guest "network" \
    /bin/sh -c 'ip -4 -br a 2>&1; echo "---"; getent hosts github.com 2>&1 || echo "DNS FAILED"'

printf '\nguest-diag: done\n'
