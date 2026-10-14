#!/usr/bin/env bash
# covers: scripts/run-record.sh
#
# The per-run record (sp-i6qrxk): which instance a CI run got, how long it
# waited for capacity, how long it took to boot and register, and how it ended.
# A job's duration lumps all of that together; this is what separates it.
#
# Sourced by provision.sh, teardown.sh and reap.sh; also runnable as
#   run-record.sh finish <record-json> <register-seconds|-> <outcome>
# which the provision action calls once the runner registers.
#
# Every record is ONE line of JSON, and every log line opens with its own UTC
# stamp -- the producer's clock, not the collector's (law-producers-stamp-
# their-own-clock):
#   2026-10-14T18:03:11Z ephemeral-ci-run-record {"event":"provision",...}
#   2026-10-14T18:21:40Z ephemeral-ci-run-end {"event":"end",...}
# `event` is provision | end. The provision record is also the `run-record`
# job output of the provision action; join the end record on run_id + label.
#
# Provision state lives in a file because ec2_launch runs in a subshell: each
# line is TAB-separated `kind epoch field...`.

rr_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# rr_mark <kind> [field...] -- append an event to the provision state file.
rr_mark() {
    [ -n "${RR_STATE:-}" ] || return 0
    local kind="$1"; shift
    local IFS=$'\t'
    printf '%s\t%s\t%s\n' "$kind" "$(date +%s)" "$*" >> "$RR_STATE" 2>/dev/null || true
}

# rr_vcpus <instance-type> -- vCPUs of a c7i/c8i size (the only families the
# spill role allows): large=2, xlarge=4, Nxlarge=4N. Empty when unknown.
rr_vcpus() {
    case "$1" in
        *.large)   echo 2 ;;
        *.xlarge)  echo 4 ;;
        *.[0-9]*xlarge) local n="${1##*.}"; echo $(( ${n%xlarge} * 4 )) ;;
        *) ;;
    esac
}

# rr_refusal_reason <aws-output> -- the API error code, e.g.
# InsufficientInstanceCapacity or VcpuLimitExceeded; "Unknown" if none.
rr_refusal_reason() {
    local c
    c="$(printf '%s' "$1" | sed -n 's/.*An error occurred (\([A-Za-z0-9.]*\)).*/\1/p' | head -1)"
    printf '%s' "${c:-Unknown}"
}

# rr_log_line <event> <json> -- the stamped log line, to stderr.
rr_log_line() {
    printf '%s ephemeral-ci-run-%s %s\n' "$(rr_stamp)" "$1" "$2" >&2
}

# rr_build_provision <outcome> -- print the provision record as one JSON line.
rr_build_provision() {
    RR_OUTCOME="$1" RR_VCPUS="$(rr_vcpus "${SPILL_INSTANCE_TYPE:-}")" python3 - <<'PY'
import json, os, sys
e = os.environ
ev = []
try:
    with open(e.get("RR_STATE", "/dev/null")) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2 and p[1].isdigit():
                ev.append((p[0], int(p[1]), p[2].split(" ") if len(p) > 2 and p[2] else []))
except OSError:
    pass

def last(kind):
    r = [x for x in ev if x[0] == kind]
    return r[-1] if r else None

def first(kind):
    r = [x for x in ev if x[0] == kind]
    return r[0] if r else None

backend = (last("backend") or (0, 0, [None]))[2][0]
attempt0, accepted = first("attempt"), last("accepted")
refusals = [{"market": x[2][0], "subnet": x[2][1], "reason": x[2][2]}
            for x in ev if x[0] == "refused"]
cap = None
if attempt0 and accepted:
    cap = accepted[1] - attempt0[1]
pw0, pw1 = first("pve_wait_start"), last("pve_wait_end")
boot0 = (accepted or last("boot_start"))
boot1 = last("boot_end")
vcpus = e.get("RR_VCPUS") or e.get("RUNNER_CORES") or ""
rec = {
    "event": "provision",
    "repo": e.get("REPO_SLUG") or None,
    "run_id": e.get("GITHUB_RUN_ID") or None,
    "run_attempt": e.get("GITHUB_RUN_ATTEMPT") or None,
    "label": e.get("LABEL") or None,
    "backend": backend,
    "instance_type": (e.get("SPILL_INSTANCE_TYPE") or None) if backend == "ec2" else None,
    "vcpus": int(vcpus) if backend and vcpus.isdigit() else None,
    "market": (accepted[2][0] if accepted else None) if backend == "ec2" else None,
    "instance_id": e.get("SPILL_INSTANCE_ID") or None,
    "vmid": e.get("VMID") or None,
    "proxmox_wait_s": (pw1[1] - pw0[1]) if pw0 and pw1 else None,
    "capacity_wait_s": cap if backend == "ec2" else ((pw1[1] - pw0[1]) if pw0 and pw1 else None),
    "refusals": refusals,
    "boot_s": (boot1[1] - boot0[1]) if boot0 and boot1 else None,
    "register_s": None,
    "outcome": e.get("RR_OUTCOME"),
}
print(json.dumps(rec, separators=(",", ":")))
PY
}

# rr_emit_provision <rc> -- once per provision, from the EXIT trap. Stdout gets
# `run-record=<json>` for the action to publish; a FAILED provision also logs
# the stamped line here, because the register step that logs it for a
# successful one never runs.
rr_emit_provision() {
    [ -n "${RR_STATE:-}" ] && [ -f "$RR_STATE" ] || return 0
    local rc="$1" outcome=ok json
    [ "$rc" -eq 0 ] || outcome=failed
    json="$(rr_build_provision "$outcome")" || { rm -f "$RR_STATE"; return 0; }
    printf 'run-record=%s\n' "$json"
    [ "$rc" -eq 0 ] || rr_log_line record "$json"
    rm -f "$RR_STATE"
}

# rr_end_record <released_by> <label> <instance-or-vmid> -- the end record.
# released_by is "run" (teardown) or "reaper".
rr_end_record() {
    RR_BY="$1" RR_LABEL="$2" RR_TARGET="$3" python3 - <<'PY'
import json, os, re, time
e = os.environ
label = e.get("RR_LABEL") or e.get("RUNNER_LABEL") or None
# The label is ci-<repo>-<run_id>-<attempt>; the reaper has no run of its own
# to read it from, so a run's end names the run from its label.
m = re.search(r"-(\d+)-\d+$", label or "")
print(json.dumps({
    "event": "end",
    "repo": e.get("REPO_SLUG") or None,
    "run_id": (m.group(1) if m else None) or e.get("GITHUB_RUN_ID") or None,
    "label": label,
    "target": e.get("RR_TARGET") or None,
    "ended_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "released_by": e["RR_BY"],
}, separators=(",", ":")))
PY
}

rr_log_end() { rr_log_line end "$(rr_end_record "$@")"; }

# finish <record-json> <register-seconds|-> <outcome>: complete the provision
# record with the register wait, log it, publish the job output.
rr_finish() {
    local json="$1" reg="$2" outcome="$3"
    json="$(RR_JSON="$json" RR_REG="$reg" RR_OUT="$outcome" python3 -c '
import json, os
r = json.loads(os.environ["RR_JSON"])
reg = os.environ["RR_REG"]
r["register_s"] = int(reg) if reg.isdigit() else None
r["outcome"] = os.environ["RR_OUT"]
print(json.dumps(r, separators=(",", ":")))')" || return 1
    rr_log_line record "$json"
    [ -z "${GITHUB_OUTPUT:-}" ] || printf 'run-record=%s\n' "$json" >> "$GITHUB_OUTPUT"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        finish) [ $# -eq 4 ] || { echo "usage: run-record.sh finish <json> <register-s|-> <outcome>" >&2; exit 2; }
                rr_finish "$2" "$3" "$4" ;;
        *) echo "usage: run-record.sh finish <json> <register-s|-> <outcome>" >&2; exit 2 ;;
    esac
fi
