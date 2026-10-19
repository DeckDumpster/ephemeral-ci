#!/usr/bin/env bash
# covers: scripts/guest-diag.sh
#
# guest-diag.sh must fail loudly when the PVE API cannot be reached, so that
# "could not be read" is distinguishable from "nothing there"
# (law-absence-needs-a-positive-control, sp-23zm9l). A guest that is merely
# broken, or an API that answers with an HTTP error, must still exit 0.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAG="$SCRIPT_DIR/guest-diag.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
ko() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Mock pvapi: MOCK_MODE=transport -> empty status, rc 7; http -> 500, rc 1.
cat > "$T/pvapi.sh" <<'M'
PVAPI_STATUS=""
PVAPI_BODY=""
pvapi() {
    case "$MOCK_MODE" in
        transport) PVAPI_STATUS=""; PVAPI_BODY=""; return 7 ;;
        http) PVAPI_STATUS=500; PVAPI_BODY=""; return 1 ;;
    esac
}
M

run() {
    MOCK_MODE="$1" PVAPI_SH="$T/pvapi.sh" CRED_FILE=/nonexistent PVE_NODE=n1 \
        bash "$DIAG" 101 >"$T/out" 2>"$T/err"
    RC=$?
}

run transport
[ "$RC" -ne 0 ] && ok "unreachable API exits non-zero (rc=$RC)" || ko "unreachable API exited 0"
grep -q 'guest-diag: FATAL - API unreachable' "$T/err" && ok "unreachable API prints FATAL message on stderr" || ko "no FATAL message"
grep -q 'guest-diag: done' "$T/out" && ko "reported done despite unreachable API" || ok "does not report done"

run http
[ "$RC" -eq 0 ] && ok "HTTP error response still exits 0 (positive control)" || ko "HTTP error exited $RC"
grep -q 'exec call failed: HTTP 500' "$T/out" && ok "HTTP error is reported in the section" || ko "HTTP error not reported"
grep -q FATAL "$T/err" && ko "HTTP error wrongly reported as unreachable" || ok "HTTP error is not FATAL"

echo "guest-diag: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
