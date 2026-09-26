#!/usr/bin/env bash
#
# Destroy every ephemeral runner VM that is old enough and confirmed idle.
# This is the bead's most important script: if: always() does not cover a
# run GitHub drops, a cancellation landing between clone and output, or the
# hypervisor rebooting mid-run. Without a reaper those become a hypervisor
# full of dead clones, discovered as a storage-full alert weeks later with
# no way to tell which clones are live.
#
# Usage:
#   reap.sh [--max-age-hours N] [--dry-run]
#
# --dry-run prints what it would destroy and touches nothing. This is the
# behaviour a human gets when they run it wrong, so it must be the first
# thing to type when the candidate list looks suspicious.
#
# Destruction requires two confirmations:
#   1. The VM must be old enough (ctime from the Proxmox config API).
#   2. The GitHub busy check must show the runner is not live.
# A VM that fails either check is SKIPPED. An unknown age is a refusal, not
# a licence: VM_EPOCH=0 resolves to 1970, making every VM past the cutoff
# regardless of reality. "I cannot tell how old this is" must mean skip.
#
# Transport: Proxmox HTTP API with an API token, not the qm CLI. The pveum
# grant is scoped to /pool/ephemeral-ci so the token can only see the
# template and live clones, not any other VMs on the host. GET /nodes/qemu
# returns an HTTP status, so a failure is never misread as an empty list.
#
# Age source: the ctime field in the Proxmox config API, written by the
# hypervisor when the VM was cloned. A VM whose ctime cannot be read is
# skipped, never destroyed.
# The real Proxmox meta string (host-verified 2026-09-14):
#   meta: creation-qemu=11.0.0,ctime=1789270996
# ctime= is the epoch. creation-qemu= is the QEMU version string, not a
# timestamp, so awk -F'creation=' was dead code — the next char after
# 'creation' is '-', not '=', so the field separator never matched.
#
# Environment variables (required for live use):
#   PVE_NODE         — Proxmox node name (e.g. "pve")
#   PVE_TOKEN_ID     — Proxmox API token id (user@realm!tokenname)
#   PVE_TOKEN_SECRET — Proxmox API token secret
#   GITHUB_TOKEN     — GitHub API token (for runner busy check)
#   GH_ORG           — GitHub organization; where provision.sh registers runners
#   GH_REPO          — GitHub repository, owner/repo form; only for a
#                      repository-registered runner. GH_ORG takes precedence.
#
# Optional:
#   PVE_API_HOST  — Proxmox API host (default: localhost)
#   PVE_API_PORT  — Proxmox API port (default: 8006)
#   GH_RUN_GRACE  — seconds a run must have been finished before its VM is
#                   eligible for early collection (default: 300). Keeps the
#                   reaper behind the consuming workflow's own teardown.
#   TEMPLATE_VMID — source VM template id (default: 101); never reaped
#   CRED_FILE     — credential file to source (default:
#                   /etc/gh-ephemeral-runner/token); sourced before the
#                   defaults below so TEMPLATE_VMID set there overrides the
#                   compiled-in default of 101.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pvapi.sh
. "${PVAPI_SH:-${SCRIPT_DIR}/pvapi.sh}"

CRED_FILE="${CRED_FILE:-/etc/gh-ephemeral-runner/token}"
if [ -f "$CRED_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CRED_FILE"
fi

TEMPLATE_VMID="${TEMPLATE_VMID:-101}"
GH_RUN_GRACE="${GH_RUN_GRACE:-300}"
SNIPPETS_DIR="${SNIPPETS_DIR:-/var/lib/vz/snippets}"
PVE_NODE="${PVE_NODE:-}"
PVE_API_HOST="${PVE_API_HOST:-localhost}"
PVE_API_PORT="${PVE_API_PORT:-8006}"
PVE_TOKEN_ID="${PVE_TOKEN_ID:-}"
PVE_TOKEN_SECRET="${PVE_TOKEN_SECRET:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GH_REPO="${GH_REPO:-}"
GH_ORG="${GH_ORG:-}"

# MAX_AGE_HOURS must exceed the CI workflow's job timeout-minutes / 60.
# GitHub's own default job timeout is 360 min (6 h); until an explicit
# timeout-minutes is set on the build job, any job can run up to 6 h.
# The default here is 8 h (6 h + 2 h buffer) so the reaper never races a
# live build. When an explicit timeout-minutes lands on the build job, update
# this default to: ceil(timeout_minutes / 60) + 2.
MAX_AGE_HOURS=8
DRY_RUN=false

while [ $# -gt 0 ]; do
    case $1 in
        --max-age-hours)
            if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "reap.sh: --max-age-hours requires a positive integer" >&2
                exit 1
            fi
            MAX_AGE_HOURS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Usage: reap.sh [--max-age-hours N] [--dry-run]" >&2
            exit 1
            ;;
    esac
done

if [ -z "$PVE_NODE" ]; then
    echo "reap.sh: PVE_NODE is required" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# GitHub runner busy check
#
# Returns 0 (true) if the runner named $1 is registered and currently busy.
# Returns 1 (false) if the runner is idle, absent, or the check cannot run.
#
# An ephemeral runner deregisters after its job completes, so "not found"
# is as safe a signal as "found and not busy" — both mean the job is done.
#
# ASK THE ENDPOINT THE RUNNER IS ACTUALLY REGISTERED WITH. This function used
# to query /repos/{GH_REPO}/actions/runners unconditionally. Registration moved
# to the ORG level (so the PAT can hold only "Self-hosted runners" instead of
# repository Administration, with a restricted group doing the confinement),
# and an org-registered runner does not appear in a repository's runner list at
# all. The check therefore found nothing, every VM read as idle, and the only
# surviving guard was age — a check that had silently become a no-op while
# still reporting a clean result, which is the most expensive kind.
#
# The reasoning in the paragraph above is what broke: "not found" only means
# "the job is done" if a LIVE runner would have been found. Against the wrong
# endpoint it means "wrong endpoint". So GH_ORG is preferred and GH_REPO is
# kept only for a repository-registered runner.
#
# When GITHUB_TOKEN is unset, or neither GH_ORG nor GH_REPO is set, a warning
# is printed and the function returns 1 (not busy) so age-based reaping still
# works. This is a degraded mode: the busy-check is skipped and age is the only
# guard. Set GITHUB_TOKEN and GH_ORG in production.
# ---------------------------------------------------------------------------
github_runner_busy() {
    local runner_name="$1"
    if [ -z "$GITHUB_TOKEN" ] || { [ -z "$GH_ORG" ] && [ -z "$GH_REPO" ]; }; then
        echo "reap.sh: WARNING: GITHUB_TOKEN, and GH_ORG or GH_REPO, not set; busy check skipped for $runner_name (degraded mode)" >&2
        return 1
    fi
    # GH_ORG wins: that is where provision.sh registers. GH_REPO remains for a
    # runner registered against a single repository.
    local url
    if [ -n "$GH_ORG" ]; then
        url="https://api.github.com/orgs/${GH_ORG}/actions/runners?per_page=100"
    else
        url="https://api.github.com/repos/${GH_REPO}/actions/runners?per_page=100"
    fi
    local response
    if ! response="$(
        curl --silent --fail --show-error \
            --header "Authorization: Bearer ${GITHUB_TOKEN}" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            "$url" 2>&1
    )"; then
        echo "reap.sh: WARNING: GitHub API request failed; treating $runner_name as not busy" >&2
        return 1
    fi
    python3 - "$response" "$runner_name" <<'EOF'
import json, sys
try:
    for r in json.loads(sys.argv[1]).get("runners", []):
        if r.get("name") == sys.argv[2] and r.get("busy"):
            sys.exit(0)
except Exception as e:
    print(f"reap.sh: WARNING: could not parse GitHub response: {e}", file=sys.stderr)
sys.exit(1)
EOF
}

# ---------------------------------------------------------------------------
# Owning-run check
#
# Returns 0 (true) when the run that provisioned this VM reached a terminal
# state at least GH_RUN_GRACE seconds ago. Returns 1 when the run is still
# going, when the label cannot be parsed, or when the answer cannot be
# obtained -- every uncertainty keeps the VM.
#
# WHY THIS EXISTS. Age was the only licence to destroy, and MAX_AGE_HOURS is 8
# -- the 6 h GitHub job ceiling plus a buffer -- because age cannot tell a
# running job from an abandoned clone. So a VM leaked by a run that failed at
# 04:08 was ineligible for collection until 12:08, and meanwhile held 12 GiB
# and 16 vCPUs on a node whose capacity gate then made every later provision
# wait. Not hypothetical: on 2026-09-23 two such clones stalled CI for the
# better part of an hour, and the operator freed the node by hand.
#
# The run id is a better signal than age, and it was already on the VM:
# provision.sh writes `runner=ci-<repo>-<run_id>-<attempt>` into the
# description. A terminal run cannot acquire a new job, so its VM is garbage
# the moment the run ends, whatever the clock says.
#
# THE GRACE PERIOD IS NOT DECORATION. A run reports "completed" before its
# `if: always()` teardown job has necessarily finished destroying the VM.
# Reaping inside that window races teardown, and both would then report a
# failure for what is really a success. GH_RUN_GRACE keeps the reaper behind
# teardown on the happy path, so it only ever acts where teardown truly did
# not happen.
# ---------------------------------------------------------------------------
owning_run_finished() {
    local label="$1" repo run_id response
    [ -n "$GITHUB_TOKEN" ] && [ -n "$GH_ORG" ] || return 1
    [[ "$label" =~ ^ci-(.+)-([0-9]+)-[0-9]+$ ]] || return 1
    repo="${BASH_REMATCH[1]}"
    run_id="${BASH_REMATCH[2]}"
    if ! response="$(
        curl --silent --fail --show-error \
            --header "Authorization: Bearer ${GITHUB_TOKEN}" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/repos/${GH_ORG}/${repo}/actions/runs/${run_id}" 2>&1
    )"; then
        echo "reap.sh: WARNING: could not read run $run_id in ${GH_ORG}/${repo}; keeping VM" >&2
        return 1
    fi
    python3 - "$response" "$GH_RUN_GRACE" <<'PYRUN'
import calendar, json, sys, time
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
if d.get("status") != "completed":
    sys.exit(1)
stamp = d.get("updated_at") or d.get("run_started_at")
if not stamp:
    sys.exit(1)
try:
    ended = calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
except Exception:
    sys.exit(1)
sys.exit(0 if time.time() - ended >= int(sys.argv[2]) else 1)
PYRUN
}

# ---------------------------------------------------------------------------
# Stop a VM via the Proxmox API and wait for it to reach the stopped state.
# Returns 0 when the VM is stopped; 1 on timeout (60 s).
# ---------------------------------------------------------------------------
vm_stop() {
    local vmid="$1"
    pvapi POST "/nodes/${PVE_NODE}/qemu/${vmid}/status/stop" 2>/dev/null || true
    local deadline=$(( $(date +%s) + 60 ))
    while true; do
        local vm_status
        pvapi GET "/nodes/${PVE_NODE}/qemu/${vmid}/status/current" 2>/dev/null || break
        vm_status="$(printf '%s' "$PVAPI_BODY" \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('status',''))" 2>/dev/null
        )" || break
        [ "$vm_status" = "stopped" ] && return 0
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "reap.sh: timeout waiting for VM $vmid to stop" >&2
            return 1
        fi
        sleep 2
    done
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

NOW="$(date +%s)"
CUTOFF=$(( NOW - MAX_AGE_HOURS * 3600 ))

if "$DRY_RUN"; then
    echo "reap.sh: DRY RUN — max-age-hours=$MAX_AGE_HOURS cutoff=$(date -d "@$CUTOFF" --iso-8601=seconds 2>/dev/null || date -r "$CUTOFF" '+%Y-%m-%dT%H:%M:%S')" >&2
fi

# Read the template's meta.ctime once. Proxmox copies the meta field verbatim
# from the template at clone time, so a clone's meta.ctime is the template's
# creation time, not the clone's own. A VM whose meta.ctime equals the
# template's has an unknown age and must be skipped rather than treated as
# being as old as the template (law-a-control-that-cannot-check-must-refuse).
# On failure the comparison is skipped and the meta.ctime fallback proceeds.
TEMPLATE_META_EPOCH=""
if pvapi GET "/nodes/${PVE_NODE}/qemu/${TEMPLATE_VMID}/config" && [[ "${PVAPI_STATUS:-}" = 2* ]]; then
    TEMPLATE_META_EPOCH="$(python3 - "$PVAPI_BODY" <<'EOF'
import json, sys, re
meta = json.loads(sys.argv[1]).get("data", {}).get("meta", "")
m = re.search(r"ctime=(\d+)", meta)
print(m.group(1) if m else "")
EOF
)"
fi

# Enumerate runner VMs via the Proxmox API.
# A failure here is a hard error: we cannot reap safely if we cannot enumerate.
# The pveum grant is scoped to /pool/ephemeral-ci so this only sees the
# template and live clones; the gh-runner-* name filter is still required
# because the template itself is in the pool and must never be reaped.
QEMU_LIST=""
if ! pvapi GET "/nodes/${PVE_NODE}/qemu"; then
    echo "reap.sh: failed to enumerate VMs from Proxmox API" >&2
    exit 1
fi
if [[ "${PVAPI_STATUS:-}" != 2* ]]; then
    echo "reap.sh: failed to enumerate VMs from Proxmox API (HTTP ${PVAPI_STATUS:-})" >&2
    exit 1
fi
QEMU_LIST="$PVAPI_BODY"

mapfile -t RUNNER_VMIDS < <(
    python3 - "$QEMU_LIST" <<'EOF'
import json, sys
for vm in json.loads(sys.argv[1]).get("data", []):
    if vm.get("name", "").startswith("gh-runner-"):
        print(vm["vmid"])
EOF
)

if [ "${#RUNNER_VMIDS[@]}" -eq 0 ]; then
    echo "reap.sh: no gh-runner-* VMs visible to this token" >&2
    exit 0
fi

reaped=0
skipped=0
unknown_age=0

for VMID in "${RUNNER_VMIDS[@]}"; do
    # Never touch the template, even if it were somehow named gh-runner-*.
    if [ "$VMID" -eq "$TEMPLATE_VMID" ]; then
        echo "reap.sh: skipping template VMID $TEMPLATE_VMID" >&2
        (( skipped++ )) || true
        continue
    fi

    # Refuse any VM whose list entry carries template:1, regardless of
    # TEMPLATE_VMID. The id is configuration and can be wrong; the template
    # flag is a fact written by Proxmox when the VM was converted and cannot
    # be falsified by a misconfigured default.
    VM_IS_TEMPLATE="$(python3 - "$QEMU_LIST" "$VMID" <<'EOF'
import json, sys
for vm in json.loads(sys.argv[1]).get("data", []):
    if str(vm.get("vmid", "")) == sys.argv[2]:
        print(1 if vm.get("template") else 0)
        break
else:
    print(0)
EOF
)"
    if [ "${VM_IS_TEMPLATE:-0}" = "1" ]; then
        echo "reap.sh: skipping template VMID $VMID (template:1 in config)" >&2
        (( skipped++ )) || true
        continue
    fi

    # The VM name from the enumeration payload drives the GitHub busy check.
    VM_NAME="$(python3 - "$QEMU_LIST" "$VMID" <<'EOF'
import json, sys
for vm in json.loads(sys.argv[1]).get("data", []):
    if str(vm.get("vmid", "")) == sys.argv[2]:
        print(vm.get("name", ""))
        break
EOF
)"

    # --- Age determination ---
    # The ctime field in the Proxmox config API is the only age source.
    #
    # It used to prefer an epoch recorded in a local ledger file, falling back
    # to this. The ledger is gone: it lived on the filesystem of whichever
    # machine ran the script, and this now runs on an ephemeral GitHub runner
    # where it is always absent. Removing it costs nothing, because ctime is
    # written by the hypervisor at clone time and is authoritative in a way a
    # file this script writes about itself never was.
    VM_EPOCH=""
    AGE_SOURCE=""

    # The Proxmox meta string looks like:
    #   creation-qemu=11.0.0,ctime=1789270996
    # The epoch is ctime=; creation-qemu= is the QEMU version (not a
    # timestamp). Reading from the API JSON avoids the original awk
    # field-separator bug where awk -F'creation=' never matched.
    VM_CONFIG=""
    if ! pvapi GET "/nodes/${PVE_NODE}/qemu/${VMID}/config"; then
        echo "reap.sh: VM $VMID ($VM_NAME): failed to read config; skipping" >&2
        (( skipped++ )) || true
        (( unknown_age++ )) || true
        continue
    fi
    if [[ "${PVAPI_STATUS:-}" != 2* ]]; then
        echo "reap.sh: VM $VMID ($VM_NAME): config API returned HTTP ${PVAPI_STATUS:-}; skipping" >&2
        (( skipped++ )) || true
        (( unknown_age++ )) || true
        continue
    fi
    VM_CONFIG="$PVAPI_BODY"

    # Prefer provision_time= from the VM description (written by provision.sh
    # at clone time) over meta.ctime. Proxmox copies the meta field verbatim
    # from the template at clone time, so meta.ctime reflects when the template
    # was created, not the clone — causing over-estimation of a clone's age and
    # potentially triggering reaping of a VM that is younger than it appears
    # (db-e1we). provision_time= is written by provision.sh, so it is always
    # the actual clone time for VMs provisioned after this change. Fall back to
    # meta.ctime for older VMs that predate provision_time= in the description.
    PROVISION_EPOCH="$(python3 - "$VM_CONFIG" <<'EOF'
import json, re, sys
try:
    desc = json.loads(sys.argv[1]).get("data", {}).get("description", "") or ""
except Exception:
    desc = ""
m = re.search(r"provision_time=(\d+)", desc)
print(m.group(1) if m else "")
EOF
)"
    META_EPOCH="$(python3 - "$VM_CONFIG" <<'EOF'
import json, sys, re
meta = json.loads(sys.argv[1]).get("data", {}).get("meta", "")
m = re.search(r"ctime=(\d+)", meta)
print(m.group(1) if m else "")
EOF
)"
    if [ -n "$PROVISION_EPOCH" ] && [[ "$PROVISION_EPOCH" =~ ^[0-9]+$ ]]; then
        VM_EPOCH="$PROVISION_EPOCH"
        AGE_SOURCE="provision-time"
    elif [ -n "$META_EPOCH" ] && [[ "$META_EPOCH" =~ ^[0-9]+$ ]]; then
        # meta.ctime is copied verbatim from the template at clone time.
        # When it matches the template's own ctime, the value is the template's
        # creation time — not this clone's — and the age is unknown.
        if [ -n "$TEMPLATE_META_EPOCH" ] && [ "$META_EPOCH" = "$TEMPLATE_META_EPOCH" ]; then
            echo "reap.sh: VM $VMID ($VM_NAME): meta.ctime matches template's — age unknown; skipping" >&2
            (( skipped++ )) || true
            (( unknown_age++ )) || true
            continue
        fi
        VM_EPOCH="$META_EPOCH"
        AGE_SOURCE="qm-config"
    else
        # Neither provision_time= nor meta.ctime can give us an age.
        # Skipping is the only safe choice. VM_EPOCH=0 would resolve to
        # 1970, making this VM older than any cutoff and authorising
        # destruction with no evidence — which is exactly the defect this
        # replaces. An orphan that survives another hour costs disk; a
        # running build destroyed as an orphan costs a red CI run and an
        # hour of someone's confidence.
        echo "reap.sh: VM $VMID ($VM_NAME): no provision_time or ctime in config, age unknown; skipping" >&2
        (( skipped++ )) || true
        (( unknown_age++ )) || true
        continue
    fi

    AGE_SECONDS=$(( NOW - VM_EPOCH ))
    AGE_HOURS=$(( AGE_SECONDS / 3600 ))

    # --- Busy check ---
    # A runner deregisters from GitHub when its job finishes (--ephemeral),
    # so "not found" in the runners list is as safe as "found and not busy".
    # Only a "found AND busy" result protects the VM from the age check.
    #
    # ASK ABOUT THE RUNNER, NOT THE VM. This used to pass $VM_NAME, which is
    # gh-runner-<vmid> -- the name teardown.sh's safety guard requires. The
    # RUNNER is registered under a different string entirely (the job's unique
    # label), so the lookup could never match and every VM read as idle. Since
    # nothing failed and nothing was logged, the check reported clean while
    # doing nothing, and age was the only guard left.
    #
    # provision.sh now records `runner=<label>` in the VM description, which
    # arrives in the same config payload as ctime. A VM with no such
    # description is one provisioned before that change: fall back to the VM
    # name, which preserves the old (useless but harmless) behaviour rather
    # than inventing a name that might collide with a live runner.
    RUNNER_NAME="$(python3 - "$VM_CONFIG" <<'EOF'
import json, re, sys
try:
    desc = json.loads(sys.argv[1]).get("data", {}).get("description", "") or ""
except Exception:
    desc = ""
m = re.search(r"^runner=(\S+)", desc, re.M)
print(m.group(1) if m else "")
EOF
)"
    if [ -z "$RUNNER_NAME" ]; then
        echo "reap.sh: VM $VMID ($VM_NAME): no runner= in description; falling back to the VM name for the busy check" >&2
        RUNNER_NAME="$VM_NAME"
    fi

    if github_runner_busy "$RUNNER_NAME"; then
        echo "reap.sh: VM $VMID ($VM_NAME, runner $RUNNER_NAME, ${AGE_HOURS}h old): runner is busy — keeping" >&2
        (( skipped++ )) || true
        continue
    fi

    # --- Owning-run check ---
    # The only path that destroys a VM younger than MAX_AGE_HOURS, and it
    # needs BOTH confirmations: the runner is not busy (checked above) and the
    # owning run has been terminal for GH_RUN_GRACE seconds.
    ORPHAN_BY_RUN=0
    if [ "$VM_EPOCH" -gt "$CUTOFF" ] && owning_run_finished "$RUNNER_NAME"; then
        echo "reap.sh: VM $VMID ($VM_NAME, runner $RUNNER_NAME, ${AGE_HOURS}h old): owning run is finished — reaping without waiting for the age cutoff" >&2
        ORPHAN_BY_RUN=1
    fi

    # --- Age check ---
    if [ "$VM_EPOCH" -gt "$CUTOFF" ] && [ "$ORPHAN_BY_RUN" -eq 0 ]; then
        echo "reap.sh: VM $VMID ($VM_NAME, $AGE_SOURCE) is ${AGE_HOURS}h old — keeping" >&2
        (( skipped++ )) || true
        continue
    fi

    if "$DRY_RUN"; then
        echo "reap.sh: DRY RUN — would destroy VM $VMID ($VM_NAME, $AGE_SOURCE, ${AGE_HOURS}h old)" >&2
        (( reaped++ )) || true
        continue
    fi

    echo "reap.sh: destroying VM $VMID ($VM_NAME, $AGE_SOURCE, ${AGE_HOURS}h old)" >&2

    # Stop first; ignore stop failure (VM may already be stopped or in error).
    vm_stop "$VMID" || true

    # Destroy. purge=1 removes disks and snapshots registered to this VM.
    if pvapi DELETE "/nodes/${PVE_NODE}/qemu/${VMID}?purge=1" && [[ "${PVAPI_STATUS:-}" = 2* ]]; then
        # Remove the cloud-init snippet that holds the registration token.
        # An orphan by definition never had a teardown, so nothing removed it.
        _REAP_SNIPPET="${SNIPPETS_DIR}/gh-runner-${VMID}.yaml"
        if [ -f "$_REAP_SNIPPET" ]; then
            shred -u "$_REAP_SNIPPET" 2>/dev/null || rm -f "$_REAP_SNIPPET"
        fi
        echo "reap.sh: VM $VMID destroyed" >&2
        (( reaped++ )) || true
    else
        echo "reap.sh: VM $VMID: destroy failed" >&2
        (( skipped++ )) || true
    fi
done

if "$DRY_RUN"; then
    echo "reap.sh: DRY RUN complete — would destroy $reaped VM(s), skip $skipped" >&2
else
    echo "reap.sh: done — destroyed $reaped VM(s), kept $skipped" >&2
fi

# Exit non-zero when any VM was skipped for unknown age so the calling
# workflow surfaces the anomaly. Reaping something is not a success;
# failing to determine age and skipping is a warning that demands attention.
if [ "$unknown_age" -gt 0 ]; then
    echo "reap.sh: $unknown_age VM(s) had unknown age and were skipped — investigate" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# EC2 spill reaping
#
# Terminates EC2 instances tagged spill:owner=ephemeral-ci when the owning
# run has finished (early collection) or when the instance exceeds
# MAX_AGE_HOURS. Instances whose runner is currently busy are kept.
#
# Falls back to age-only mode when the ephemeral-ci:runner tag is absent;
# provision.sh must tag runner instances with that key for the busy check
# and early-collection path to function.
#
# Also terminates:
#   - stale AMI-builder instances (Name=ephemeral-ci-runner, age-only)
#   - orphaned EBS volumes tagged spill:owner=ephemeral-ci in available state
#
# Skipped gracefully when the aws CLI is unavailable or credentials are not
# configured.
#
# Environment variables:
#   SPILL_REGION — AWS region (default: us-west-2)
# ---------------------------------------------------------------------------

SPILL_REGION="${SPILL_REGION:-us-west-2}"

# Return the on-demand cost estimate string for <age_seconds> of <instance_type>.
# Prints "~$N.NNNN" for known types or "<N.Nh> (rate unknown for <type>)" otherwise.
_ec2_cost_estimate() {
    local age_s="$1" itype="$2"
    python3 - "$age_s" "$itype" <<'EOF'
import sys
age = int(sys.argv[1]) if len(sys.argv) > 1 else 0
itype = sys.argv[2] if len(sys.argv) > 2 else ""
rates = {
    "c7i.xlarge":  0.2013, "c7i.large":   0.1007, "c7i.2xlarge": 0.4026,
    "c7i.4xlarge": 0.8052, "c8i.xlarge":  0.2112, "c8i.large":   0.1056,
    "c8i.2xlarge": 0.4224, "t3.micro":    0.0104, "t3.small":    0.0208,
    "t3.medium":   0.0416, "t3.large":    0.0832,
}
rate = rates.get(itype, 0)
hours = age / 3600.0
if rate > 0:
    print("~$%.4f (%s, %.1fh)" % (hours * rate, itype, hours))
else:
    print("%.1fh (rate unknown for %s)" % (hours, itype))
EOF
}

# Convert an EC2 ISO-8601 LaunchTime string to a Unix epoch integer.
# Prints 0 on parse failure.
_ec2_launch_epoch() {
    python3 - "$1" <<'EOF'
import sys
from datetime import datetime, timezone
t = sys.argv[1] if len(sys.argv) > 1 else ""
if not t:
    print(0); sys.exit(0)
try:
    dt = datetime.fromisoformat(t.replace("Z", "+00:00"))
    print(int(dt.timestamp()))
except Exception:
    print(0)
EOF
}

if ! command -v aws >/dev/null 2>&1; then
    echo "reap.sh: aws CLI not found; EC2 reaping skipped" >&2
elif ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "reap.sh: AWS credentials not configured; EC2 reaping skipped" >&2
else

ec2_reaped=0
ec2_skipped=0
ec2_unknown_launch=0

# Enumerate non-terminated instances carrying the spill tag.
# A hard failure here (API error) is propagated as a script error: we cannot
# reap safely if we cannot enumerate, just as with the Proxmox section.
EC2_LIST_JSON=""
if ! EC2_LIST_JSON="$(aws ec2 describe-instances \
        --region "$SPILL_REGION" \
        --filters \
            "Name=tag:spill:owner,Values=ephemeral-ci" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[*].Instances[*].{id:InstanceId,state:State.Name,launch:LaunchTime,type:InstanceType,tags:Tags}' \
        --output json 2>&1)"; then
    echo "reap.sh: EC2 describe-instances failed: $EC2_LIST_JSON" >&2
    exit 1
fi

# Flatten [[batch], [batch], ...] → [instance, ...]
EC2_INSTANCES="$(python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(json.dumps([x for b in d for x in b]))' \
    <<< "$EC2_LIST_JSON")"

EC2_COUNT="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' \
    <<< "$EC2_INSTANCES")"

if [ "${EC2_COUNT:-0}" -eq 0 ]; then
    echo "reap.sh: EC2: no tagged instances (pending/running/stopping/stopped)" >&2
else
    echo "reap.sh: EC2: $EC2_COUNT tagged instance(s) to evaluate" >&2
fi

while IFS= read -r _ec2_line; do
    [ -z "$_ec2_line" ] && continue

    _ec2_tag() {
        python3 - "$_ec2_line" "$1" <<'PYEOF'
import json,sys
d=json.loads(sys.argv[1])
tags=d.get('tags',[]) or []
print(next((t['Value'] for t in tags if t['Key']==sys.argv[2]),''))
PYEOF
    }

    EC2_IID="$(python3      -c "import json,sys; print(json.loads(sys.argv[1]).get('id',''))"     "$_ec2_line")"
    EC2_STATE="$(python3    -c "import json,sys; print(json.loads(sys.argv[1]).get('state',''))"  "$_ec2_line")"
    EC2_LAUNCH="$(python3   -c "import json,sys; print(json.loads(sys.argv[1]).get('launch',''))" "$_ec2_line")"
    EC2_TYPE="$(python3     -c "import json,sys; print(json.loads(sys.argv[1]).get('type',''))"   "$_ec2_line")"
    EC2_NAME="$(_ec2_tag Name)"
    EC2_RUNNER_LABEL="$(_ec2_tag "ephemeral-ci:runner")"

    EC2_LAUNCH_EPOCH="$(_ec2_launch_epoch "$EC2_LAUNCH")"

    if [ "${EC2_LAUNCH_EPOCH:-0}" -eq 0 ]; then
        echo "reap.sh: EC2 $EC2_IID ($EC2_NAME): cannot parse LaunchTime '$EC2_LAUNCH' — skipping" >&2
        (( ec2_skipped++ )) || true
        (( ec2_unknown_launch++ )) || true
        continue
    fi

    EC2_AGE_SECONDS=$(( NOW - EC2_LAUNCH_EPOCH ))
    EC2_AGE_HOURS=$(( EC2_AGE_SECONDS / 3600 ))
    EC2_COST="$(_ec2_cost_estimate "$EC2_AGE_SECONDS" "$EC2_TYPE")"

    # AMI-builder instances (Name=ephemeral-ci-runner): age cutoff only.
    # Builder instances do not register a GitHub runner so busy/run checks
    # do not apply.
    if [ "$EC2_NAME" = "ephemeral-ci-runner" ]; then
        if [ "$EC2_LAUNCH_EPOCH" -gt "$CUTOFF" ]; then
            echo "reap.sh: EC2 builder $EC2_IID (${EC2_AGE_HOURS}h, $EC2_COST): within age cutoff — keeping" >&2
            (( ec2_skipped++ )) || true
            continue
        fi
        if "$DRY_RUN"; then
            echo "reap.sh: DRY RUN — would terminate EC2 builder $EC2_IID (${EC2_AGE_HOURS}h, $EC2_COST)" >&2
            (( ec2_reaped++ )) || true
            continue
        fi
        echo "reap.sh: terminating stale EC2 builder $EC2_IID (${EC2_AGE_HOURS}h, $EC2_COST)" >&2
        if aws ec2 terminate-instances \
                --region "$SPILL_REGION" \
                --instance-ids "$EC2_IID" >/dev/null 2>&1; then
            echo "reap.sh: EC2 builder $EC2_IID terminated" >&2
            (( ec2_reaped++ )) || true
        else
            echo "reap.sh: EC2 builder $EC2_IID: terminate failed" >&2
            (( ec2_skipped++ )) || true
        fi
        continue
    fi

    # Runner instances: busy check + owning-run check + age cutoff.
    if [ -n "$EC2_RUNNER_LABEL" ]; then
        # A busy runner must not be reaped regardless of age.
        if github_runner_busy "$EC2_RUNNER_LABEL"; then
            echo "reap.sh: EC2 $EC2_IID ($EC2_NAME, runner $EC2_RUNNER_LABEL, ${EC2_AGE_HOURS}h): runner busy — keeping" >&2
            (( ec2_skipped++ )) || true
            continue
        fi

        # Early collection: reap an instance younger than MAX_AGE_HOURS when
        # its owning run has already reached a terminal state and the grace
        # period has elapsed. Same logic as the Proxmox VM path.
        EC2_ORPHAN_BY_RUN=0
        if [ "$EC2_LAUNCH_EPOCH" -gt "$CUTOFF" ] && owning_run_finished "$EC2_RUNNER_LABEL"; then
            echo "reap.sh: EC2 $EC2_IID ($EC2_NAME, runner $EC2_RUNNER_LABEL, ${EC2_AGE_HOURS}h): owning run finished — early collection" >&2
            EC2_ORPHAN_BY_RUN=1
        fi

        if [ "$EC2_LAUNCH_EPOCH" -gt "$CUTOFF" ] && [ "$EC2_ORPHAN_BY_RUN" -eq 0 ]; then
            echo "reap.sh: EC2 $EC2_IID ($EC2_NAME, runner $EC2_RUNNER_LABEL, ${EC2_AGE_HOURS}h): within age cutoff — keeping" >&2
            (( ec2_skipped++ )) || true
            continue
        fi
    else
        # Degraded mode: the ephemeral-ci:runner tag is absent.
        # provision.sh must set this tag so the busy check and early
        # collection can function; without it only the age cutoff protects
        # running jobs, and the owning-run early-collection path is disabled.
        echo "reap.sh: EC2 $EC2_IID ($EC2_NAME): no ephemeral-ci:runner tag — degraded mode (age-only). provision.sh must tag runner instances." >&2
        if [ "$EC2_LAUNCH_EPOCH" -gt "$CUTOFF" ]; then
            echo "reap.sh: EC2 $EC2_IID ($EC2_NAME, ${EC2_AGE_HOURS}h): within age cutoff — keeping" >&2
            (( ec2_skipped++ )) || true
            continue
        fi
    fi

    if "$DRY_RUN"; then
        echo "reap.sh: DRY RUN — would terminate EC2 $EC2_IID ($EC2_NAME, ${EC2_AGE_HOURS}h, $EC2_COST)" >&2
        (( ec2_reaped++ )) || true
        continue
    fi

    echo "reap.sh: terminating EC2 instance $EC2_IID ($EC2_NAME, ${EC2_AGE_HOURS}h, $EC2_COST)" >&2
    if aws ec2 terminate-instances \
            --region "$SPILL_REGION" \
            --instance-ids "$EC2_IID" >/dev/null 2>&1; then
        echo "reap.sh: EC2 instance $EC2_IID terminated" >&2
        (( ec2_reaped++ )) || true
    else
        echo "reap.sh: EC2 instance $EC2_IID: terminate failed" >&2
        (( ec2_skipped++ )) || true
    fi

done < <(python3 -c \
    'import json,sys; [print(json.dumps(x)) for x in json.load(sys.stdin)]' \
    <<< "$EC2_INSTANCES")

# ---- Orphaned EBS volumes ----
# Volumes tagged spill:owner=ephemeral-ci in the available state are not
# attached to any instance; they were left behind when an instance was
# terminated without first detaching them (or when terminate-on-delete was
# not set). Delete them unconditionally — an unattached spill volume has
# no useful state.
EC2_VOL_JSON=""
ec2_vols_reaped=0
if EC2_VOL_JSON="$(aws ec2 describe-volumes \
        --region "$SPILL_REGION" \
        --filters \
            "Name=tag:spill:owner,Values=ephemeral-ci" \
            "Name=status,Values=available" \
        --query 'Volumes[*].{id:VolumeId,size:Size}' \
        --output json 2>/dev/null)"; then
    while IFS= read -r _vol_line; do
        [ -z "$_vol_line" ] && continue
        _vol_id="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('id',''))" "$_vol_line")"
        _vol_gib="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('size',0))" "$_vol_line")"
        if "$DRY_RUN"; then
            echo "reap.sh: DRY RUN — would delete orphaned EBS volume $_vol_id (${_vol_gib} GiB)" >&2
            (( ec2_vols_reaped++ )) || true
            continue
        fi
        echo "reap.sh: deleting orphaned EBS volume $_vol_id (${_vol_gib} GiB)" >&2
        if aws ec2 delete-volume \
                --region "$SPILL_REGION" \
                --volume-id "$_vol_id" >/dev/null 2>&1; then
            echo "reap.sh: EBS volume $_vol_id deleted" >&2
            (( ec2_vols_reaped++ )) || true
        else
            echo "reap.sh: EBS volume $_vol_id: delete failed" >&2
        fi
    done < <(python3 -c \
        'import json,sys; [print(json.dumps(x)) for x in json.load(sys.stdin)]' \
        <<< "$EC2_VOL_JSON")
fi

# ---- EC2 summary ----
if "$DRY_RUN"; then
    echo "reap.sh: EC2 DRY RUN complete — would terminate $ec2_reaped instance(s), skip $ec2_skipped, delete $ec2_vols_reaped volume(s)" >&2
else
    echo "reap.sh: EC2 done — terminated $ec2_reaped instance(s), kept $ec2_skipped, deleted $ec2_vols_reaped volume(s)" >&2
fi

if [ "$ec2_unknown_launch" -gt 0 ]; then
    echo "reap.sh: EC2: $ec2_unknown_launch instance(s) had unparseable launch time — investigate" >&2
    exit 1
fi

fi  # end: aws CLI available block
