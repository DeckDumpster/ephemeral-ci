#!/usr/bin/env bash
#
# Provision an ephemeral GitHub Actions runner on Proxmox via the HTTP API.
#
# Output contract (stdout):
#   Two lines are written to stdout after the clone and before any step that
#   can fail post-clone:
#     vmid=<n>        — VMID of the cloned VM
#     vmtoken=<hex>   — 32-char hex ownership token stamped into the VM
#                       description; teardown.sh requires it (db-ogjn)
#   Callers MUST capture stdout and parse BEFORE checking exit status, because
#   a failure in a later step (agent delivery, start) still exits non-zero
#   while the VMID has already been emitted. A caller written as
#     VMID=$(ssh proxmox provision.sh ...)
#   loses the VMID on any non-zero exit. Use instead:
#     OUT=$(ssh proxmox provision.sh ...); rc=$?
#     VMID=$(printf '%s\n' "$OUT" | grep -oP 'vmid=\K[0-9]+')
#     VMTOKEN=$(printf '%s\n' "$OUT" | grep -oP 'vmtoken=\K[a-f0-9]+')
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
#   BOOT_LOCK_TIMEOUT -- seconds to wait for the per-template boot lock (default: 600).
#                   Linked clones from the same template share a base volume; concurrent
#                   boots contend on it and can stall long enough to miss AGENT_TIMEOUT
#                   (sp-bmim8). The lock serialises start-through-agent-ready so each
#                   boot has the base volume mostly to itself.
#   CRED_FILE      -- credential file to source (default: /etc/gh-ephemeral-runner/token)
#   PVE_API_HOST   -- Proxmox API hostname or IP (default: localhost)
#   PVE_API_PORT   -- Proxmox API port (default: 8006)
#   PVE_API_HOSTNAME -- Hostname as it appears in the Proxmox TLS certificate.
#                   When set, pvapi() connects to PVE_API_HOST but validates TLS
#                   against this name. Required when PVE_API_HOST is an IP address
#                   (the certificate carries no SAN for IPs).
#   PVE_CA_CERT_FILE -- Path to the Proxmox cluster CA certificate (PEM).
#                   Defaults to /etc/pve/pve-root-ca.pem (exists on the
#                   hypervisor). Callers running off-node (e.g. GitHub-hosted
#                   runners) must set this to a temp file written from
#                   vars.PVE_CA_CERT.
#   RUNNER_GROUP   -- runner group the guest registers into (default: ephemeral-ci)
#   CAPACITY_UNCAPPED -- set to "1" to provision without any capacity check.
#                   Must be set by the caller; provision.sh never sets it from a
#                   failed permission check. A missing privilege and a deliberate
#                   decision to run uncapped must not produce the same behaviour.
#   REPO_SLUG      -- "owner/repo" identifier (e.g. "ryangantt/ephemeral-ci").
#                   When set, a sanitised tag is derived from it and stamped on
#                   cloned VMs so the per-repo admission count can identify them.
#                   Unset or empty -> per-repo cap is not enforced.
#   FLEET_SHARE_PER_REPO -- maximum concurrent runner VMs from this repo.
#                   Counts ALL gh-runner VMs tagged with this repo's derived tag
#                   (any state, including stopped/cloning) before cloning. If at
#                   or above this ceiling, waits. 0 disables the cap entirely.
#                   Default 1: one install cannot take the whole fleet while
#                   another install is waiting for a slot.
#   CPU_OVERCOMMIT_RATIO -- vCPUs to allocate per physical CPU thread (default: 4).
#                   CPU overcommit is legitimate where memory overcommit is not: a
#                   guest that gets less CPU than it expects slows down; a guest that
#                   gets less memory than it expects crashes. 4 vCPUs per thread is
#                   conservative for CI: runners burst hard for seconds and idle the
#                   rest of a job.
#   NODE_CPU_RESERVE_VCPUS -- vCPUs withheld for the hypervisor and non-guest work
#                   (default: 0). Analogous to NODE_MEM_RESERVE_MIB.
#
# API transport notes:
#   --cacert: TLS verification uses the cluster CA at $PVE_CA_CERT_FILE
#       (default: /etc/pve/pve-root-ca.pem, which exists on the hypervisor;
#       callers running off-node must set this to a temp file written from
#       vars.PVE_CA_CERT). The token authenticates the caller; TLS verification
#       authenticates the server the token is sent to. Neither substitutes for
#       the other.
#   --resolve: when PVE_API_HOSTNAME is set, curl connects to PVE_API_HOST (the
#       tailnet IP) but validates the certificate against PVE_API_HOSTNAME (the
#       node name in the cert). Required when PVE_API_HOST is an IP — the
#       certificate carries no SAN for the IP address.
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
BOOT_LOCK_TIMEOUT="${BOOT_LOCK_TIMEOUT:-600}"
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
    local body_file code _pvapi_body _url_host _resolve_args
    _url_host="${PVE_API_HOST}"
    _resolve_args=()
    if [ -n "${PVE_API_HOSTNAME:-}" ]; then
        _url_host="${PVE_API_HOSTNAME}"
        _resolve_args=(--resolve "${PVE_API_HOSTNAME}:${PVE_API_PORT}:${PVE_API_HOST}")
    fi
    body_file="$(mktemp)"
    code="$(curl -sS \
        --cacert "${PVE_CA_CERT_FILE:-/etc/pve/pve-root-ca.pem}" \
        ${_resolve_args[@]+"${_resolve_args[@]}"} \
        -o "$body_file" -w '%{http_code}' -X "$method" \
        -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
        "https://${_url_host}:${PVE_API_PORT}/api2/json${path}" "$@")" || {
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
CAPACITY_TIMEOUT="${CAPACITY_TIMEOUT:-3600}"
CAPACITY_POLL="${CAPACITY_POLL:-15}"
CAPACITY_SLACK_RUNNERS="${CAPACITY_SLACK_RUNNERS:-1}"
CAPACITY_UNCAPPED="${CAPACITY_UNCAPPED:-0}"
# Left for the hypervisor itself -- ZFS ARC, the kernel, and whatever is not a
# guest. Not a safety margin for the guests; that is what the slack is for.
NODE_MEM_RESERVE_MIB="${NODE_MEM_RESERVE_MIB:-8192}"
# CPU overcommit ratio: how many vCPUs to allocate per physical CPU thread.
# CPU overcommit is legitimate where memory overcommit is not: a guest that is
# allocated 8 vCPUs on a node with 8 threads slows down under contention; a
# guest allocated 8 GiB on a node with 6 GiB crashes. 4:1 is conservative for
# CI runners that burst hard for seconds and idle the rest of the job.
CPU_OVERCOMMIT_RATIO="${CPU_OVERCOMMIT_RATIO:-4}"
# vCPUs reserved for the hypervisor itself and any non-guest workloads.
NODE_CPU_RESERVE_VCPUS="${NODE_CPU_RESERVE_VCPUS:-0}"
# Per-repo admission cap. REPO_SLUG must be set to enable it; derive a
# Proxmox tag by lowercasing and replacing non-alphanumeric chars with '-'.
# OFF BY DEFAULT (per Ryan, 2026-09-23). A per-repo share enforced by each repo's own
# provision counts only itself; no consumer sees the whole fleet, so fairness cannot be
# enforced this way. Shipped at 1, it held spira to one runner with ~34 GiB free on the
# node and four runs queued behind it. The node-wide memory and vCPU gate above is the limit
# that protects the hypervisor; burst beyond it is the EC2 spill design's job.
FLEET_SHARE_PER_REPO="${FLEET_SHARE_PER_REPO:-0}"
REPO_TAG=""
if [ -n "${REPO_SLUG:-}" ]; then
    _slug_sanitized="$(printf '%s' "${REPO_SLUG}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
    REPO_TAG="repo-${_slug_sanitized#-}"
fi

# Prints "<total_mib> <total_cpus> <alloc_mib> <template_mib> <alloc_cpus> <template_cpus>"
# for the node, or nothing if the token cannot see them.
#
# TWO CALLS, AND NEVER /config. scripts/test-provision.sh asserts that nothing
# reads a VM's /config before the clone -- that probe is what pick_vmid was
# rewritten to remove, because a pool-scoped token cannot do it and the clone
# is the authoritative collision check instead. The template's maxmem and cpus
# are already in the /qemu list this reads, so taking them from there keeps the
# invariant AND costs one call fewer than asking for them separately.
node_resources() {
    # This file's own pvapi() prints the body on stdout and returns non-zero on
    # anything but 2xx -- it is NOT the pvapi.sh that exports PVAPI_STATUS.
    # stderr is NOT suppressed here: pvapi already logs the failing call and its
    # HTTP status to stderr (e.g. "pvapi GET /nodes/x/status -> HTTP 403"), and
    # that message is the actionable signal when the token lacks the grant.
    local status_body qemu_body status_vals rest
    status_body="$(pvapi GET "/nodes/${PVE_NODE}/status")" || return 1
    status_vals="$(printf '%s' "$status_body" | python3 -c \
        'import json,sys; d=json.load(sys.stdin)["data"]
print(d["memory"]["total"]//1048576, d["cpuinfo"]["cpus"])' 2>/dev/null)" || return 1
    [ -n "$status_vals" ] || return 1

    qemu_body="$(pvapi GET "/nodes/${PVE_NODE}/qemu")" || return 1
    rest="$(printf '%s' "$qemu_body" | TEMPLATE_VMID="$TEMPLATE_VMID" REPO_TAG="${REPO_TAG:-}" python3 -c \
        'import json,os,sys
d=json.load(sys.stdin)["data"]
tid=str(os.environ["TEMPLATE_VMID"])
repo_tag=os.environ.get("REPO_TAG","")
run_mem=sum(v.get("maxmem",0) for v in d if v.get("status")=="running")//1048576
run_cpu=sum(int(v.get("cpus",0)) for v in d if v.get("status")=="running")
tpl=[v for v in d if str(v.get("vmid"))==tid]
tpl_mem=tpl[0].get("maxmem",0)//1048576 if tpl else 0
tpl_cpu=int(tpl[0].get("cpus",0)) if tpl else 0
repo_count=0
if repo_tag:
 repo_count=sum(1 for v in d if (v.get("name","") or "").startswith("gh-runner-") and str(v.get("vmid",""))!=tid and repo_tag in [t.strip() for t in (v.get("tags","") or "").split(";")])
print(run_mem, tpl_mem, run_cpu, tpl_cpu, repo_count)' 2>/dev/null)" || return 1
    [ -n "$rest" ] || return 1
    printf '%s %s' "$status_vals" "$rest"
}

wait_for_capacity() {
    local total_mib total_cpus alloc_mib want_mib alloc_cpus want_cpus \
          free_mib need_mib free_cpus need_cpus repo_count _repo_at_cap \
          waited=0 resources
    while :; do
        if ! resources="$(node_resources)" || [ -z "$resources" ]; then
            # node_resources() already printed the failing call and HTTP status
            # to stderr via pvapi(). Naming the call (not just the required
            # grants) is what lets an operator distinguish a token with the
            # wrong ACL from one whose ACL never intersected with the user's
            # rows -- the same symptom, the same message, two different fixes.
            # 'pvapi GET /nodes/x/status -> HTTP 403' points at one call;
            # 'needs Sys.Audit AND VM.Audit' points at neither (sp-7zzni note).
            if [ "${CAPACITY_UNCAPPED:-0}" = "1" ]; then
                printf '::warning::provision.sh: CAPACITY_UNCAPPED=1 -- proceeding with NO capacity cap\n' >&2
                return 0
            fi
            printf '::error::provision.sh: cannot read node resources (see pvapi error above for the failing call) -- refusing to clone without a capacity check. Grant the token Sys.Audit on /nodes/%s and VM.Audit on /vms, or set CAPACITY_UNCAPPED=1 for a deliberately uncapped deployment.\n' "$PVE_NODE" >&2
            return 1
        fi
        # $resources is "total_mib total_cpus alloc_mib template_mib alloc_cpus template_cpus repo_count"
        # shellcheck disable=SC2086
        set -- $resources
        total_mib="$1"; total_cpus="$2"; alloc_mib="$3"; want_mib="$4"
        alloc_cpus="$5"; want_cpus="$6"; repo_count="${7:-0}"
        if [ "${want_mib:-0}" -le 0 ]; then
            printf '::warning::provision.sh: template %s reports no memory -- proceeding with NO capacity cap\n' "$TEMPLATE_VMID" >&2
            return 0
        fi
        need_mib=$(( want_mib * (1 + CAPACITY_SLACK_RUNNERS) ))
        free_mib=$(( total_mib - alloc_mib - NODE_MEM_RESERVE_MIB ))
        # vCPU budget = physical threads * overcommit ratio, minus the reserve.
        # ALLOCATION, NOT USAGE: sum configured cpus of running VMs, not load
        # average. Load is a lagging measure; this gate runs before trouble
        # starts. If the template reports 0 cpus the CPU check is skipped.
        need_cpus=$(( want_cpus * (1 + CAPACITY_SLACK_RUNNERS) ))
        free_cpus=$(( total_cpus * CPU_OVERCOMMIT_RATIO - alloc_cpus - NODE_CPU_RESERVE_VCPUS ))
        _repo_at_cap=0
        if [ "${FLEET_SHARE_PER_REPO:-0}" -gt 0 ] && [ -n "${REPO_TAG:-}" ] \
           && [ "$repo_count" -ge "$FLEET_SHARE_PER_REPO" ]; then
            _repo_at_cap=1
        fi
        if [ "$free_mib" -ge "$need_mib" ] \
           && { [ "${want_cpus:-0}" -le 0 ] || [ "$free_cpus" -ge "$need_cpus" ]; } \
           && [ "$_repo_at_cap" -eq 0 ]; then
            printf 'provision.sh: %s has %s MiB free of %s (reserve %s, VMs allocate %s); %s vCPUs free (budget %s x %s = %s, reserve %s, VMs allocate %s); this runner wants %s MiB / %s vCPUs; per-repo (%s): %s/%s\n' \
                "$PVE_NODE" "$free_mib" "$total_mib" "$NODE_MEM_RESERVE_MIB" "$alloc_mib" \
                "$free_cpus" "$total_cpus" "$CPU_OVERCOMMIT_RATIO" \
                "$(( total_cpus * CPU_OVERCOMMIT_RATIO ))" \
                "$NODE_CPU_RESERVE_VCPUS" "$alloc_cpus" \
                "$want_mib" "$want_cpus" \
                "${REPO_TAG:-none}" "$repo_count" "${FLEET_SHARE_PER_REPO:-0}" >&2
            return 0
        fi
        if [ "$waited" -ge "$CAPACITY_TIMEOUT" ]; then
            printf '::error::provision.sh: waited %ss for room on %s. Memory: %s MiB free of %s (reserve %s, VMs allocate %s, need %s). CPU: %s vCPUs free of %s (budget %s x %s, reserve %s, VMs allocate %s, need %s). Slack: %s concurrent clone(s). Per-repo (%s): %s/%s.\n' \
                "$waited" "$PVE_NODE" \
                "$free_mib" "$total_mib" "$NODE_MEM_RESERVE_MIB" "$alloc_mib" "$need_mib" \
                "$free_cpus" "$(( total_cpus * CPU_OVERCOMMIT_RATIO ))" \
                "$total_cpus" "$CPU_OVERCOMMIT_RATIO" "$NODE_CPU_RESERVE_VCPUS" "$alloc_cpus" "$need_cpus" \
                "$CAPACITY_SLACK_RUNNERS" \
                "${REPO_TAG:-none}" "$repo_count" "${FLEET_SHARE_PER_REPO:-0}" >&2
            return 1
        fi
        printf 'provision.sh: %s: memory %s MiB free (need %s), cpu %s vCPUs free (need %s), per-repo (%s): %s/%s -- waiting (%ss/%ss)\n' \
            "$PVE_NODE" "$free_mib" "$need_mib" "$free_cpus" "$need_cpus" \
            "${REPO_TAG:-none}" "$repo_count" "${FLEET_SHARE_PER_REPO:-0}" \
            "$waited" "$CAPACITY_TIMEOUT" >&2
        sleep "$CAPACITY_POLL"
        waited=$(( waited + CAPACITY_POLL ))
    done
}

wait_for_capacity || exit 1

# --- Generate an ownership token ---
#
# A random hex token stamped into the VM description at clone time.  Teardown
# refuses to destroy unless the caller presents the same token (db-ogjn).
# Using Python avoids the SIGPIPE that `tr ... | head` triggers under
# set -euo pipefail when head closes the pipe early.
VM_TOKEN=$(python3 -c 'import os,binascii; print(binascii.hexlify(os.urandom(16)).decode())')

# --- Pick a VMID ---
VMID="$(pick_vmid)" || exit 1

# Capture the wall-clock epoch once before the clone loop. provision_time is
# written into the VM description so reap.sh can use it as the authoritative
# age source rather than meta.ctime, which Proxmox may copy verbatim from the
# template instead of updating at clone time (db-e1we).
PROVISION_TIMESTAMP="$(date +%s)"

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
        --data-urlencode "description=runner=${LABEL} vmtoken=${VM_TOKEN} provision_time=${PROVISION_TIMESTAMP}" \
        --data-urlencode "full=0" \
        --data-urlencode "pool=ephemeral-ci")"; then
        clone_upid="$(printf '%s\n' "$clone_body" | python3 -c \
            'import json,sys; print(json.load(sys.stdin).get("data",""))')"
        [ -n "$clone_upid" ] && break
        printf 'provision.sh: clone POST returned no UPID\n' >&2
        exit 1
    fi
    # pvapi already logged HTTP status and raw body above. Parse the body for
    # "Permission check failed (/vms/<id>, <perm>)" so we name the actual
    # refused object rather than always blaming the target VMID (db-g8po).
    _refused_info="$(printf '%s' "$clone_body" | python3 -c \
        'import json,sys,re
b=sys.stdin.read()
try: text=json.dumps(json.loads(b))
except: text=b
m=re.search(r"Permission check failed \(/vms/(\d+),\s*([^)]+)\)", text)
if m: print(m.group(1)+" "+m.group(2).strip())
' 2>/dev/null)" || true
    _refused_vmid="${_refused_info%% *}"
    _refused_perm="${_refused_info#* }"
    if [ "${_refused_vmid:-}" = "$TEMPLATE_VMID" ]; then
        printf 'provision.sh: clone refused: %s denied on template %s -- is template %s in the ephemeral-ci pool?\n' \
            "${_refused_perm:-VM.Clone}" "$TEMPLATE_VMID" "$TEMPLATE_VMID" >&2
    elif [ -n "${_refused_vmid:-}" ]; then
        printf 'provision.sh: clone onto VMID %s refused (%s denied on /vms/%s); asking for a new id\n' \
            "$VMID" "${_refused_perm:-permission}" "$_refused_vmid" >&2
    else
        printf 'provision.sh: clone onto VMID %s refused; asking for a new id\n' "$VMID" >&2
    fi
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

# --- Per-repo tag, set on the CONFIG, never on the clone ---
#
# THE CLONE ENDPOINT HAS NO tags PROPERTY. Proxmox 9.2.2 answers a clone POST
# carrying one with HTTP 400 and refuses the whole request:
#
#   {"errors":{"tags":"property is not defined in schema and the schema does
#    not allow additional properties"}}
#
# and since the clone is also the VMID collision check, all CLONE_RETRIES
# attempts fail identically and provisioning stops dead. That is what happened
# on 2026-09-23 when v1 moved onto the commit that added the parameter: every
# consumer pinned to @v1 lost CI until the tag was moved again.
#
# tags IS accepted on PUT .../config, and the qemu LIST endpoint returns it —
# which is the only thing the per-repo cap needs, since it counts from the
# list (see the repo_count expression above). Verified against the live
# hypervisor, Proxmox 9.2.2, before this change was written.
#
# SET AFTER THE CLONE TASK COMPLETES, not before the VM exists, and treated as
# NON-FATAL. An untagged runner makes the per-repo cap undercount by one for
# this VM's lifetime, which costs a little fairness; refusing to provision
# because a label did not stick would cost the whole job. The failure is
# logged loudly so an undercount is never silent.
if [ -n "${REPO_TAG:-}" ]; then
    if pvapi PUT "/nodes/${PVE_NODE}/qemu/${VMID}/config" \
        --data-urlencode "tags=${REPO_TAG}" >/dev/null; then
        printf 'provision.sh: tagged VM %s with %s\n' "$VMID" "$REPO_TAG" >&2
    else
        printf 'provision.sh: WARNING could not tag VM %s with %s — the per-repo cap will undercount this runner\n' \
            "$VMID" "$REPO_TAG" >&2
    fi
fi

# Emit the VMID and ownership token now -- before any step that can fail --
# so callers can tear down even if we die later. See the output contract at
# the top. The token is emitted here because it has already been stamped into
# the VM description; any post-clone failure still leaves a VM that the caller
# can identify and destroy with the right token.
#
# There is deliberately no ledger write here. A file on this machine's disk
# cannot be read by teardown.sh, which runs in a different job on a different
# ephemeral runner. Ownership is established from the hypervisor instead: the
# VM's name, its pool membership, its template flag, and the token.
printf 'vmid=%s\n' "$VMID"
printf 'vmtoken=%s\n' "$VM_TOKEN"

# --- Serialize boot by template ---
#
# Linked clones from template N all share base-N's volume. Two clones booting
# at once both fault in blocks from that volume; the second can stall long
# enough to miss AGENT_TIMEOUT (sp-bmim8). Hold a per-template lock from VM
# start through agent-ready so at most one clone per template is booting at
# any moment. The lock is released before credential delivery, which does not
# touch the disk path that causes contention.
_BOOT_LOCK_FILE="/var/lock/pve-clone-${TEMPLATE_VMID}.lock"
exec {_boot_lock_fd}>>"$_BOOT_LOCK_FILE" || {
    printf 'provision.sh: cannot open boot lock file %s\n' "$_BOOT_LOCK_FILE" >&2
    exit 1
}
if ! flock -w "$BOOT_LOCK_TIMEOUT" "$_boot_lock_fd"; then
    printf 'provision.sh: timed out waiting for boot lock for template %s (%ss)\n' \
        "$TEMPLATE_VMID" "$BOOT_LOCK_TIMEOUT" >&2
    exit 1
fi
printf 'provision.sh: acquired boot lock for template %s\n' "$TEMPLATE_VMID" >&2

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

# Release the boot lock. The bulk of the base-volume I/O is done once the
# agent answers; subsequent steps (apt masking, credential delivery) touch
# only the clone's own volume.
exec {_boot_lock_fd}>&-
printf 'provision.sh: released boot lock for template %s\n' "$TEMPLATE_VMID" >&2

# --- Mask apt automation ---
#
# A fresh clone inherits the template's systemd unit state. If apt timers are
# enabled, unattended-upgrades or apt-daily-upgrade fires at a random point in
# the first hour and needrestart can restart the runner's service, killing the
# job mid-suite with "The runner has received a shutdown signal". Mask before
# credentials land: the runner never starts on a node where an upgrade can
# interrupt it.
#
# If the template was drifted (timers enabled), refuse: a warning that succeeds
# cannot surface a fault that appears 20 minutes later as a dpkg-lock failure
# (law-a-control-that-cannot-check-must-refuse). The guest's units are masked
# before the check exits so the running clone is safe regardless, but a drifted
# template must be resealed (bash scripts/template-substrate.sh inside the
# template VM, then convert) before CI can provision again.
# If the mask call itself fails, also refuse.
#
# Guest script exit codes:
#   0: all units were already masked/disabled -- template is clean
#   2: one or more were enabled; all are now masked -- template is drifted: refuse
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
    2) printf '::error::provision.sh: template %s has apt automation enabled; reseal the template (bash scripts/template-substrate.sh) before provisioning\n' "$TEMPLATE_VMID" >&2; exit 1 ;;
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
