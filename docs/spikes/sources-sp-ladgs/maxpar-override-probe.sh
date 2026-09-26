#!/usr/bin/env bash
# Does SPIRA_BATCH_MAXPAR let an operator raise maxpar ABOVE nproc?
# Executes the harness's own derivation block; nproc shadowed by a function.
set -uo pipefail
printf '%-8s %-14s %-22s %-8s %-18s %s\n' "nproc" "MemAvail(MiB)" "SPIRA_BATCH_MAXPAR" "maxpar" "binding" "verdict"
for spec in "8:14744:" "8:14744:4" "8:14744:16" "8:14744:32" "8:14744:0" "16:4583:32"; do
  IFS=: read -r NP MA OV <<<"$spec"
  out=$(
    nproc() { echo "$NP"; }
    SPIRA_BATCH_MEM_AVAIL_MIB="$MA"
    if [ -n "$OV" ]; then SPIRA_BATCH_MAXPAR="$OV"; else unset SPIRA_BATCH_MAXPAR; fi
    . /tmp/sp-ladgs/maxpar-block.sh
    printf '%s %s' "$_maxpar" "$_maxpar_binding"
  )
  set -- $out
  verdict=""
  if [ -n "$OV" ] && [ "$OV" != "0" ] && [ "$OV" -gt "$NP" ] 2>/dev/null; then
    if [ "$1" -eq "$NP" ]; then verdict="CLAMPED to nproc — the ask was $OV"; else verdict="honoured above nproc"; fi
  fi
  [ "$OV" = "0" ] && verdict="0 = uncapped entirely"
  printf '%-8s %-14s %-22s %-8s %-18s %s\n' "$NP" "$MA" "${OV:-<unset>}" "$1" "$2" "$verdict"
done
