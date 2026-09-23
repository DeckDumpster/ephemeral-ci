#!/usr/bin/env bash
# covers: deploy/ephemeral-runner/teardown.sh
#
# Stubs the Proxmox API via PVAPI_SH so no hypervisor is required.
# Each test writes per-call responses into a directory; the mock pvapi()
# reads them in sequence and logs every call so assertions can verify
# which API calls were (and were not) made.
#
# Run: bash deploy/ephemeral-runner/test-teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEARDOWN="$SCRIPT_DIR/teardown.sh"

PASS=0
FAIL=0

# Fixed token used by all tests that expect teardown to pass Guard 4b.
# Tests that check token-mismatch behaviour set VM_TOKEN to a different value.
TEST_VM_TOKEN="aabbccdd11223344aabbccdd11223344"

_die() { echo "FATAL: $*" >&2; exit 1; }

# --- Test infrastructure ---

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

_setup() {
    # Create a fresh test directory. Sets:
    #   TDIR          — per-test temp directory
    #   PVAPI_LOG     — file recording every pvapi call (method:path:body)
    #   PVAPI_CALL_FILE — file holding the current call count
    #   PVAPI_RESPONSES — directory; file N holds status\nbody for call N
    #   PVAPI_SH      — path to the mock pvapi.sh for this test
    TDIR=$(mktemp -d -p "$TMPDIR_ROOT")
    PVAPI_LOG="$TDIR/pvapi.log"
    PVAPI_CALL_FILE="$TDIR/call_count"
    PVAPI_RESPONSES="$TDIR/responses"
    mkdir -p "$PVAPI_RESPONSES"
    printf '0' > "$PVAPI_CALL_FILE"
    PVAPI_SH="$TDIR/pvapi.sh"
    # Write the mock pvapi.sh. It reads sequenced response files; when a
    # response file is absent it defaults to HTTP 200 with an empty body.
    cat > "$PVAPI_SH" <<'MOCK'
PVAPI_STATUS=""
PVAPI_BODY=""
pvapi() {
    local method="$1" path="$2" body="${3:-}"
    PVAPI_STATUS=""
    PVAPI_BODY=""
    local count
    count=$(cat "${PVAPI_CALL_FILE}")
    count=$(( count + 1 ))
    printf '%d' "$count" > "${PVAPI_CALL_FILE}"
    printf 'PVAPI:%s:%s:%s\n' "$method" "$path" "$body" >> "${PVAPI_LOG}"
    local resp_file="${PVAPI_RESPONSES}/${count}"
    if [ -f "$resp_file" ]; then
        PVAPI_STATUS=$(head -1 "$resp_file")
        PVAPI_BODY=$(tail -n +2 "$resp_file")
    else
        PVAPI_STATUS="200"
        PVAPI_BODY='{}'
    fi
}
MOCK
}

_resp() {
    # _resp <call_number> <http_status> [body]
    local n="$1" status="$2" body="${3:-}"
    [ -z "$body" ] && body='{}'
    printf '%s\n%s\n' "$status" "$body" > "${PVAPI_RESPONSES}/${n}"
}

# Pool membership response bodies. Guard 5 reads GET /pools/<pool> and looks
# for the vmid among .data.members[].
_pool_with()    { printf '{"data":{"members":[{"vmid":%s,"type":"qemu"}]}}' "$1"; }
_pool_without() { printf '{"data":{"members":[{"vmid":999,"type":"qemu"}]}}'; }

# Config response body with the test token embedded in the description.
# Guard 4b reads .data.description and extracts vmtoken=.
_config_with_token() {
    local vmid="$1" token="${2:-$TEST_VM_TOKEN}"
    printf '{"data":{"name":"gh-runner-%s","cores":2,"description":"runner=test-runner vmtoken=%s"}}' \
        "$vmid" "$token"
}


_call_count() {
    cat "$PVAPI_CALL_FILE"
}

_log_has() {
    # _log_has <pattern> — true if the pvapi log contains the pattern
    grep -q "$1" "$PVAPI_LOG" 2>/dev/null
}

_assert_eq() {
    local label="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        return 0
    fi
    echo "  FAIL: $label: got '$got', expected '$expected'" >&2
    return 1
}

_run_teardown() {
    # Run teardown.sh with the current test fixtures; returns its exit code.
    # All API env vars are set; STOP_TIMEOUT/POLL/WAIT are minimised so
    # timeout tests do not take seconds.
    # VM_TOKEN defaults to TEST_VM_TOKEN; tests that check mismatch behaviour
    # set VM_TOKEN explicitly before calling _run_teardown.
    PVAPI_SH="$PVAPI_SH" \
    PVAPI_LOG="$PVAPI_LOG" \
    PVAPI_CALL_FILE="$PVAPI_CALL_FILE" \
    PVAPI_RESPONSES="$PVAPI_RESPONSES" \
    PVE_POOL="${PVE_POOL:-ephemeral-ci}" \
    TEMPLATE_VMID="${TEMPLATE_VMID:-101}" \
    PVE_API_HOST=pve-test \
    PVE_NODE=pve \
    PVE_TOKEN_ID=test@pve!tok \
    PVE_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
    VM_TOKEN="${VM_TOKEN-$TEST_VM_TOKEN}" \
    STOP_TIMEOUT="${STOP_TIMEOUT:-1}" \
    STOP_POLL_INTERVAL=0 \
    FORCE_STOP_WAIT=0 \
    JOURNAL_TIMEOUT="${JOURNAL_TIMEOUT:-2}" \
    JOURNAL_POLL_INTERVAL=0 \
    bash "$TEARDOWN" "$@"
}

_pass() { (( PASS++ )) || true; echo "  PASS: $1"; }
_fail() { (( FAIL++ )) || true; echo "  FAIL: $1"; }

_check() {
    # _check <label> <exit_code_assertion> <assertion_commands...>
    # Runs the named check and records pass/fail.
    local label="$1"
    if "$@"; then
        _pass "$label"
    else
        _fail "$label"
    fi
}

# --- Helpers that each test uses as assertions ---

_assert_rc() { local label="$1" rc="$2" expected="$3"; _assert_eq "$label" "$rc" "$expected"; }

_assert_log_has()    { _log_has "$1" || { echo "  FAIL: expected API call matching '$1' not found" >&2; return 1; }; }
_assert_log_not_has() { ! _log_has "$1" || { echo "  FAIL: unexpected API call matching '$1' found in log" >&2; return 1; }; }
# ============================================================
# TEST 1: normal teardown of a live, pool-resident VM
# ============================================================
# Plant a real destroy call first so tests 3/4 can rely on its absence
# as a meaningful signal (not just "nothing happened yet").
echo "--- Test 1: live VM in pool → rc=0, VM destroyed"
(
    _setup
    VMID=500
    # Call 1: GET /config → 200, VM exists with correct name and token
    _resp 1 200 "$(_config_with_token 500)"
    # Call 2: GET /pools/<pool> → 200, VMID is a member
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 200, journal pid (journal capture)
    _resp 3 200 '{"data":{"pid":9876}}'
    # Call 4: GET /agent/exec-status → 200, exited (journal capture)
    _resp 4 200 '{"data":{"exited":1,"out-data":"","exitcode":0}}'
    # Call 5: POST /status/stop → 200, UPID
    _resp 5 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    # Call 6: GET /tasks/.../status → stopped/OK
    _resp 6 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    # Call 7: GET /status/current → stopped
    _resp 7 200 '{"data":{"status":"stopped"}}'
    # Call 8: DELETE → 200
    _resp 8 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:500:root@pam:"}'

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && _assert_log_has "PVAPI:DELETE:" \
    && _assert_log_has "PVAPI:GET:/pools/"
) && _pass "Test 1" || _fail "Test 1"

# ============================================================
# TEST 2: same VMID torn down a second time → rc=0 (idempotency)
#
# The VM is now gone (API 404). Guard 3 must run before the ownership guards,
# so the second call exits 0 rather than refusing. The original bug had the
# ownership guard first, which made a second teardown exit 1.
# ============================================================
echo "--- Test 2: second teardown of same VMID → rc=0 (idempotency)"
(
    _setup
    VMID=500
    # Call 1: GET /config → 404 (VM is gone)
    _resp 1 404 '{"errors":{"vmid":"not found"}}'

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 2" || _fail "Test 2"

# ============================================================
# TEST 3: VM present on host but not a member of the pool → rc≠0, no destroy
#
# This is the guard that replaced the ledger. A VM the API can see, correctly
# named, but outside ephemeral-ci is not ours and must not be destroyed.
# ============================================================
echo "--- Test 3: VM exists but is not in the pool → rc≠0, no destroy"
(
    _setup
    VMID=500
    # Call 1: GET /config → 200 (VM exists, correct name and token)
    _resp 1 200 "$(_config_with_token 500)"
    # Call 2: GET /pools/<pool> → 200, but this VMID is not a member
    _resp 2 200 "$(_pool_without)"

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero exit code, got 0" >&2; exit 1; }
    # Refusal must happen AT the pool guard, not incidentally downstream.
    # Asserting "no DELETE" alone is not enough: with the guard removed the
    # script still fails later once the mock runs out of planted responses,
    # so the test passed while proving nothing. No POST at all is the signal
    # that nothing past the guard ever ran.
    _assert_log_has "PVAPI:GET:/pools/" \
    && _assert_log_not_has "PVAPI:POST:" \
    && _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 3" || _fail "Test 3"

# ============================================================
# TEST 4: qm stop leaves VM running → script does not call destroy
#
# The old bug: qm stop ... || true discarded whether the VM was still running,
# so qm destroy was called on a running VM and was refused.
# ============================================================
echo "--- Test 4: stop leaves VM running → no destroy, reports it"
(
    _setup
    VMID=500
    # Call 1: GET /config → 200 (correct name and token)
    _resp 1 200 "$(_config_with_token 500)"
    # Call 2: GET /pools/<pool> → 200, VMID is a member
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 200, journal pid (journal capture)
    _resp 3 200 '{"data":{"pid":9876}}'
    # Call 4: GET /agent/exec-status → 200, exited (journal capture)
    _resp 4 200 '{"data":{"exited":1,"exitcode":0}}'
    # Call 5: POST /status/stop → 200
    _resp 5 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    # Call 6: GET /tasks/.../status → still running (triggers timeout immediately
    # since STOP_TIMEOUT=1 and STOP_POLL_INTERVAL=0)
    _resp 6 200 '{"data":{"status":"running"}}'
    # Call 7: force-stop POST → 200
    _resp 7 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    # Call 8: GET /status/current after force-stop → still running
    _resp 8 200 '{"data":{"status":"running"}}'

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero exit when VM still running" >&2; exit 1; }
    _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 4" || _fail "Test 4"

# ============================================================
# TEST 5: TEMPLATE_VMID → rc≠0, no API calls at all
# ============================================================
echo "--- Test 5: TEMPLATE_VMID → rc≠0, API never called"
(
    _setup
    VMID=101  # matches default TEMPLATE_VMID

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero exit for template VMID" >&2; exit 1; }
    _assert_eq "call count" "$(_call_count)" "0"
) && _pass "Test 5" || _fail "Test 5"

# ============================================================
# TEST 6: wrong VM name → rc≠0, destroy never called
#
# These two names are the other load-bearing VMs on this hypervisor.
# ============================================================
echo "--- Test 6a: VM named 'Agent-Swarm' → rc≠0, no destroy"
(
    _setup
    VMID=500
    # Guard 4 (name) runs before the token and pool checks, so a wrong name
    # rejects before we ever read the token.
    _resp 1 200 '{"data":{"name":"Agent-Swarm","cores":8,"description":"runner=test-runner vmtoken=aabbccdd11223344aabbccdd11223344"}}'

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero for wrong name" >&2; exit 1; }
    _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 6a" || _fail "Test 6a"

echo "--- Test 6b: VM named 'Prod-Services' → rc≠0, no destroy"
(
    _setup
    VMID=500
    _resp 1 200 '{"data":{"name":"Prod-Services","cores":8,"description":"runner=test-runner vmtoken=aabbccdd11223344aabbccdd11223344"}}'

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero for wrong name" >&2; exit 1; }
    _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 6b" || _fail "Test 6b"

# ============================================================
# TEST 7: API connection error → rc≠0, no destroy
# ============================================================
echo "--- Test 7: connection error (curl failure) → rc≠0"
(
    _setup
    VMID=500
    # Override pvapi.sh to simulate curl exit 7 (connection refused).
    cat > "$PVAPI_SH" <<'MOCK'
PVAPI_STATUS=""
PVAPI_BODY=""
pvapi() {
    local method="$1" path="$2" body="${3:-}"
    PVAPI_STATUS=""
    PVAPI_BODY=""
    printf 'PVAPI:%s:%s:%s\n' "$method" "$path" "$body" >> "${PVAPI_LOG}"
    return 7
}
MOCK

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero on connection error" >&2; exit 1; }
    _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 7" || _fail "Test 7"

# ============================================================
# TEST 8: non-numeric VMID → rc≠0, no API call
# ============================================================
echo "--- Test 8: non-numeric VMID → rc≠0"
(
    _setup
    rc=0
    _run_teardown "abc" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero for non-numeric VMID" >&2; exit 1; }
    _assert_eq "call count" "$(_call_count)" "0"
) && _pass "Test 8" || _fail "Test 8"

# ============================================================
# TEST 9: journal lines appear in teardown's output
#
# The agent returns real journal text. Confirm it appears in teardown's
# stderr — this is the signal that the content was streamed, not silently
# discarded. A test that only checks exit code cannot tell this from a no-op.
# ============================================================
echo "--- Test 9: journal output appears in teardown stderr"
(
    _setup
    VMID=500
    _resp 1 200 "$(_config_with_token 500)"
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 200, pid
    _resp 3 200 '{"data":{"pid":9876}}'
    # Call 4: GET /agent/exec-status → 200, exited with recognizable journal text
    _resp 4 200 '{"data":{"exited":1,"out-data":"Sep 18 shutdown: runner-killed-deliberately\n","exitcode":0}}'
    _resp 5 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    _resp 6 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    _resp 7 200 '{"data":{"status":"stopped"}}'
    _resp 8 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:500:root@pam:"}'

    rc=0
    output=$(_run_teardown $VMID 2>&1) || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && echo "$output" | grep -q "runner-killed-deliberately" \
        || { echo "  FAIL: journal text not found in output" >&2; exit 1; } \
    && _assert_log_has "PVAPI:DELETE:"
) && _pass "Test 9" || _fail "Test 9"

# ============================================================
# TEST 10: agent exec returns HTTP error → "unavailable", teardown completes
#
# When the guest-agent is not running (Proxmox returns non-200), journal
# capture prints "unavailable" and teardown still destroys the VM.
# ============================================================
echo "--- Test 10: agent exec HTTP error → unavailable, teardown still completes"
(
    _setup
    VMID=500
    _resp 1 200 "$(_config_with_token 500)"
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 500 (agent not available)
    _resp 3 500 '{"errors":"qemu agent is not running"}'
    # Stop/destroy calls follow immediately after journal gives up
    _resp 4 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    _resp 5 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    _resp 6 200 '{"data":{"status":"stopped"}}'
    _resp 7 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:500:root@pam:"}'

    rc=0
    output=$(_run_teardown $VMID 2>&1) || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && echo "$output" | grep -q "journal unavailable" \
        || { echo "  FAIL: 'journal unavailable' not found in output" >&2; exit 1; } \
    && _assert_log_has "PVAPI:DELETE:"
) && _pass "Test 10" || _fail "Test 10"

# ============================================================
# TEST 11: agent exec returns no pid → "unavailable", teardown completes
#
# Proxmox accepts the exec call (200) but returns no pid in the body.
# Journal capture says so and teardown continues.
# ============================================================
echo "--- Test 11: agent exec returns no pid → unavailable, teardown still completes"
(
    _setup
    VMID=500
    _resp 1 200 "$(_config_with_token 500)"
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 200 but body has no pid
    _resp 3 200 '{"data":{}}'
    # Stop/destroy calls follow immediately
    _resp 4 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    _resp 5 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    _resp 6 200 '{"data":{"status":"stopped"}}'
    _resp 7 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:500:root@pam:"}'

    rc=0
    output=$(_run_teardown $VMID 2>&1) || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && echo "$output" | grep -q "journal unavailable" \
        || { echo "  FAIL: 'journal unavailable' not found in output" >&2; exit 1; } \
    && _assert_log_has "PVAPI:DELETE:"
) && _pass "Test 11" || _fail "Test 11"

# ============================================================
# TEST 12: agent exec-status never says exited → timeout, teardown completes
#
# With JOURNAL_TIMEOUT=0 the deadline fires immediately after the first poll.
# Teardown must still destroy the VM and return 0.
# ============================================================
echo "--- Test 12: agent exec-status never exits → timeout, teardown still completes"
(
    _setup
    VMID=500
    _resp 1 200 "$(_config_with_token 500)"
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 200, pid returned
    _resp 3 200 '{"data":{"pid":9876}}'
    # Call 4: GET /agent/exec-status → 200, exited=0 (still running); deadline then fires
    _resp 4 200 '{"data":{"exited":0}}'
    # Stop/destroy calls follow immediately after timeout
    _resp 5 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    _resp 6 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    _resp 7 200 '{"data":{"status":"stopped"}}'
    _resp 8 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:500:root@pam:"}'

    rc=0
    JOURNAL_TIMEOUT=0 output=$(_run_teardown $VMID 2>&1) || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && echo "$output" | grep -q "journal unavailable" \
        || { echo "  FAIL: 'journal unavailable' not found in output" >&2; exit 1; } \
    && _assert_log_has "PVAPI:DELETE:"
) && _pass "Test 12" || _fail "Test 12"

# ============================================================
# TEST 13: token mismatch → rc≠0, no destroy (db-ogjn)
#
# This is the primary fix for the recycled-VMID vulnerability. The VM exists
# and has the right name (trivially, since name is derived from the VMID), but
# the caller holds a stale token from the previous provision of that VMID. The
# current VM's description carries a different token, so teardown must refuse.
# ============================================================
echo "--- Test 13: VM token in description does not match VM_TOKEN → rc≠0, no destroy"
(
    _setup
    VMID=500
    # Call 1: GET /config → 200; description has a DIFFERENT token than VM_TOKEN
    _resp 1 200 "$(_config_with_token 500 "deadbeef00000000deadbeef00000000")"

    rc=0
    VM_TOKEN="aabbccdd11223344aabbccdd11223344" _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero on token mismatch, got 0" >&2; exit 1; }
    _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 13" || _fail "Test 13"

# ============================================================
# TEST 14: no vmtoken in description → rc≠0, no destroy (db-ogjn)
#
# A VM provisioned before the token feature was deployed has no vmtoken= in its
# description. Teardown must refuse: allowing it would mean the recycling window
# is open for any VM that predates the fix.
# ============================================================
echo "--- Test 14: VM description has no vmtoken → rc≠0, no destroy"
(
    _setup
    VMID=500
    # Call 1: GET /config → 200; correct name, but no vmtoken in description
    _resp 1 200 '{"data":{"name":"gh-runner-500","cores":2,"description":"runner=test-runner"}}'

    rc=0
    _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero when description has no vmtoken, got 0" >&2; exit 1; }
    _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 14" || _fail "Test 14"

# ============================================================
# TEST 15: VM_TOKEN unset but VM carries a token → rc≠0, no destroy (db-rzdr)
#
# A new VM (provisioned with the token feature) carries vmtoken= in its
# description. If the caller didn't wire vm-token (e.g. unupgraded consumer
# workflow), VM_TOKEN arrives empty. Teardown must refuse: the caller cannot
# prove it participated in this specific provision and the recycling window
# is open. This is the "new-provision / old-teardown" case.
# ============================================================
echo "--- Test 15: VM_TOKEN unset, VM HAS token → rc≠0, no destroy (db-rzdr)"
(
    _setup
    VMID=500
    # Call 1: GET /config → 200; VM has a token but caller has none
    _resp 1 200 "$(_config_with_token 500)"

    rc=0
    VM_TOKEN="" _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero when VM has token but VM_TOKEN unset, got 0" >&2; exit 1; }
    _assert_log_not_has "PVAPI:DELETE:"
) && _pass "Test 15" || _fail "Test 15"

# ============================================================
# TEST 16: VM_TOKEN unset AND VM has no token → rc=0 (degraded path) (db-rzdr)
#
# A VM provisioned before the token feature was deployed has no vmtoken= in
# its description, and a consumer that has not yet wired vm-token passes an
# empty VM_TOKEN. Neither side has a token: this is the pre-feature case.
# Teardown must degrade to the name-only ownership check and succeed, so that
# the action remains a drop-in on @v1 for existing consumers.
# ============================================================
echo "--- Test 16: VM_TOKEN unset, VM has no token → rc=0, VM destroyed (degraded, db-rzdr)"
(
    _setup
    VMID=500
    # Call 1: GET /config → 200; correct name, NO vmtoken in description
    _resp 1 200 '{"data":{"name":"gh-runner-500","cores":2,"description":"runner=test-runner"}}'
    # Call 2: GET /pools/<pool> → 200, VMID is a member
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 200 (journal capture)
    _resp 3 200 '{"data":{"pid":9876}}'
    # Call 4: GET /agent/exec-status → 200, exited
    _resp 4 200 '{"data":{"exited":1,"out-data":"","exitcode":0}}'
    # Call 5: POST /status/stop → 200
    _resp 5 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:500:root@pam:"}'
    # Call 6: GET /tasks/.../status → stopped/OK
    _resp 6 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    # Call 7: GET /status/current → stopped
    _resp 7 200 '{"data":{"status":"stopped"}}'
    # Call 8: DELETE → 200
    _resp 8 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:500:root@pam:"}'

    rc=0
    VM_TOKEN="" _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && _assert_log_has "PVAPI:DELETE:"
) && _pass "Test 16" || _fail "Test 16"

# ============================================================
# TEST 17: explicit TEMPLATE_VMID=107; VMID=107 → still refused (db-b2gh)
#
# Guard 2 must use the configured TEMPLATE_VMID, not a hard-coded default.
# When the caller correctly wires template-vmid=107, tearing down the template
# itself must still be refused.
# ============================================================
echo "--- Test 17: TEMPLATE_VMID=107, VMID=107 → rc≠0, API never called"
(
    _setup
    VMID=107

    rc=0
    TEMPLATE_VMID=107 _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || { echo "  FAIL: expected non-zero when VMID == TEMPLATE_VMID=107" >&2; exit 1; }
    _assert_eq "call count" "$(_call_count)" "0"
) && _pass "Test 17" || _fail "Test 17"

# ============================================================
# TEST 18: explicit TEMPLATE_VMID=107; VMID=101 → NOT blocked, VM destroyed (db-b2gh)
#
# 101 was the old hard-coded default. With the correct template id configured
# as 107, a clone that lands on VMID 101 must not be blocked by Guard 2 —
# it should proceed through all guards and be destroyed normally.
# ============================================================
echo "--- Test 18: TEMPLATE_VMID=107, VMID=101 → rc=0, VM destroyed (old default no longer blocks)"
(
    _setup
    VMID=101
    # Call 1: GET /config → 200, VM exists with correct name and token
    _resp 1 200 "$(_config_with_token 101)"
    # Call 2: GET /pools/<pool> → 200, VMID is a member
    _resp 2 200 "$(_pool_with $VMID)"
    # Call 3: POST /agent/exec → 200, journal pid (journal capture)
    _resp 3 200 '{"data":{"pid":9876}}'
    # Call 4: GET /agent/exec-status → 200, exited
    _resp 4 200 '{"data":{"exited":1,"out-data":"","exitcode":0}}'
    # Call 5: POST /status/stop → 200, UPID
    _resp 5 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:101:root@pam:"}'
    # Call 6: GET /tasks/.../status → stopped/OK
    _resp 6 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    # Call 7: GET /status/current → stopped
    _resp 7 200 '{"data":{"status":"stopped"}}'
    # Call 8: DELETE → 200
    _resp 8 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:101:root@pam:"}'

    rc=0
    TEMPLATE_VMID=107 _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    _assert_rc "exit code" "$rc" 0 \
    && _assert_log_has "PVAPI:DELETE:"
) && _pass "Test 18" || _fail "Test 18"

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
