# Excerpt — maxpar derivation in the spira harness
# source:    spira/testenv-batch.sh, between the "#!maxpar-begin" and "#!maxpar-end"
#            markers, in DeckDumpster/spira at commit dd345ae0 (branch main)
# retrieved: 2026-09-23
# why kept:  Finding 1 of the sp-ladgs spike turns on the exact meaning of the
#            word "cpu-bound" in the gate log, which is decided here.
# ---------------------------------------------------------------------------

#!maxpar-begin
# Derive maxpar from the guest's own hardware: min(nproc, floor((avail-reserve)/per_suite)).
# SPIRA_BATCH_MAXPAR is a ceiling: when set, the result is min(N, hardware_maxpar).
# An operator value set for a larger box cannot exceed what this box allows.
# Setting it to 0 disables all capping (useful for small explicit selections or stress tests).
_mem_reserve_mib="${SPIRA_BATCH_MEM_RESERVE_MIB:-1024}"
_mem_per_suite_mib="${SPIRA_BATCH_MEM_PER_SUITE_MIB:-192}"
_maxpar_cpu="$(nproc)"
_mem_avail_mib="${SPIRA_BATCH_MEM_AVAIL_MIB:-$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)}"
_mem_budget=$(( _mem_avail_mib - _mem_reserve_mib ))
[ "${_mem_budget:-0}" -lt "${_mem_per_suite_mib}" ] && _mem_budget="${_mem_per_suite_mib}"
_mem_bound=$(( _mem_budget / _mem_per_suite_mib ))
[ "${_mem_bound:-0}" -lt 1 ] && _mem_bound=1
if [ "${_maxpar_cpu}" -le "${_mem_bound}" ]; then
    _hardware_maxpar="${_maxpar_cpu}"
    _hardware_binding="cpu"
else
    _hardware_maxpar="${_mem_bound}"
    _hardware_binding="memory"
fi
if [ -n "${SPIRA_BATCH_MAXPAR:-}" ] && [ "${SPIRA_BATCH_MAXPAR}" = "0" ]; then
    _maxpar=0
    _maxpar_binding="override-unlimited"
elif [ -n "${SPIRA_BATCH_MAXPAR:-}" ] && [ "${SPIRA_BATCH_MAXPAR}" -le "${_hardware_maxpar}" ] 2>/dev/null; then
    _maxpar="${SPIRA_BATCH_MAXPAR}"
    _maxpar_binding="override"
elif [ -n "${SPIRA_BATCH_MAXPAR:-}" ]; then
    _maxpar="${_hardware_maxpar}"
    _maxpar_binding="${_hardware_binding}"
else
    _maxpar="${_hardware_maxpar}"
    _maxpar_binding="${_hardware_binding}"
fi
#!maxpar-end

# --- and the line that prints it (same file, in the run banner) ---

849:                log "batch: running $_n_selected suite(s) in $CNAME (mode: $MODE, maxpar: $_maxpar [override: SPIRA_BATCH_MAXPAR=${SPIRA_BATCH_MAXPAR:-?}; hardware was ${_hardware_binding}-bound at ${_hardware_maxpar}])" ;;
851:                log "batch: running $_n_selected suite(s) in $CNAME (mode: $MODE, maxpar: $_maxpar [${_maxpar_binding}-bound: cpu=${_maxpar_cpu} mem=${_mem_avail_mib}MiB avail ${_mem_reserve_mib}MiB reserve ${_mem_per_suite_mib}MiB/suite])" ;;
