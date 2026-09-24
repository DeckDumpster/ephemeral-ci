#!/usr/bin/env bash
# Run the harness's OWN maxpar derivation (extracted verbatim between its
# #!maxpar-begin / #!maxpar-end markers) at injected (nproc, MemAvailable) pairs.
# nproc is shadowed by a function so the block is executed unmodified.
set -uo pipefail
printf '%-10s %-14s %-9s %-8s %s\n' "vCPU" "MemAvail(MiB)" "maxpar" "binding" "note"
for pair in "8:14744" "16:14744" "32:14744" "8:4583" "16:4583" "32:4583" "64:4583"; do
  NP="${pair%%:*}"; MA="${pair##*:}"
  out=$(
    nproc() { echo "$NP"; }
    export -f nproc 2>/dev/null || true
    SPIRA_BATCH_MEM_AVAIL_MIB="$MA"
    unset SPIRA_BATCH_MAXPAR
    . /tmp/sp-ladgs/maxpar-block.sh
    printf '%s %s %s' "$_maxpar" "$_maxpar_binding" "$_hardware_maxpar"
  )
  set -- $out
  note=""
  [ "$2" = "memory" ] && note="memory cap bites before the vCPUs are used"
  printf '%-10s %-14s %-9s %-8s %s\n' "$NP" "$MA" "$1" "$2" "$note"
done
