#!/usr/bin/env bash
# measure-corpus.sh <tag> — run the full suite corpus once at the guest's current
# vCPU count and record wall clock, maxpar, cgroup peak, and CPU/steal utilisation.
#
# Runs ON the measurement guest as user `runner`.
#
# WHY STEAL IS SAMPLED. The guest sits on a hypervisor shared with the live runner
# fleet and two production VMs. If the node has no spare core to give, a guest
# configured with N vCPUs does not get N vCPUs — it gets fewer, and the corpus
# looks like it stopped scaling when in fact it was never given the parallelism.
# Those two causes have opposite conclusions for instance sizing, so a run that
# does not measure steal cannot tell them apart (law-verify-the-discriminating-fact).
set -uo pipefail
TAG="$1"
MAXPAR_OVERRIDE="${2:-}"   # optional: pass a value <= nproc to pin maxpar below the vCPU count
H=/home/runner/spike/harness
OUT=/home/runner/spike/logs
mkdir -p "$OUT"
NCPU=$(nproc)
MEMAVAIL=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo)

# Sample aggregate CPU jiffies (incl. steal) and loadavg every 5s for the whole run.
( while :; do
    printf '%s | %s | load %s\n' "$(date +%s)" "$(head -1 /proc/stat)" "$(cut -d' ' -f1-3 /proc/loadavg)"
    sleep 5
  done ) > "$OUT/cpu-$TAG.samples" &
SAMPLER=$!
trap 'kill "$SAMPLER" 2>/dev/null' EXIT

CPU_BEFORE="$(head -1 /proc/stat)"
SUITES="$(ls "$H"/spira/test-*.sh | xargs -n1 basename | tr '\n' ',' | sed 's/,$//')"
NSUITES="$(printf '%s' "$SUITES" | tr ',' '\n' | wc -l)"

# Explicit minimal environment: the gate's verdict must not depend on anything
# ambient in this session (law-gates-run-in-a-clean-environment). SPIRA_VERDICT_TTL=0
# disables the verdict cache — without it the second and third runs would return a
# cached green in seconds and measure nothing at all.
START=$(date +%s)
( cd "$H" && env -i \
    HOME=/home/runner \
    USER=runner \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    XDG_RUNTIME_DIR="/run/user/$(id -u runner)" \
    TERM=dumb \
    SPIRA_VERDICT_TTL=0 \
    ${MAXPAR_OVERRIDE:+SPIRA_BATCH_MAXPAR=$MAXPAR_OVERRIDE} \
    bash spira/testenv-batch.sh --mode parallel --suites "$SUITES" main \
) > "$OUT/batch-$TAG.log" 2>&1
RC=$?
END=$(date +%s)
CPU_AFTER="$(head -1 /proc/stat)"
kill "$SAMPLER" 2>/dev/null

# Aggregate CPU accounting over the run window: user+nice+system busy, idle+iowait
# idle, steal = time the hypervisor owed this guest and did not deliver.
BUSY_IDLE_STEAL="$(printf '%s\n%s\n' "$CPU_BEFORE" "$CPU_AFTER" | awk '
  NR==1 { for(i=2;i<=11;i++) a[i]=$i }
  NR==2 { for(i=2;i<=11;i++) b[i]=$i
    busy=(b[2]-a[2])+(b[3]-a[3])+(b[4]-a[4])+(b[7]-a[7])+(b[8]-a[8])
    idle=(b[5]-a[5])+(b[6]-a[6]); steal=(b[9]-a[9]); tot=busy+idle+steal
    if(tot>0) printf "busy_pct=%.1f idle_pct=%.1f steal_pct=%.1f", 100*busy/tot, 100*idle/tot, 100*steal/tot
  }')"

{
  printf 'TAG=%s\n' "$TAG"
  printf 'NCPU=%s\n' "$NCPU"
  printf 'MAXPAR_OVERRIDE=%s\n' "${MAXPAR_OVERRIDE:-<none>}"
  printf 'MEMAVAIL_MIB_AT_START=%s\n' "$MEMAVAIL"
  printf 'NSUITES_SELECTED=%s\n' "$NSUITES"
  printf 'RC=%s\n' "$RC"
  printf 'WALL_S=%s\n' "$((END-START))"
  printf 'CPU_ACCOUNTING=%s\n' "$BUSY_IDLE_STEAL"
  printf 'HARNESS_COMMIT=%s\n' "$(cd "$H" && git rev-parse HEAD 2>/dev/null)"
  echo '--- batch self-report ---'
  grep -E 'maxpar:|cgroup peak|batch: wall|suite\(s\) red|all suites passed|harness fault|quarantined|timeout' "$OUT/batch-$TAG.log" || true
} | tee "$OUT/result-$TAG.txt"
