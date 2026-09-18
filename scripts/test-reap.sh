#!/usr/bin/env bash
# covers: scripts/reap.sh scripts/teardown.sh
#
# Regression suite for db-69kx: CRED_FILE sourcing and template-flag guard.
#
# Tests:
#   1. reap.sh skips a VM whose config carries template:1, even when its
#      VMID differs from TEMPLATE_VMID — the flag is a fact about the VM;
#      the id is configuration and can be wrong.
#   2. teardown.sh refuses a VM whose config carries template:1, even when
#      its VMID differs from TEMPLATE_VMID.
#   3. TEMPLATE_VMID set in CRED_FILE reaches reap.sh (sourcing works).
#   4. TEMPLATE_VMID set in CRED_FILE reaches teardown.sh (sourcing works).
#   5. The runner busy check queries the ORG endpoint, where provision.sh
#      actually registers runners, and a busy runner there protects the VM.
#   6. With GH_ORG unset the repository endpoint is still used, so 5 cannot be
#      satisfied by hardcoding the org URL.
#   7. The busy check looks up the RUNNER name recorded in the VM description,
#      not the VM's own name — the two are different strings and only the
#      former is registered with GitHub.
#
# Run: bash deploy/ephemeral-runner/test-reap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAP="$SCRIPT_DIR/reap.sh"
TEARDOWN="$SCRIPT_DIR/teardown.sh"

PASS=0
FAIL=0

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

_pass() { (( PASS++ )) || true; echo "  PASS: $1"; }
_fail() { (( FAIL++ )) || true; echo "  FAIL: $1"; }

# ---------------------------------------------------------------------------
# Teardown mock infrastructure (mirrors test-teardown.sh)
# ---------------------------------------------------------------------------

_td_setup() {
    TD_DIR=$(mktemp -d -p "$TMPDIR_ROOT")
    SNIPPETS_DIR="$TD_DIR/snippets"
    mkdir -p "$SNIPPETS_DIR"
    PVAPI_LOG="$TD_DIR/pvapi.log"
    PVAPI_CALL_FILE="$TD_DIR/call_count"
    PVAPI_RESPONSES="$TD_DIR/responses"
    mkdir -p "$PVAPI_RESPONSES"
    printf '0' > "$PVAPI_CALL_FILE"
    PVAPI_SH="$TD_DIR/pvapi.sh"
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

_td_resp() {
    local n="$1" status="$2" body="${3:-}"
    [ -z "$body" ] && body='{}'
    printf '%s\n%s\n' "$status" "$body" > "${PVAPI_RESPONSES}/${n}"
}

_td_log_has() {
    grep -q "$1" "$PVAPI_LOG" 2>/dev/null
}

# Run teardown.sh with the test fixtures, passing all env vars explicitly.
# Accepts additional KEY=VALUE pairs as arguments to inject.
_run_teardown() {
    local vmid="$1"; shift
    local extra_env=("$@")
    env \
    PVAPI_SH="$PVAPI_SH" \
    PVAPI_LOG="$PVAPI_LOG" \
    PVAPI_CALL_FILE="$PVAPI_CALL_FILE" \
    PVAPI_RESPONSES="$PVAPI_RESPONSES" \
    SNIPPETS_DIR="$SNIPPETS_DIR" \
    TEMPLATE_VMID="${TEMPLATE_VMID:-101}" \
    PVE_HOST=pve-test \
    PVE_NODE=pve \
    PVE_API_TOKEN_ID=test@pve!tok \
    PVE_API_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
    STOP_TIMEOUT=1 \
    STOP_POLL_INTERVAL=0 \
    FORCE_STOP_WAIT=0 \
    "${extra_env[@]}" \
    bash "$TEARDOWN" "$vmid"
}

# ---------------------------------------------------------------------------
# reap.sh mock infrastructure
#
# reap.sh's pvapi() calls curl directly. We stub curl on PATH using a
# URL-pattern dispatcher so tests can set up responses per-endpoint.
# ---------------------------------------------------------------------------

_reap_setup() {
    RD=$(mktemp -d -p "$TMPDIR_ROOT")
    REAP_SNIPPETS="$RD/snippets"
    mkdir -p "$REAP_SNIPPETS"
    BIN="$RD/bin"
    mkdir -p "$BIN"
    # Dummy CA cert file — exists so the curl stub allows the --cacert check.
    REAP_CA_CERT="$RD/ca.pem"
    printf 'DUMMY-CA-CERT\n' > "$REAP_CA_CERT"
    # Each stub file is placed at $BIN/.stub-<key>; curl reads them by URL pattern.
    printf '{"data":[]}\n' > "$BIN/.stub-qemu-list"
    printf '{"data":{"name":"gh-runner-500","meta":"ctime=1000000000"}}\n' > "$BIN/.stub-qemu-config"
    printf '{"data":"UPID:pve:1:1:1:stop:500:root@pam:"}\n' > "$BIN/.stub-stop"
    printf '{"data":{"status":"stopped"}}\n' > "$BIN/.stub-current"
    # pvapi.sh calls curl with -o FILE -w '%{http_code}': body to file, status
    # to stdout. The stub handles both conventions. It also checks --cacert FILE
    # to simulate the "file not found" failure curl returns (exit 77) when
    # PVE_CA_CERT_FILE points to a non-existent path.
    cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
url=""
output_file=""
write_out_fmt=""
cacert_file=""
resolve_arg=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    case "$arg" in
        https://*) url="$arg" ;;
        -o|--output) i=$(( i + 1 )); output_file="${args[$i]}" ;;
        -w|--write-out) i=$(( i + 1 )); write_out_fmt="${args[$i]}" ;;
        --cacert) i=$(( i + 1 )); cacert_file="${args[$i]}" ;;
        --resolve) i=$(( i + 1 )); resolve_arg="${args[$i]}" ;;
    esac
    i=$(( i + 1 ))
done
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$url" >> "$BIN_DIR/.urls"
if [ -n "$cacert_file" ]; then
    printf '%s\n' "$cacert_file" >> "$BIN_DIR/.cacerts"
    if [ ! -f "$cacert_file" ]; then
        printf 'curl: (77) error setting certificate file: %s\n' "$cacert_file" >&2
        exit 77
    fi
fi
if [ -n "$resolve_arg" ]; then
    printf '%s\n' "$resolve_arg" >> "$BIN_DIR/.resolves"
fi
_respond() {
    local body="$1" status="${2:-200}"
    if [ -n "$output_file" ]; then
        printf '%s' "$body" > "$output_file"
        [ "$write_out_fmt" = '%{http_code}' ] && printf '%s' "$status"
    else
        printf '%s\n' "$body"
    fi
}
# GitHub API first: these URLs have no /api2/json to strip, and falling through
# to the Proxmox matcher below would make every runner query an "unhandled path".
case "$url" in
    https://api.github.com/orgs/*/actions/runners*)
        _respond "$(cat "$BIN_DIR/.stub-gh-org-runners" 2>/dev/null || echo '{"runners":[]}')"
        exit 0 ;;
    https://api.github.com/repos/*/actions/runners*)
        _respond "$(cat "$BIN_DIR/.stub-gh-repo-runners" 2>/dev/null || echo '{"runners":[]}')"
        exit 0 ;;
esac
path="${url#https://}"
path="${path#*/api2/json}"
if [[ "$path" =~ /qemu/[0-9]+/config ]]; then
    _respond "$(cat "$BIN_DIR/.stub-qemu-config")"
elif [[ "$path" =~ /qemu/[0-9]+/status/current ]]; then
    _respond "$(cat "$BIN_DIR/.stub-current")"
elif [[ "$path" =~ /qemu/[0-9]+/status/stop ]]; then
    _respond "$(cat "$BIN_DIR/.stub-stop")"
elif [[ "$path" =~ purge ]]; then
    _respond '{"data":"UPID:pve:2:2:2:destroy:500:root@pam:"}'
elif [[ "$path" =~ /nodes/[^/]+/qemu$ ]]; then
    _respond "$(cat "$BIN_DIR/.stub-qemu-list")"
else
    printf 'curl stub: unhandled path: %s\n' "$path" >&2
    exit 1
fi
STUB
    chmod +x "$BIN/curl"
}

# Run reap.sh with the current test fixtures. Pass extra KEY=VALUE pairs as args.
_run_reap() {
    local extra_env=()
    # Collect leading KEY=VALUE args.
    while [[ $# -gt 0 && "$1" == *=* ]]; do
        extra_env+=("$1")
        shift
    done
    PATH="$BIN:$PATH" \
    SNIPPETS_DIR="$REAP_SNIPPETS" \
    TEMPLATE_VMID="${TEMPLATE_VMID:-101}" \
    PVE_NODE=pve \
    PVE_TOKEN_ID=test@pve!tok \
    PVE_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
    PVE_CA_CERT_FILE="$REAP_CA_CERT" \
    GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    GH_REPO="${GH_REPO:-}" \
    GH_ORG="${GH_ORG:-}" \
    "${extra_env[@]+"${extra_env[@]}"}" \
    bash "$REAP" "$@"
}

# ============================================================
# TEST 1: reap.sh skips a VM whose config carries template:1,
#         even when that VMID does not equal TEMPLATE_VMID.
#
# TEMPLATE_VMID=101 (the wrong default). The real template is VMID 9100
# and its Proxmox config carries template:1. The old code only checked
# whether VMID==TEMPLATE_VMID; since 9100!=101 it would proceed to destroy.
# The fix adds a template-flag check on the config before the age/busy path.
# ============================================================
echo "--- Test 1: reap.sh skips VM with template:1 (VMID != TEMPLATE_VMID)"
(
    _reap_setup
    # VM list: one VM at 9100, carrying template:1 (as Proxmox reports it).
    printf '{"data":[{"vmid":9100,"name":"gh-runner-9100","template":1}]}\n' > "$BIN/.stub-qemu-list"
    # Config: template:1, old ctime — would be reaped on age alone without the flag check.
    printf '{"data":{"name":"gh-runner-9100","template":1,"meta":"creation-qemu=9.0.0,ctime=1000000000"}}\n' \
        > "$BIN/.stub-qemu-config"
    TEMPLATE_VMID=101  # default/wrong value

    output=$(TEMPLATE_VMID=101 _run_reap --dry-run 2>&1 || true)

    if printf '%s\n' "$output" | grep -q 'would destroy.*9100'; then
        echo "  expected fail: reap.sh would destroy VM 9100 (template:1 flag not checked)" >&2
        exit 1
    fi
    # After fix, reap.sh must log that 9100 is a template or was skipped as one.
    printf '%s\n' "$output" | grep -qiE 'template.*9100|9100.*template|skipping.*9100' || {
        echo "  expected fail: reap.sh did not log a template-skip for VMID 9100" >&2
        exit 1
    }
) && _pass "Test 1: reap.sh skips VM with template:1" || _fail "Test 1: reap.sh skips VM with template:1"

# ============================================================
# TEST 2: teardown.sh refuses a VM whose config carries template:1,
#         even when its VMID differs from TEMPLATE_VMID.
#
# All other guards are satisfied (name matches, stop succeeds)
# so the only thing preventing destruction should be template:1.
# The test must red with the current code (no template-flag guard) and
# green after the fix.
# ============================================================
echo "--- Test 2: teardown.sh refuses VM with template:1 (VMID != TEMPLATE_VMID)"
(
    _td_setup
    VMID=9100
    TEMPLATE_VMID=101

    # Call 1: GET /config → 200, correct name, but template:1.
    _td_resp 1 200 '{"data":{"name":"gh-runner-9100","template":1}}'
    # Calls 2-5 are reached only if the template guard does not fire.
    _td_resp 2 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:9100:root@pam:"}'
    _td_resp 3 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    _td_resp 4 200 '{"data":{"status":"stopped"}}'
    _td_resp 5 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:9100:root@pam:"}'

    rc=0
    TEMPLATE_VMID=101 _run_teardown $VMID >/dev/null 2>&1 || rc=$?

    [ "$rc" -ne 0 ] || {
        echo "  expected fail: teardown.sh returned 0 for a VM with template:1" >&2
        exit 1
    }
    ! _td_log_has "PVAPI:DELETE:" || {
        echo "  expected fail: teardown.sh issued a DELETE for a VM with template:1" >&2
        exit 1
    }
) && _pass "Test 2: teardown.sh refuses VM with template:1" || _fail "Test 2: teardown.sh refuses VM with template:1"

# ============================================================
# TEST 3: TEMPLATE_VMID set in CRED_FILE reaches reap.sh.
#
# The old bug: reap.sh never sourced CRED_FILE, so TEMPLATE_VMID=9100 in
# /etc/gh-ephemeral-runner/token was invisible — the variable kept its
# default 101 and the real template at VMID 9100 was treated as a clone.
# ============================================================
echo "--- Test 3: TEMPLATE_VMID from CRED_FILE reaches reap.sh"
(
    _reap_setup
    CRED_FILE="$RD/token"
    printf 'TEMPLATE_VMID=9100\n' > "$CRED_FILE"

    # A single VM at 9100 with an old ctime — would be reaped without CRED_FILE.
    printf '{"data":[{"vmid":9100,"name":"gh-runner-9100"}]}\n' > "$BIN/.stub-qemu-list"
    printf '{"data":{"name":"gh-runner-9100","meta":"creation-qemu=9.0.0,ctime=1000000000"}}\n' \
        > "$BIN/.stub-qemu-config"

    # Do NOT set TEMPLATE_VMID — it must come from CRED_FILE only.
    output=$(
        PATH="$BIN:$PATH" \
        SNIPPETS_DIR="$REAP_SNIPPETS" \
        CRED_FILE="$CRED_FILE" \
        PVE_NODE=pve \
        PVE_TOKEN_ID=test@pve!tok \
        PVE_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
        PVE_CA_CERT_FILE="$REAP_CA_CERT" \
        GITHUB_TOKEN="" \
        GH_REPO="" \
        bash "$REAP" --dry-run 2>&1 || true
    )

    if printf '%s\n' "$output" | grep -q 'would destroy.*9100'; then
        echo "  expected fail: TEMPLATE_VMID from CRED_FILE did not reach reap.sh — would destroy 9100" >&2
        exit 1
    fi
    # After fix, reap.sh must log "skipping template VMID 9100".
    printf '%s\n' "$output" | grep -qiE 'skipping template.*9100|template.*9100' || {
        echo "  expected fail: reap.sh did not log a template-skip for 9100 — CRED_FILE not sourced" >&2
        exit 1
    }
) && _pass "Test 3: TEMPLATE_VMID from CRED_FILE reaches reap.sh" || _fail "Test 3: TEMPLATE_VMID from CRED_FILE reaches reap.sh"

# ============================================================
# TEST 4: TEMPLATE_VMID set in CRED_FILE reaches teardown.sh.
#
# Without sourcing CRED_FILE, teardown.sh uses TEMPLATE_VMID=101.
# VMID 9100 then clears guard 2 (9100 != 101). After the fix, teardown.sh
# sources CRED_FILE, reads TEMPLATE_VMID=9100, and guard 2 fires before
# any API call is made.
# ============================================================
echo "--- Test 4: TEMPLATE_VMID from CRED_FILE reaches teardown.sh"
(
    _td_setup
    VMID=9100
    CRED_FILE="$TD_DIR/token"
    printf 'TEMPLATE_VMID=9100\n' > "$CRED_FILE"

    # Responses for the full stop/destroy path — reached only without guard 2.
    _td_resp 1 200 '{"data":{"name":"gh-runner-9100"}}'
    _td_resp 2 200 '{"data":"UPID:pve:00001234:abcdef01:67890abc:stopvm:9100:root@pam:"}'
    _td_resp 3 200 '{"data":{"status":"stopped","exitstatus":"OK"}}'
    _td_resp 4 200 '{"data":{"status":"stopped"}}'
    _td_resp 5 200 '{"data":"UPID:pve:00001235:abcdef02:67890abd:qmdestroy:9100:root@pam:"}'

    rc=0
    env \
    PVAPI_SH="$PVAPI_SH" \
    PVAPI_LOG="$PVAPI_LOG" \
    PVAPI_CALL_FILE="$PVAPI_CALL_FILE" \
    PVAPI_RESPONSES="$PVAPI_RESPONSES" \
    SNIPPETS_DIR="$SNIPPETS_DIR" \
    CRED_FILE="$CRED_FILE" \
    PVE_HOST=pve-test \
    PVE_NODE=pve \
    PVE_API_TOKEN_ID=test@pve!tok \
    PVE_API_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
    STOP_TIMEOUT=1 \
    STOP_POLL_INTERVAL=0 \
    FORCE_STOP_WAIT=0 \
    bash "$TEARDOWN" $VMID >/dev/null 2>&1 || rc=$?

    # teardown.sh must refuse because CRED_FILE says 9100 is the template.
    [ "$rc" -ne 0 ] || {
        echo "  expected fail: teardown.sh returned 0 — CRED_FILE not sourced, guard 2 did not fire" >&2
        exit 1
    }
    ! _td_log_has "PVAPI:DELETE:" || {
        echo "  expected fail: teardown.sh issued a DELETE — guard 2 did not block it" >&2
        exit 1
    }
) && _pass "Test 4: TEMPLATE_VMID from CRED_FILE reaches teardown.sh" || _fail "Test 4: TEMPLATE_VMID from CRED_FILE reaches teardown.sh"

# ============================================================
# TEST 5: the busy check asks the endpoint the runner is REGISTERED with.
#
# provision.sh registers runners at the ORGANIZATION level (org registration
# token plus a restricted runner group), so a live runner appears in
# /orgs/{org}/actions/runners and NOT in /repos/{owner}/{repo}/actions/runners.
#
# reap.sh queried the repository endpoint unconditionally. Against an
# org-registered runner that returns an empty list, "absent" was read as "idle",
# and every VM passed the busy check no matter what it was doing — leaving age
# as the only guard while the check still reported a clean result.
#
# THE SECOND ASSERTION IS THE POSITIVE CONTROL. "The VM survived" is not
# evidence the check worked: a VM also survives when the check errors out, or
# when the stub returns nothing at all. The org URL must actually have been
# requested.
# ============================================================
echo "--- Test 5: busy check queries the ORG runner endpoint"
(
    _reap_setup
    # One old VM, reapable on age alone.
    # The VM is named gh-runner-<vmid> (teardown.sh's guard requires it) and
    # carries the RUNNER's name in its description, which is the correlation
    # the busy check needs.
    printf '{"data":[{"vmid":500,"name":"gh-runner-500"}]}\n' > "$BIN/.stub-qemu-list"
    printf '{"data":{"name":"gh-runner-500","description":"runner=ci-pokedumpster-99-1","meta":"creation-qemu=11.0.0,ctime=1000000000"}}\n' \
        > "$BIN/.stub-qemu-config"
    # The runner is BUSY, and says so only at the org endpoint. The repo endpoint
    # answers the way it really does for an org-registered runner: successfully,
    # with an empty list.
    printf '{"runners":[{"name":"ci-pokedumpster-99-1","busy":true}]}\n' > "$BIN/.stub-gh-org-runners"
    printf '{"runners":[]}\n' > "$BIN/.stub-gh-repo-runners"

    output=$(GITHUB_TOKEN=tok GH_ORG=DeckDumpster GH_REPO=DeckDumpster/pokedumpster \
             _run_reap --dry-run 2>&1 || true)

    if printf '%s\n' "$output" | grep -q 'would destroy.*500'; then
        echo "  expected fail: reap.sh would destroy VM 500 while its runner is busy" >&2
        exit 1
    fi
    if ! grep -q 'https://api.github.com/orgs/DeckDumpster/actions/runners' "$BIN/.urls"; then
        echo "  expected fail: reap.sh never queried the org runner endpoint" >&2
        echo "  URLs requested:" >&2; sed 's/^/    /' "$BIN/.urls" >&2
        exit 1
    fi
) && _pass "Test 5: busy check queries the ORG runner endpoint" \
  || _fail "Test 5: busy check queries the ORG runner endpoint"

# ============================================================
# TEST 6: with GH_ORG unset, the repository endpoint is still used.
#
# A runner registered against a single repository remains a supported shape,
# and this is what stops Test 5 from being satisfied by hardcoding the org URL.
# ============================================================
echo "--- Test 6: GH_ORG unset falls back to the repo runner endpoint"
(
    _reap_setup
    printf '{"data":[{"vmid":500,"name":"gh-runner-500"}]}\n' > "$BIN/.stub-qemu-list"
    printf '{"data":{"name":"gh-runner-500","description":"runner=ci-legacy-1","meta":"creation-qemu=11.0.0,ctime=1000000000"}}\n' \
        > "$BIN/.stub-qemu-config"
    printf '{"runners":[{"name":"ci-legacy-1","busy":true}]}\n' > "$BIN/.stub-gh-repo-runners"

    output=$(GITHUB_TOKEN=tok GH_ORG='' GH_REPO=DeckDumpster/deckdumpster \
             _run_reap --dry-run 2>&1 || true)

    if printf '%s\n' "$output" | grep -q 'would destroy.*500'; then
        echo "  expected fail: reap.sh would destroy VM 500 while its runner is busy" >&2
        exit 1
    fi
    if ! grep -q 'https://api.github.com/repos/DeckDumpster/deckdumpster/actions/runners' "$BIN/.urls"; then
        echo "  expected fail: reap.sh never queried the repo runner endpoint" >&2
        exit 1
    fi
) && _pass "Test 6: GH_ORG unset falls back to the repo runner endpoint" \
  || _fail "Test 6: GH_ORG unset falls back to the repo runner endpoint"

# ============================================================
# TEST 7: the busy check looks up the RUNNER name, not the VM name.
#
# The VM is gh-runner-500; the runner registered with GitHub is ci-run-7. The
# org runner list holds a BUSY runner under each name. If the check asks about
# the VM name it "works" for the wrong reason, so the discriminating fixture is
# the one below: only `ci-run-7` is busy, and `gh-runner-500` is present and
# IDLE. A check that asks the wrong question destroys a live VM here.
# ============================================================
echo "--- Test 7: busy check uses the runner name from the VM description"
(
    _reap_setup
    printf '{"data":[{"vmid":500,"name":"gh-runner-500"}]}\n' > "$BIN/.stub-qemu-list"
    printf '{"data":{"name":"gh-runner-500","description":"runner=ci-run-7","meta":"creation-qemu=11.0.0,ctime=1000000000"}}\n' \
        > "$BIN/.stub-qemu-config"
    printf '{"runners":[{"name":"gh-runner-500","busy":false},{"name":"ci-run-7","busy":true}]}\n' \
        > "$BIN/.stub-gh-org-runners"

    output=$(GITHUB_TOKEN=tok GH_ORG=DeckDumpster _run_reap --dry-run 2>&1 || true)

    if printf '%s\n' "$output" | grep -q 'would destroy.*500'; then
        echo "  expected fail: reap.sh would destroy VM 500 while runner ci-run-7 is busy" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -q 'ci-run-7' || {
        echo "  expected fail: reap.sh never named the runner from the description" >&2
        exit 1
    }
) && _pass "Test 7: busy check uses the runner name from the VM description" \
  || _fail "Test 7: busy check uses the runner name from the VM description"

# ============================================================
# TEST 8: reap.sh fails loudly when PVE_CA_CERT_FILE is missing.
#
# Without a CA cert file the Proxmox API cannot be reached with a verified
# connection. pvapi.sh passes --cacert to curl; curl exits 77 when the cert
# file does not exist. reap.sh must exit non-zero — never silently proceed
# with an unverified connection.
#
# POSITIVE CONTROL: the same run with a valid cert file succeeds (reaps
# nothing because the VM list is empty) to confirm it is the missing cert,
# not something else, that caused the failure.
# ============================================================
echo "--- Test 8: reap.sh fails loudly when CA cert file is missing"
(
    _reap_setup
    # Empty VM list so any real work is absent — only the cert check matters.
    printf '{"data":[]}\n' > "$BIN/.stub-qemu-list"

    # Without PVE_CA_CERT_FILE: pvapi.sh defaults to /etc/pve/pve-root-ca.pem,
    # which does not exist here. The curl stub exits 77 and reap.sh must fail.
    rc=0
    PATH="$BIN:$PATH" \
    SNIPPETS_DIR="$REAP_SNIPPETS" \
    PVE_NODE=pve \
    PVE_TOKEN_ID=test@pve!tok \
    PVE_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
    GITHUB_TOKEN="" GH_REPO="" GH_ORG="" \
    bash "$REAP" --dry-run 2>/dev/null || rc=$?

    [ "$rc" -ne 0 ] || {
        echo "  expected fail: reap.sh returned 0 without a CA cert file" >&2
        exit 1
    }

    # Positive control: with the CA cert file present, the run succeeds.
    rc=0
    _run_reap --dry-run 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || {
        echo "  expected fail: reap.sh returned $rc with a valid CA cert file" >&2
        exit 1
    }
) && _pass "Test 8: reap.sh fails loudly when CA cert file is missing" \
  || _fail "Test 8: reap.sh fails loudly when CA cert file is missing"

# ============================================================
# TEST 9: reap.sh passes --cacert with the supplied CA cert file.
#
# Verifies that the CA cert path actually reaches curl — not just that the
# run succeeds. The curl stub logs every --cacert argument; this test reads
# that log and confirms the expected path was passed on every Proxmox call.
# ============================================================
echo "--- Test 9: reap.sh passes --cacert with the supplied CA cert file"
(
    _reap_setup
    printf '{"data":[]}\n' > "$BIN/.stub-qemu-list"

    _run_reap --dry-run 2>/dev/null || true

    # The stub wrote every --cacert path to .cacerts (one per curl call).
    if [ ! -s "$BIN/.cacerts" ]; then
        echo "  expected fail: curl stub .cacerts log is empty — --cacert was not passed" >&2
        exit 1
    fi
    # Every entry must be the cert file we provided.
    while IFS= read -r line; do
        [ "$line" = "$REAP_CA_CERT" ] || {
            echo "  expected fail: --cacert path '$line' != expected '$REAP_CA_CERT'" >&2
            exit 1
        }
    done < "$BIN/.cacerts"
) && _pass "Test 9: reap.sh passes --cacert with the supplied CA cert file" \
  || _fail "Test 9: reap.sh passes --cacert with the supplied CA cert file"

# ============================================================
# TEST 10: PVE_API_HOSTNAME causes URL to use the hostname and --resolve
#          to pin it to PVE_API_HOST (the tailnet IP).
#
# The reaper workflow sets PVE_API_HOST to a tailnet IP. The Proxmox TLS
# certificate carries no SAN for that IP — it is issued for the node name.
# Supplying the correct CA only fixes chain trust; the name mismatch still
# fails validation.
#
# The fix: pvapi.sh reads PVE_API_HOSTNAME and, when set, uses it as the URL
# host and adds --resolve <hostname>:<port>:<ip> so curl connects to the IP
# but validates against the certificate's name.
#
# DISCRIMINATING ASSERTIONS:
#   a. The Proxmox URL must use the hostname, not the IP.
#   b. Every curl call to the Proxmox API must carry a --resolve argument
#      in the form <hostname>:<port>:<ip>.
# ============================================================
echo "--- Test 10: PVE_API_HOSTNAME routes URL through hostname with --resolve"
(
    _reap_setup
    printf '{"data":[]}\n' > "$BIN/.stub-qemu-list"

    FAKE_IP="100.64.0.1"
    FAKE_HOST="pve"
    FAKE_PORT="8006"

    PATH="$BIN:$PATH" \
    SNIPPETS_DIR="$REAP_SNIPPETS" \
    TEMPLATE_VMID=101 \
    PVE_NODE=pve \
    PVE_TOKEN_ID=test@pve!tok \
    PVE_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
    PVE_CA_CERT_FILE="$REAP_CA_CERT" \
    GITHUB_TOKEN="" \
    GH_REPO="" \
    GH_ORG="" \
    PVE_API_HOST="$FAKE_IP" \
    PVE_API_HOSTNAME="$FAKE_HOST" \
    PVE_API_PORT="$FAKE_PORT" \
    bash "$REAP" --dry-run 2>/dev/null || true

    # a. The URL must use the hostname, not the IP.
    if grep -qF "https://${FAKE_IP}:" "$BIN/.urls" 2>/dev/null; then
        echo "  expected fail: curl URL contains the IP '$FAKE_IP' — hostname not used" >&2
        echo "  URLs requested:" >&2; cat "$BIN/.urls" | sed 's/^/    /' >&2
        exit 1
    fi
    if ! grep -qF "https://${FAKE_HOST}:" "$BIN/.urls" 2>/dev/null; then
        echo "  expected fail: curl URL does not contain the hostname '$FAKE_HOST'" >&2
        echo "  URLs logged (may be empty if curl was not called):" >&2
        cat "$BIN/.urls" 2>/dev/null | sed 's/^/    /' >&2 || echo "    (no .urls file)" >&2
        exit 1
    fi

    # b. Every Proxmox call must carry --resolve <hostname>:<port>:<ip>.
    EXPECTED_RESOLVE="${FAKE_HOST}:${FAKE_PORT}:${FAKE_IP}"
    if [ ! -s "$BIN/.resolves" ]; then
        echo "  expected fail: no --resolve argument was passed to curl" >&2
        exit 1
    fi
    while IFS= read -r line; do
        [ "$line" = "$EXPECTED_RESOLVE" ] || {
            echo "  expected fail: --resolve '$line' != expected '$EXPECTED_RESOLVE'" >&2
            exit 1
        }
    done < "$BIN/.resolves"
) && _pass "Test 10: PVE_API_HOSTNAME routes URL through hostname with --resolve" \
  || _fail "Test 10: PVE_API_HOSTNAME routes URL through hostname with --resolve"

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
