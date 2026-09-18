#!/usr/bin/env bash
#
# Provision an ephemeral GitHub Actions runner on Proxmox via the HTTP API.
#
# Output contract (stdout):
#   Exactly one line of the form  vmid=<n>  is written to stdout immediately
#   after the clone and before any step that can fail post-clone. Callers MUST
#   capture stdout and parse the vmid= line BEFORE checking the exit status,
#   because a failure in a later step (agent delivery, start) still exits
#   non-zero while the VMID has already been emitted. A caller written as
#     VMID=$(ssh proxmox provision.sh ...)
#   loses the VMID on any non-zero exit. Use instead:
#     OUT=$(ssh proxmox provision.sh ...); rc=$?
#     VMID=$(printf '%s\n' "$OUT" | grep -oP 'vmid=\K[0-9]+')
#   Everything else (progress, errors) goes to stderr.
#
# Usage:
#   provision.sh <runner-label> <registration-token> <registration-url>
#
# <registration-url> must match the scope the token was minted for. An
# organization registration token requires the ORG url; passing the repository
# url with an org token fails at config.sh with a 404 that reads like a bad
# token. Registration is org-level so the PAT can hold only "Self-hosted
# runners" rather than repository Administration; the runner is confined to one
# repository by RUNNER_GROUP instead.
#
# The registration token is delivered by writing /run/gh-runner-init inside
# the guest via the qemu guest agent (POST .../agent/file-write). provision.sh
# never opens an SSH connection to the guest and writes no files to the
# hypervisor filesystem. The token must not appear in any curl process argv --
# visible to ps aux on the hypervisor -- so the content is written to a temp
# file and passed as --data-urlencode "content@FILE" rather than inline.
# The file lands root:root in the guest; the path unit must chown it before
# starting the runner service (see db-wd43).
#
# Proxmox credentials (from $CRED_FILE, mode 0600, owned by gh-runner):
#   PVE_TOKEN_ID     -- Proxmox API token id (user@realm!tokenname)
#   PVE_TOKEN_SECRET -- Proxmox API token secret
#   PVE_NODE         -- Proxmox node name
#
# These three are never accepted as command-line arguments -- an unset variable
# and a dead API produce identical symptoms at the curl layer, and naming the
# missing one at startup is the only way to distinguish them.
#
# Environment variables:
#   TEMPLATE_VMID  -- source VM template id (default: 101)
#   CLONE_RETRIES  -- attempts before giving up on VMID collision (default: 5)
#   TASK_TIMEOUT   -- seconds to wait for a UPID task to complete (default: 120)
#   AGENT_TIMEOUT  -- seconds to wait for the guest agent to become ready (default: 120)
#   CRED_FILE      -- credential file to source (default: /etc/gh-ephemeral-runner/token)
#   PVE_API_HOST   -- Proxmox API hostname or IP (default: localhost)
#   PVE_API_PORT   -- Proxmox API port (default: 8006)
#   RUNNER_GROUP   -- runner group the guest registers into (default: ephemeral-ci)
#
# API transport notes:
#   -k: loopback only. The request never leaves the host, so anyone positioned
#       to intercept it already has local access. Do not copy this flag to a
#       call that goes over the network.
#   -sS: -s suppresses the progress meter; -S restores curl's transport-error
#       messages to stderr. Never use -s alone -- connection refused, TLS
#       failure, and a malformed URL from an unset variable all produce empty
#       output and HTTP 000 with no indication of cause.
#   Never -f/--fail: it discards the response body on HTTP >=400. The Proxmox
#       API returns its error reason in that body; discarding it makes every
#       auth and validation failure arrive as a bare exit code with nothing to
#       act on.
#
set -euo pipefail

TEMPLATE_VMID="${TEMPLATE_VMID:-101}"
CLONE_RETRIES="${CLONE_RETRIES:-5}"
TASK_TIMEOUT="${TASK_TIMEOUT:-120}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-120}"
CRED_FILE="${CRED_FILE:-/etc/gh-ephemeral-runner/token}"
# Where the Proxmox API lives. These default to loopback because that is right
# when the script runs on the hypervisor, but it no longer does: provision runs
# on a GitHub-hosted runner that reaches the host over the tailnet, and a
# hardcoded localhost made this script unable to provision anything from there
# at all (db-323).
PVE_API_HOST="${PVE_API_HOST:-localhost}"
PVE_API_PORT="${PVE_API_PORT:-8006}"
# The runner group the guest registers into. Org-level registration puts a
# runner in "Default" unless a group is named, and Default is visible to every
# repository in the organisation.
RUNNER_GROUP="${RUNNER_GROUP:-ephemeral-ci}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -ne 3 ]; then
    printf 'Usage: provision.sh <runner-label> <registration-token> <repo-url>\n' >&2
    exit 1
fi

LABEL="$1"
TOKEN="$2"
REPO_URL="$3"

# Validate label before any network step. Characters outside this set have no
# legitimate use in a runner label.
if ! printf '%s' "$LABEL" | grep -qE '^[A-Za-z0-9._-]+$'; then
    printf 'provision.sh: label contains invalid characters (allowed: A-Za-z0-9._-)\n' >&2
    exit 1
fi

# Source credentials. Fail fast with a named cause before calling curl --
# an unset variable and a dead API look the same at the curl layer.
if [ -f "$CRED_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CRED_FILE"
fi
: "${PVE_TOKEN_ID:?credential not set -- is $CRED_FILE sourced and readable?}"
: "${PVE_TOKEN_SECRET:?credential not set -- is $CRED_FILE sourced and readable?}"
: "${PVE_NODE:?credential not set -- is $CRED_FILE sourced and readable?}"

# ---------------------------------------------------------------------------
# pvapi <METHOD> <path> [curl-args...]
#
# Calls the Proxmox REST API. Writes the response body to stdout. Returns 0
# on 2xx, 1 on any HTTP error or curl transport failure. On non-2xx, logs
# METHOD, path, and the HTTP status to stderr; the body (which contains the
# API's reason) is still emitted so the caller can log it.
#
# -o to a temp file separates body from the -w status code, so the body
# always reaches stdout regardless of HTTP status.
# ---------------------------------------------------------------------------
pvapi() {
    local method="$1" path="$2"; shift 2
    local body_file code _pvapi_body
    body_file="$(mktemp)"
    code="$(curl -sS -k -o "$body_file" -w '%{http_code}' -X "$method" \
        -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
        "https://${PVE_API_HOST}:${PVE_API_PORT}/api2/json${path}" "$@")" || {
        rm -f "$body_file"
        printf 'provision.sh: curl transport error (%s %s)\n' "$method" "$path" >&2
        return 1
    }
    _pvapi_body="$(cat "$body_file")"
    printf '%s' "$_pvapi_body"
    rm -f "$body_file"
    case "$code" in 2??) return 0 ;; esac
    # The API puts its reason in the body. Printing only the status is how an
    # intermittent agent failure became unreadable: "HTTP 500" and nothing else.
    printf 'provision.sh: pvapi %s %s -> HTTP %s\n' "$method" "$path" "$code" >&2
    printf 'provision.sh: response: %s\n' "$_pvapi_body" >&2
    return 1
}

# ---------------------------------------------------------------------------
# agent_retry <attempts> <METHOD> <path> [curl-args...]
#
# Guest-agent calls are intermittently unavailable for the first seconds after
# the agent starts answering ping: the channel is up before every command is
# serviceable, and the API surfaces that as HTTP 500 rather than a retryable
# status. One such 500 on a file-write failed a whole provision, and the same
# call had succeeded on the previous run -- so it is flaky, not wrong.
#
# Retries with a short backoff and reports every attempt, so a persistent
# failure is still visible rather than smoothed away.
# ---------------------------------------------------------------------------
agent_retry() {
    local attempts="$1"; shift
    local i
    for i in $(seq 1 "$attempts"); do
        if pvapi "$@"; then
            return 0
        fi
        printf 'provision.sh: guest agent call failed (attempt %s/%s), retrying\n' \
            "$i" "$attempts" >&2
        sleep 3
    done
    printf 'provision.sh: guest agent call failed after %s attempts\n' "$attempts" >&2
    return 1
}

# ---------------------------------------------------------------------------
# poll_exec <vmid> <timeout_s> [exec POST args...]
#
# Runs a command in the guest via agent/exec and waits for it to finish.
# Forwards the command's stdout and stderr to this script's stderr so the
# operator can read them in the job log. Returns the command's exit code, or
# 1 on API error or timeout.
#
# WHY THIS EXISTS. agent/exec fires and forgets: it returns a pid, not output.
# The result lives in exec-status and is not ready immediately. A caller that
# trusts the fire-and-forget return code is reading the API call's success, not
# the command's. guest-diag.sh uses the same poll pattern; see that file for
# the prior state (it returned nothing useful).
# ---------------------------------------------------------------------------
poll_exec() {
    local vmid="$1" timeout_s="$2"; shift 2
    local pid body exited exitcode out_data err_data deadline
    body="$(pvapi POST "/nodes/${PVE_NODE}/qemu/${vmid}/agent/exec" "$@")" || return 1
    pid="$(printf '%s' "$body" | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("data",{}).get("pid",""))')"
    [ -n "$pid" ] || { printf 'provision.sh: agent/exec returned no pid\n' >&2; return 1; }
    deadline=$(( $(date +%s) + timeout_s ))
    while true; do
        body="$(pvapi GET "/nodes/${PVE_NODE}/qemu/${vmid}/agent/exec-status?pid=${pid}")" || return 1
        exited="$(printf '%s' "$body" | python3 -c \
            'import json,sys; print(json.load(sys.stdin).get("data",{}).get("exited",0))')"
        if [ "$exited" = "1" ]; then
            exitcode="$(printf '%s' "$body" | python3 -c \
                'import json,sys; print(json.load(sys.stdin).get("data",{}).get("exitcode",1))')"
            out_data="$(printf '%s' "$body" | python3 -c \
                'import json,sys; d=json.load(sys.stdin).get("data",{}); sys.stdout.write(d.get("out-data",""))')"
            err_data="$(printf '%s' "$body" | python3 -c \
                'import json,sys; d=json.load(sys.stdin).get("data",{}); sys.stdout.write(d.get("err-data",""))')"
            [ -n "$out_data" ] && printf '%s\n' "$out_data" >&2
            [ -n "$err_data" ] && printf '%s\n' "$err_data" >&2
            return "$exitcode"
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf 'provision.sh: poll_exec timed out waiting for pid %s (%ss)\n' "$pid" "$timeout_s" >&2
            return 1
        fi
        sleep 2
    done
}

# ---------------------------------------------------------------------------
# poll_task <upid>
#
# Waits for a Proxmox async task to reach status=stopped. Returns 0 when
# exitstatus=OK, 1 when exitstatus is anything else or when TASK_TIMEOUT
# expires. Every POST to a Proxmox action endpoint returns a UPID immediately
# and the work happens afterwards -- a script that fires the clone and proceeds
# straight to config injection races intermittently. That is the defect class
# this bead exists to remove.
# ---------------------------------------------------------------------------
poll_task() {
    local upid="$1"
    local encoded deadline body status exitstatus
    encoded="$(printf '%s' "$upid" | python3 -c \
        'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip(),safe=""))')"
    deadline=$(( $(date +%s) + TASK_TIMEOUT ))
    while true; do
        body="$(pvapi GET "/nodes/${PVE_NODE}/tasks/${encoded}/status")" || return 1
        status="$(printf '%s\n' "$body" | python3 -c \
            'import json,sys; print(json.load(sys.stdin).get("data",{}).get("status",""))')"
        if [ "$status" = "stopped" ]; then
            exitstatus="$(printf '%s\n' "$body" | python3 -c \
                'import json,sys; print(json.load(sys.stdin).get("data",{}).get("exitstatus",""))')"
            if [ "$exitstatus" = "OK" ]; then
                return 0
            fi
            printf 'provision.sh: task %s failed (exitstatus=%s)\n' "$upid" "$exitstatus" >&2
            return 1
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf 'provision.sh: timed out waiting for task %s (%ss)\n' "$upid" "$TASK_TIMEOUT" >&2
            return 1
        fi
        sleep 2
    done
}

# ---------------------------------------------------------------------------
# pick_vmid
#
# Returns the id from /cluster/nextid. That value is authoritative: nextid is
# existence-aware and will not hand back an id that is in use.
#
# THERE IS DELIBERATELY NO "IS IT FREE?" PROBE. The obvious check --
# GET /nodes/<node>/qemu/<id>/config and treat 404 as free -- cannot work with
# a pool-scoped API token. Proxmox evaluates path permission BEFORE existence,
# so a token holding rights only on /pool/ephemeral-ci receives 403 for every
# id outside that pool, including ids where no VM exists at all. Free and
# occupied are indistinguishable to this caller, and the probe rejected every
# candidate in turn until it ran out of retries.
#
# The race the probe was guarding against is real but is better caught by the
# clone itself: Proxmox refuses to clone onto an existing VMID, which is an
# authoritative answer requiring no extra permission. See the clone retry loop.

# ---------------------------------------------------------------------------
pick_vmid() {
    local body vmid
    body="$(pvapi GET "/cluster/nextid")" || return 1
    vmid="$(printf '%s\n' "$body" | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("data",""))')"
    if [ -z "$vmid" ]; then
        printf 'provision.sh: /cluster/nextid returned empty data\n' >&2
        return 1
    fi
    printf '%s' "$vmid"
}

# --- Wait for the node to have room -------------------------------------------
#
# WHY THIS IS HERE AND NOT IN THE GUEST. By the time a runner VM exists its
# memory is already committed, so a limit enforced inside the runner is a
# limit enforced too late. This is the last point at which not starting is
# still free.
#
# WHY NOT A GITHUB `concurrency:` GROUP. GitHub holds exactly one PENDING run
# per group and every newer arrival evicts the previous one, so several pull
# requests pushed together do not queue -- one runs, one waits, and the rest
# are CANCELLED. A consumer of this action has that written up in its own
# workflow after four runs disappeared that way. A cancelled run looks
# identical to one that has not started, which is the worst property a
# capacity control can have.
#
# ALLOCATION, NOT USAGE. This sums maxmem over running VMs rather than reading
# the node's free memory. Ballooning and KSM make "used" an understatement: a
# guest holding 16 GiB that has touched 4 reports 4, and memory is precisely
# the resource that cannot be overcommitted. The conservative number is the
# only correct one here.
#
# Summing EVERY running VM, not just this pool's, is the point. A hypervisor
# that also carries production services and other fleets has those in the sum
# for free, so nobody has to declare their sizes here or remember to update a
# constant when one of them grows. A budget written as a number goes stale in
# silence; a budget derived from the node does not.
#
# IT WAITS, IT DOES NOT FAIL. A red pull request for a capacity reason is
# indistinguishable from a broken test, and costs someone the diagnosis before
# they can discover it was never about their change.
#
# THE RACE IS ABSORBED, NOT COORDINATED. Two provision jobs can both observe
# room and both clone; the API offers no atomic reserve, and inventing one
# across GitHub-hosted runners would be far more machinery than the failure
# deserves. Requiring room for this runner plus CAPACITY_SLACK_RUNNERS more
# bounds the overshoot at exactly that many. It is the same instinct as the
# clone-is-the-collision-check below: lean on what the API makes authoritative
# and size the slack for what it does not.
#
# EVERYTHING HERE PRINTS TO STDERR. stdout carries the vmid= output contract.
CAPACITY_TIMEOUT="${CAPACITY_TIMEOUT:-1800}"
CAPACITY_POLL="${CAPACITY_POLL:-15}"
CAPACITY_SLACK_RUNNERS="${CAPACITY_SLACK_RUNNERS:-1}"
# Left for the hypervisor itself -- ZFS ARC, the kernel, and whatever is not a
# guest. Not a safety margin for the guests; that is what the slack is for.
NODE_MEM_RESERVE_MIB="${NODE_MEM_RESERVE_MIB:-8192}"

# Prints "<total_mib> <allocated_mib> <template_mib>" for the node, or nothing
# if the token cannot see them.
#
# TWO CALLS, AND NEVER /config. scripts/test-provision.sh asserts that nothing
# reads a VM's /config before the clone -- that probe is what pick_vmid was
# rewritten to remove, because a pool-scoped token cannot do it and the clone
# is the authoritative collision check instead. The template's own maxmem is
# already in the /qemu list this reads anyway, so taking it from there keeps
# the invariant AND costs one call fewer than asking for it separately.
node_memory() {
    # This file's own pvapi() prints the body on stdout and returns non-zero on
    # anything but 2xx -- it is NOT the pvapi.sh that exports PVAPI_STATUS.
    local status_body qemu_body total rest
    status_body="$(pvapi GET "/nodes/${PVE_NODE}/status" 2>/dev/null)" || return 1
    total="$(printf '%s' "$status_body" | python3 -c \
        'import json,sys; print(json.load(sys.stdin)["data"]["memory"]["total"]//1048576)' 2>/dev/null)" || return 1
    [ -n "$total" ] || return 1

    qemu_body="$(pvapi GET "/nodes/${PVE_NODE}/qemu" 2>/dev/null)" || return 1
    rest="$(printf '%s' "$qemu_body" | TEMPLATE_VMID="$TEMPLATE_VMID" python3 -c \
        'import json,os,sys
d=json.load(sys.stdin)["data"]
tid=str(os.environ["TEMPLATE_VMID"])
run=sum(v.get("maxmem",0) for v in d if v.get("status")=="running")//1048576
tpl=[v.get("maxmem",0)//1048576 for v in d if str(v.get("vmid"))==tid]
print(run, tpl[0] if tpl else 0)' 2>/dev/null)" || return 1
    [ -n "$rest" ] || return 1
    printf '%s %s' "$total" "$rest"
}

wait_for_capacity() {
    local total alloc want free need waited=0 pair
    while :; do
        if ! pair="$(node_memory)" || [ -z "$pair" ]; then
            # A pool-scoped token cannot read the node or its VM list. That is a
            # grant to widen -- Sys.Audit on /nodes/<node> for the total and
            # VM.Audit on /vms for the guests, both read-only -- not a reason to
            # fail a run. But it must be said out loud, because a capacity
            # control that quietly does nothing is worse than none at all.
            #
            # THE TWO GRANTS ARE INDEPENDENT AND HALF OF THEM IS THE DANGEROUS
            # STATE. /nodes/<node>/status needs Sys.Audit; /nodes/<node>/qemu is
            # FILTERED by VM.Audit rather than refused, so a token holding the
            # first and not the second gets a 200 carrying only the VMs it can
            # see. The sum is then legitimately small, the cap passes, and
            # nothing anywhere reports a problem -- a check that cannot fail is
            # not a check. Grant both or neither.
            printf '::warning::provision.sh: cannot read node memory (needs Sys.Audit on /nodes/%s AND VM.Audit on /vms) -- proceeding with NO capacity cap\n' "$PVE_NODE" >&2
            return 0
        fi
        # Split on purpose: $pair is "total alloc want".
        # shellcheck disable=SC2086
        set -- $pair
        total="$1"; alloc="$2"; want="$3"
        if [ "${want:-0}" -le 0 ]; then
            printf '::warning::provision.sh: template %s reports no memory -- proceeding with NO capacity cap\n' "$TEMPLATE_VMID" >&2
            return 0
        fi
        need=$(( want * (1 + CAPACITY_SLACK_RUNNERS) ))
        free=$(( total - alloc - NODE_MEM_RESERVE_MIB ))
        if [ "$free" -ge "$need" ]; then
            printf 'provision.sh: %s has %s MiB free of %s (reserve %s, running VMs allocate %s); this runner wants %s\n' \
                "$PVE_NODE" "$free" "$total" "$NODE_MEM_RESERVE_MIB" "$alloc" "$want" >&2
            return 0
        fi
        if [ "$waited" -ge "$CAPACITY_TIMEOUT" ]; then
            printf '::error::provision.sh: waited %ss for room on %s. %s MiB free of %s (reserve %s, running VMs allocate %s); this runner needs %s MiB including slack for %s concurrent clone(s).\n' \
                "$waited" "$PVE_NODE" "$free" "$total" "$NODE_MEM_RESERVE_MIB" "$alloc" "$need" "$CAPACITY_SLACK_RUNNERS" >&2
            return 1
        fi
        printf 'provision.sh: %s has %s MiB free, need %s -- waiting (%ss/%ss)\n' \
            "$PVE_NODE" "$free" "$need" "$waited" "$CAPACITY_TIMEOUT" >&2
        sleep "$CAPACITY_POLL"
        waited=$(( waited + CAPACITY_POLL ))
    done
}

wait_for_capacity || exit 1

# --- Pick a VMID ---
VMID="$(pick_vmid)" || exit 1

# --- Clone ---
#
# THE DESCRIPTION CARRIES THE RUNNER NAME, AND IT IS LOAD-BEARING.
#
# The VM is named gh-runner-<vmid> -- teardown.sh refuses to destroy anything
# whose name does not match that exactly, which is the guard that stops a
# mistyped id from destroying an unrelated machine. The RUNNER is registered
# with GitHub under $LABEL, which is a different string entirely.
#
# So nothing on the hypervisor said which runner a VM was, and reap.sh's
# GitHub busy check -- which looks the VM's name up in the runner list -- could
# never match. Every VM read as idle and age was the only real guard, while the
# check still reported a clean result.
#
# Recording the label in the VM description fixes the correlation without
# touching the name, so teardown's guard is unchanged. reap.sh already fetches
# /qemu/<vmid>/config for ctime and the description arrives in that same
# payload, so it costs no extra API call.
#
# pool=ephemeral-ci is required. A pool-scoped grant cannot allocate outside
# its pool, so omitting it causes the clone to fail with a permissions error
# even if the token has VM.Clone on the template.
# THE CLONE IS THE COLLISION CHECK. Proxmox refuses to clone onto an existing
# VMID, and that refusal is authoritative and needs no permission the token
# lacks -- unlike probing the id first, which a pool-scoped token cannot do
# (see pick_vmid). On refusal, ask nextid again: if the id was taken by a
# concurrent provision, nextid has moved past it.
clone_upid=""
for _clone_try in $(seq 1 "$CLONE_RETRIES"); do
    printf 'provision.sh: cloning template %s -> VMID %s (attempt %s/%s)\n' \
        "$TEMPLATE_VMID" "$VMID" "$_clone_try" "$CLONE_RETRIES" >&2
    if clone_body="$(pvapi POST "/nodes/${PVE_NODE}/qemu/${TEMPLATE_VMID}/clone" \
        --data-urlencode "newid=${VMID}" \
        --data-urlencode "name=gh-runner-${VMID}" \
        --data-urlencode "description=runner=${LABEL}" \
        --data-urlencode "full=0" \
        --data-urlencode "pool=ephemeral-ci")"; then
        clone_upid="$(printf '%s\n' "$clone_body" | python3 -c \
            'import json,sys; print(json.load(sys.stdin).get("data",""))')"
        [ -n "$clone_upid" ] && break
        printf 'provision.sh: clone POST returned no UPID\n' >&2
        exit 1
    fi
    printf 'provision.sh: clone onto VMID %s refused; asking for a new id\n' "$VMID" >&2
    VMID="$(pick_vmid)" || exit 1
    sleep 1
done
if [ -z "$clone_upid" ]; then
    printf 'provision.sh: could not clone after %s attempts\n' "$CLONE_RETRIES" >&2
    exit 1
fi

# Poll the clone task. A non-OK exitstatus means the clone failed on the
# server; do not proceed to start the VM.
poll_task "$clone_upid" || exit 1

# Emit the VMID now -- before any step that can fail -- so callers can tear
# down even if we die later. See the output contract at the top.
#
# There is deliberately no ledger write here. A file on this machine's disk
# cannot be read by teardown.sh, which runs in a different job on a different
# ephemeral runner. Ownership is established from the hypervisor instead: the
# VM's name, its pool membership, and its template flag.
printf 'vmid=%s\n' "$VMID"

# --- Start ---
printf 'provision.sh: starting VM %s\n' "$VMID" >&2
start_body="$(pvapi POST "/nodes/${PVE_NODE}/qemu/${VMID}/status/start")" || exit 1
start_upid="$(printf '%s\n' "$start_body" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("data",""))')"
if [ -z "$start_upid" ]; then
    printf 'provision.sh: start POST returned no UPID\n' >&2
    exit 1
fi
poll_task "$start_upid" || exit 1

# --- Wait for guest agent ---
#
# The guest agent needs time to start after the VM boots. Poll /agent/ping
# until it responds before attempting file-write, which would fail immediately
# if the agent is not yet running.
printf 'provision.sh: waiting for guest agent on VM %s (timeout %ss)\n' "$VMID" "$AGENT_TIMEOUT" >&2
agent_deadline=$(( $(date +%s) + AGENT_TIMEOUT ))
while true; do
    # The inline pvapi() returns non-0 on non-2xx. If pvapi.sh is ever
    # sourced here instead, pvapi() returns 0 even on 500 but sets
    # PVAPI_STATUS. The PVAPI_STATUS:-200 default makes both work: the
    # inline version leaves PVAPI_STATUS unset, so it defaults to 200 on
    # any successful return (which the inline version only does on 2xx).
    _ping_ok=0
    if pvapi POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/ping" >/dev/null 2>&1; then
        case "${PVAPI_STATUS:-200}" in 2??) _ping_ok=1 ;; esac
    fi
    [ "$_ping_ok" -eq 1 ] && break
    if [ "$(date +%s)" -ge "$agent_deadline" ]; then
        printf 'provision.sh: timed out waiting for guest agent on VM %s (%ss)\n' \
            "$VMID" "$AGENT_TIMEOUT" >&2
        exit 1
    fi
    sleep 2
done

# --- Mask apt automation ---
#
# A fresh clone inherits the template's systemd unit state. If apt timers are
# enabled, unattended-upgrades or apt-daily-upgrade fires at a random point in
# the first hour and needrestart can restart the runner's service, killing the
# job mid-suite with "The runner has received a shutdown signal". Mask before
# credentials land: the runner never starts on a node where an upgrade can
# interrupt it.
#
# If the template was drifted (timers enabled), emit a ::warning:: naming the
# template and proceed: refusing every provision until the template is resealed
# at the Proxmox console would block CI entirely, and masking handles the
# immediate risk. If the mask itself fails, refuse.
#
# Guest script exit codes:
#   0: all units were already masked/disabled -- template is clean
#   2: one or more were enabled; all are now masked -- template was drifted
#   1 (or other non-zero): mask or post-mask verify failed -- refuse
printf 'provision.sh: masking apt automation in guest %s\n' "$VMID" >&2
_apt_rc=0
# shellcheck disable=SC2016
poll_exec "$VMID" 60 \
    --data-urlencode "command=/bin/bash" \
    --data-urlencode "command=-c" \
    --data-urlencode 'command=drifted=0; for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do s=$(systemctl is-enabled "$u" 2>/dev/null); case "$s" in ""|masked|disabled|not-found|linked-runtime) ;; *) drifted=1;; esac; done; systemctl mask --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || exit 1; for u in unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer; do s=$(systemctl is-enabled "$u" 2>/dev/null); [ "$s" = "masked" ] || { printf "verify: %s is %s\n" "$u" "$s" >&2; exit 1; }; done; [ "$drifted" -eq 0 ] && exit 0 || exit 2' \
    || _apt_rc=$?
case "$_apt_rc" in
    0) ;;
    2) printf '::warning::provision.sh: template %s had apt automation enabled; units masked for this run\n' "$TEMPLATE_VMID" >&2 ;;
    *) printf 'provision.sh: failed to mask apt automation in guest %s\n' "$VMID" >&2; exit 1 ;;
esac

# --- Deliver the guest script, then the token ---
#
# ORDER IS LOAD-BEARING. The guest's ephemeral-runner.path unit watches
# /run/gh-runner-init and starts the service the moment that file appears, so
# start-runner.sh must already be in place. Writing the script first and the
# token second is what makes that safe.
#
# The script is shipped from this repository on every run rather than baked
# into the VM template. That keeps it version-controlled and reviewable, and
# means changing it never requires cloning, editing and resealing the template.
# REFUSE NON-ASCII BEFORE SENDING. Proxmox's agent/file-write dies on any byte
# above 0x7F with "Wide character in subroutine entry at .../Qemu/Agent.pm" and
# returns HTTP 500 with no mention of encoding. A single em dash in a comment
# broke every provision, and the failure named the hypervisor's Perl rather
# than the file that caused it. Checking here puts the message where the fix is.
if LC_ALL=C grep -qP '[^\x00-\x7F]' "${SCRIPT_DIR}/guest/start-runner.sh" 2>/dev/null; then
    printf 'provision.sh: guest/start-runner.sh contains non-ASCII bytes; agent/file-write cannot carry them\n' >&2
    LC_ALL=C grep -nP '[^\x00-\x7F]' "${SCRIPT_DIR}/guest/start-runner.sh" >&2
    exit 1
fi

printf 'provision.sh: delivering guest script to VM %s\n' "$VMID" >&2
agent_retry 5 POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/file-write" \
    --data-urlencode "file=/home/runner/start-runner.sh" \
    --data-urlencode "content@${SCRIPT_DIR}/guest/start-runner.sh" >/dev/null || exit 1

# file-write lands the file root:root and non-executable. The service runs as
# User=runner and execs this path, so both have to be corrected before the
# token arrives and the path unit fires.
agent_retry 5 POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/exec" \
    --data-urlencode "command=/bin/chown" \
    --data-urlencode "command=runner:runner" \
    --data-urlencode "command=/home/runner/start-runner.sh" >/dev/null || exit 1
agent_retry 5 POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/exec" \
    --data-urlencode "command=/bin/chmod" \
    --data-urlencode "command=0755" \
    --data-urlencode "command=/home/runner/start-runner.sh" >/dev/null || exit 1

# Write the token content to a temp file so it never appears in any curl
# process argv (visible to ps aux). The file lands root:root in the guest; the
# path unit chowns it before starting the runner service.
# THE FINAL FILE MUST APPEAR ATOMICALLY. The guest's ephemeral-runner.path unit
# triggers on PathExists, which fires the instant the path comes into being --
# not when writing to it finishes. Writing straight to /run/gh-runner-init let
# the service start and source a partially written file, so RUNNER_LABEL was
# unset, the script exited, the path unit retriggered, and systemd rate-limited
# it five failures later. The file was complete by the time anyone looked,
# which made it read like a delivery failure rather than a race.
#
# Write to a temp path the path unit is not watching, then rename. rename(2) is
# atomic within a filesystem, so the watched path only ever appears complete.
printf 'provision.sh: delivering token to VM %s via guest agent\n' "$VMID" >&2
_token_file="$(mktemp)"
printf 'RUNNER_LABEL=%s\nRUNNER_TOKEN=%s\nRUNNER_URL=%s\nRUNNER_GROUP=%s\n' \
    "$LABEL" "$TOKEN" "$REPO_URL" "$RUNNER_GROUP" > "$_token_file"
agent_retry 5 POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/file-write" \
    --data-urlencode "file=/run/gh-runner-init.partial" \
    --data-urlencode "content@${_token_file}" >/dev/null || { rm -f "$_token_file"; exit 1; }
rm -f "$_token_file"

agent_retry 5 POST "/nodes/${PVE_NODE}/qemu/${VMID}/agent/exec" \
    --data-urlencode "command=/bin/mv" \
    --data-urlencode "command=/run/gh-runner-init.partial" \
    --data-urlencode "command=/run/gh-runner-init" >/dev/null || exit 1

printf 'provision.sh: VM %s started; runner credentials delivered via guest agent\n' "$VMID" >&2
