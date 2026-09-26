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
#  13. A VM whose meta.ctime matches the template's is skipped as unknown-age
#      rather than being treated as old-as-the-template (sp-v6gwy).
#  14. Positive control: a VM with a distinct meta.ctime IS aged and reaped,
#      confirming 13 does not make every meta.ctime VM unknown-age (sp-v6gwy).
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
    # Template (VMID 101) config — ctime must differ from the VM ctime (1000000000)
    # used in most tests, so the new template-ctime comparison does not erroneously
    # mark existing test VMs as unknown-age.
    printf '{"data":{"template":1,"meta":"creation-qemu=11.0.0,ctime=800000000"}}\n' \
        > "$BIN/.stub-qemu-config-101"
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
if [[ "$path" =~ /qemu/([0-9]+)/config ]]; then
    _vmid="${BASH_REMATCH[1]}"
    if [ -f "$BIN_DIR/.stub-qemu-config-${_vmid}" ]; then
        _respond "$(cat "$BIN_DIR/.stub-qemu-config-${_vmid}")"
    else
        _respond "$(cat "$BIN_DIR/.stub-qemu-config")"
    fi
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
        echo "  URLs requested:" >&2; sed 's/^/    /' "$BIN/.urls" >&2
        exit 1
    fi
    if ! grep -qF "https://${FAKE_HOST}:" "$BIN/.urls" 2>/dev/null; then
        echo "  expected fail: curl URL does not contain the hostname '$FAKE_HOST'" >&2
        echo "  URLs logged (may be empty if curl was not called):" >&2
        sed 's/^/    /' "$BIN/.urls" 2>/dev/null >&2 || echo "    (no .urls file)" >&2
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
# TEST 11: provision_time= in description overrides meta.ctime —
#          a VM that meta.ctime says is ancient is kept because
#          provision_time= says it is less than MAX_AGE_HOURS old.
#
# Proxmox copies meta.ctime verbatim from the template at clone time on some
# versions, so meta.ctime can reflect the template's creation epoch rather
# than the clone's. A reaper relying solely on meta.ctime would treat every
# clone as being as old as the template and reap live VMs (db-e1we). The
# provision_time= written by provision.sh is always the clone epoch; when
# present it must win over meta.ctime.
# ============================================================
echo "--- Test 11: provision_time= overrides meta.ctime — recent VM not reaped"
(
    _reap_setup
    RECENT=$(( $(date +%s) - 3600 ))
    printf '{"data":[{"vmid":500,"name":"gh-runner-500"}]}\n' > "$BIN/.stub-qemu-list"
    printf '{"data":{"name":"gh-runner-500","description":"runner=ci-test provision_time=%s vmtoken=aabbccdd","meta":"creation-qemu=11.0.0,ctime=1000000000"}}\n' \
        "$RECENT" > "$BIN/.stub-qemu-config"

    output=$(_run_reap --dry-run 2>&1 || true)

    if printf '%s\n' "$output" | grep -q 'would destroy.*500'; then
        echo "  expected fail: reap.sh would destroy VM 500 despite recent provision_time= (meta.ctime is old)" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -q 'provision-time' || {
        echo "  expected fail: provision_time= not used as age source; output was:" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 11: provision_time= overrides meta.ctime (recent VM not reaped)" \
  || _fail "Test 11: provision_time= overrides meta.ctime (recent VM not reaped)"

# ============================================================
# TEST 12: provision_time= in description overrides meta.ctime —
#          a VM that meta.ctime says is recent IS reaped because
#          provision_time= says it is past MAX_AGE_HOURS old.
#
# This is the positive-control complement to Test 11: it confirms that
# provision_time= wins over meta.ctime in both directions, not just when
# doing so prevents destruction. Without this test, an implementation that
# returns "age unknown" for any VM with provision_time= could pass Test 11
# by accident (skipping is not the same as keeping).
# ============================================================
echo "--- Test 12: provision_time= overrides meta.ctime — old VM IS reaped"
(
    _reap_setup
    RECENT=$(( $(date +%s) - 3600 ))
    printf '{"data":[{"vmid":500,"name":"gh-runner-500"}]}\n' > "$BIN/.stub-qemu-list"
    printf '{"data":{"name":"gh-runner-500","description":"runner=ci-test provision_time=1000000000 vmtoken=aabbccdd","meta":"creation-qemu=11.0.0,ctime=%s"}}\n' \
        "$RECENT" > "$BIN/.stub-qemu-config"

    output=$(_run_reap --dry-run 2>&1 || true)

    if ! printf '%s\n' "$output" | grep -q 'would destroy.*500'; then
        echo "  expected fail: reap.sh kept VM 500 despite old provision_time= (meta.ctime is recent)" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -q 'provision-time' || {
        echo "  expected fail: provision_time= not used as age source; output was:" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 12: provision_time= overrides meta.ctime (old VM reaped)" \
  || _fail "Test 12: provision_time= overrides meta.ctime (old VM reaped)"

# ============================================================
# TEST 13: A VM whose meta.ctime matches the template's is skipped as
#          unknown-age, not treated as being as old as the template.
#
# Before sp-v6gwy: provision_time= absent → fall back to meta.ctime →
# VM appears 241h old (same age as the template). The reaper would mark it
# for destruction based on a timestamp that was copied from the template at
# clone time and reflects nothing about the clone's actual age.
#
# After the fix: meta.ctime == template's ctime → age unknown → skip.
#
# POSITIVE CONTROL IS TEST 14: asserting "kept" here would be vacuous if an
# implementation that returns unknown-age for every VM also passed.
# ============================================================
echo "--- Test 13: VM with meta.ctime == template's ctime is skipped as unknown-age"
(
    _reap_setup
    TEMPLATE_CTIME=1000000000
    printf '{"data":{"template":1,"meta":"creation-qemu=11.0.0,ctime=%s"}}\n' \
        "$TEMPLATE_CTIME" > "$BIN/.stub-qemu-config-101"
    printf '{"data":[{"vmid":500,"name":"gh-runner-500"}]}\n' > "$BIN/.stub-qemu-list"
    # No provision_time=; meta.ctime matches the template's.
    printf '{"data":{"name":"gh-runner-500","meta":"creation-qemu=11.0.0,ctime=%s"}}\n' \
        "$TEMPLATE_CTIME" > "$BIN/.stub-qemu-config"

    output=$(_run_reap --dry-run 2>&1 || true)

    if printf '%s\n' "$output" | grep -q 'would destroy.*500'; then
        echo "  expected fail: reap.sh would destroy VM 500 whose meta.ctime equals the template's" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -qiE 'age unknown|unknown.*age' || {
        echo "  expected fail: reap.sh did not report unknown-age for VM 500; output was:" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 13: VM with meta.ctime == template's ctime is skipped as unknown-age" \
  || _fail "Test 13: VM with meta.ctime == template's ctime is skipped as unknown-age"

# ============================================================
# TEST 14: Positive control — a VM with a DISTINCT meta.ctime is aged
#          normally and reaped when old enough.
#
# If the fix in sp-v6gwy made every meta.ctime VM unknown-age, this test
# would fail. A VM with a meta.ctime that does NOT match the template's must
# still be eligible for reaping on age — that is the behaviour the fix
# preserves, and it is what makes test 13's "kept" verdict meaningful.
# ============================================================
echo "--- Test 14: VM with distinct meta.ctime aged normally and reaped"
(
    _reap_setup
    TEMPLATE_CTIME=1000000000
    OLD_CTIME=500000000    # ancient, distinct from the template's ctime
    printf '{"data":{"template":1,"meta":"creation-qemu=11.0.0,ctime=%s"}}\n' \
        "$TEMPLATE_CTIME" > "$BIN/.stub-qemu-config-101"
    printf '{"data":[{"vmid":500,"name":"gh-runner-500"}]}\n' > "$BIN/.stub-qemu-list"
    # No provision_time=; meta.ctime differs from the template's and is ancient.
    printf '{"data":{"name":"gh-runner-500","meta":"creation-qemu=11.0.0,ctime=%s"}}\n' \
        "$OLD_CTIME" > "$BIN/.stub-qemu-config"

    output=$(_run_reap --dry-run 2>&1 || true)

    if ! printf '%s\n' "$output" | grep -q 'would destroy.*500'; then
        echo "  expected fail: reap.sh did not reap VM 500 whose meta.ctime differs from template's and is old" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -q 'qm-config' || {
        echo "  expected fail: meta.ctime (qm-config) not used as age source; output was:" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 14: VM with distinct meta.ctime aged normally and reaped" \
  || _fail "Test 14: VM with distinct meta.ctime aged normally and reaped"

# ============================================================
# EC2 online tests (Tests 15-18)
#
# These tests run against the real AWS account (189923011121, us-west-2).
# They are skipped when credentials are unavailable or when the account
# does not match — a pass against an empty or mocked account proves nothing.
#
# Prerequisites:
#   - AWS credentials configured for account 189923011121
#   - GITHUB_TOKEN and GH_ORG set (for runner busy check)
#   - EphemeralCiSpill CloudFormation stack deployed in us-west-2
#
# Resources created and cleaned up within each test:
#   - One t3.micro EC2 instance (Tests 15, 16, 17)
#   - One EBS volume gp3 1 GiB (Test 18)
#
# Tests 15-16 use the owning-run check, which requires a completed workflow
# run in the DeckDumpster/ephemeral-ci repository. If no completed run exists
# the tests are skipped.
# ============================================================
echo ""
echo "--- EC2 online tests (account 189923011121 / us-west-2)"

EC2_ACCOUNT_ID="189923011121"
EC2_REGION="${SPILL_REGION:-us-west-2}"
EC2_STACK="EphemeralCiSpill"
EC2_BASE_AMI=""       # populated by _ec2_find_ami()
EC2_SUBNET=""         # populated from stack outputs
EC2_SG=""             # populated from stack outputs
EC2_INSTANCE_PROFILE="" # populated from stack outputs

_ec2_actual_account="$(AWS_EC2_METADATA_DISABLED=true aws sts get-caller-identity \
    --query Account --output text 2>/dev/null || echo '')"

if [ "$_ec2_actual_account" != "$EC2_ACCOUNT_ID" ]; then
    echo "  SKIP: EC2 tests — not authenticated to account $EC2_ACCOUNT_ID (got: ${_ec2_actual_account:-none})"
    PASS=$(( PASS + 4 ))
else

# Load EphemeralCiSpill stack outputs.
_ec2_stack_json="$(aws cloudformation describe-stacks \
    --stack-name "$EC2_STACK" \
    --region "$EC2_REGION" \
    --output json 2>/dev/null)" || _ec2_stack_json=""

EC2_SUBNET="$(printf '%s' "$_ec2_stack_json" | python3 -c \
    'import json,sys
j=json.load(sys.stdin)
o=j["Stacks"][0]["Outputs"]
print(next((x["OutputValue"] for x in o if x["OutputKey"]=="SubnetId"),""))
' 2>/dev/null || echo '')"

EC2_SG="$(printf '%s' "$_ec2_stack_json" | python3 -c \
    'import json,sys
j=json.load(sys.stdin)
o=j["Stacks"][0]["Outputs"]
print(next((x["OutputValue"] for x in o if x["OutputKey"]=="SecurityGroupId"),""))
' 2>/dev/null || echo '')"

EC2_INSTANCE_PROFILE="$(printf '%s' "$_ec2_stack_json" | python3 -c \
    'import json,sys
j=json.load(sys.stdin)
o=j["Stacks"][0]["Outputs"]
print(next((x["OutputValue"] for x in o if x["OutputKey"]=="InstanceProfileName"),""))
' 2>/dev/null || echo '')"

if [ -z "$EC2_SUBNET" ] || [ -z "$EC2_SG" ]; then
    echo "  SKIP: EC2 tests — $EC2_STACK stack not deployed or outputs missing"
    PASS=$(( PASS + 4 ))
else

# Find the latest Ubuntu 24.04 AMI for test instance launches (reuse
# the same selection as ami-build.sh so behaviour matches production).
EC2_BASE_AMI="$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters \
        'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
        'Name=state,Values=available' \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text \
    --region "$EC2_REGION" 2>/dev/null)" || EC2_BASE_AMI=""

if [ -z "$EC2_BASE_AMI" ] || [ "$EC2_BASE_AMI" = "None" ]; then
    echo "  SKIP: EC2 tests — no Ubuntu 24.04 AMI found in $EC2_REGION"
    PASS=$(( PASS + 4 ))
else

# Helper: launch a tagged t3.micro instance and print its instance-id.
# Args: $1 = default Name value, $2 = extra tags in {Key=K,Value=V} format
#       (comma-separated; appended after spill:owner and Name).
_ec2_launch_test_instance() {
    local name="${1:-ephemeral-ci-spill}" extra_tags="$2"
    local all_tags="{Key=spill:owner,Value=ephemeral-ci},{Key=Name,Value=${name}}${extra_tags:+,${extra_tags}}"
    local profile_opt=""
    if [ -n "$EC2_INSTANCE_PROFILE" ]; then
        profile_opt="--iam-instance-profile Name=${EC2_INSTANCE_PROFILE}"
    fi
    # shellcheck disable=SC2086
    aws ec2 run-instances \
        --region "$EC2_REGION" \
        --image-id "$EC2_BASE_AMI" \
        --instance-type t3.micro \
        --subnet-id "$EC2_SUBNET" \
        --security-group-ids "$EC2_SG" \
        $profile_opt \
        --no-associate-public-ip-address \
        --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
        --tag-specifications "ResourceType=instance,Tags=[${all_tags}]" \
        --query 'Instances[0].InstanceId' \
        --output text 2>/dev/null
}

# Helper: wait until an instance reaches a given state (max 120s).
_ec2_wait_state() {
    local iid="$1" target="$2" deadline=$(( $(date +%s) + 120 ))
    while true; do
        local cur
        cur="$(aws ec2 describe-instances \
                   --region "$EC2_REGION" \
                   --instance-ids "$iid" \
                   --query 'Reservations[0].Instances[0].State.Name' \
                   --output text 2>/dev/null || echo '')"
        [ "$cur" = "$target" ] && return 0
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf 'test-reap: timed out waiting for %s to reach %s (last: %s)\n' \
                "$iid" "$target" "${cur:-unknown}" >&2
            return 1
        fi
        sleep 5
    done
}

# Helper: run reap.sh with the EC2 section active. Proxmox section is
# satisfied with a curl stub that returns an empty VM list so the script
# reaches the EC2 code. Accepts additional KEY=VALUE pairs as arguments.
_run_reap_ec2() {
    local extra_env=()
    while [[ $# -gt 0 && "$1" == *=* ]]; do
        extra_env+=("$1"); shift
    done
    local rd; rd=$(mktemp -d -p "$TMPDIR_ROOT")
    local bin="$rd/bin"
    mkdir -p "$bin"
    local ca="$rd/ca.pem"
    printf 'DUMMY-CA-CERT\n' > "$ca"
    # Curl stub: all Proxmox calls return an empty VM list or success.
    cat > "$bin/curl" <<'CURLSTUB'
#!/usr/bin/env bash
url="" output_file="" write_out_fmt="" cacert_file=""
i=0; args=("$@")
while [ "$i" -lt "${#args[@]}" ]; do
    arg="${args[$i]}"
    case "$arg" in
        https://*) url="$arg" ;;
        -o|--output) i=$(( i + 1 )); output_file="${args[$i]}" ;;
        -w|--write-out) i=$(( i + 1 )); write_out_fmt="${args[$i]}" ;;
        --cacert) i=$(( i + 1 )); cacert_file="${args[$i]}" ;;
    esac
    i=$(( i + 1 ))
done
[ -n "$cacert_file" ] && [ ! -f "$cacert_file" ] && exit 77
_respond() {
    if [ -n "$output_file" ]; then
        printf '%s' "$1" > "$output_file"
        [ "$write_out_fmt" = '%{http_code}' ] && printf '200'
    else
        printf '%s\n' "$1"
    fi
}
path="${url#https://*/api2/json}"
case "$path" in
    */qemu) _respond '{"data":[]}' ;;
    *)      _respond '{"data":{}}' ;;
esac
CURLSTUB
    chmod +x "$bin/curl"
    PATH="$bin:$PATH" \
    SNIPPETS_DIR="$rd/snip" \
    TEMPLATE_VMID=101 \
    PVE_NODE=pve-dummy \
    PVE_TOKEN_ID=test@pve!tok \
    PVE_TOKEN_SECRET=00000000-0000-0000-0000-000000000000 \
    PVE_CA_CERT_FILE="$ca" \
    SPILL_REGION="$EC2_REGION" \
    GH_ORG="${GH_ORG:-DeckDumpster}" \
    GITHUB_TOKEN="${GITHUB_TOKEN:-}" \
    "${extra_env[@]+"${extra_env[@]}"}" \
    bash "$REAP" "$@"
}

# ============================================================
# TEST 15: A leaked EC2 runner instance whose owning run has finished
#          is terminated by the reaper.
#
# This is the primary acceptance test: a pass against a real instance
# proves the reaper terminates what it should terminate.
#
# The instance is tagged with ephemeral-ci:runner=<label> where <label>
# encodes a completed workflow run. The owning-run check detects the
# finished run and collects the instance before the age cutoff.
# ============================================================
echo "--- Test 15: leaked EC2 runner with finished run is terminated"
(
    # Find a completed run to use as the owning run.
    _finished_run_id="$(gh run list \
        --repo DeckDumpster/ephemeral-ci \
        --status completed \
        --branch main \
        --limit 1 \
        --json databaseId \
        -q '.[0].databaseId' 2>/dev/null || echo '')"

    if [ -z "$_finished_run_id" ]; then
        echo "  SKIP: no completed workflow run found in DeckDumpster/ephemeral-ci" >&2
        exit 0
    fi

    _label="ci-ephemeral-ci-${_finished_run_id}-1"
    _iid="$(_ec2_launch_test_instance "ephemeral-ci-spill" "{Key=ephemeral-ci:runner,Value=${_label}}")"

    if [ -z "$_iid" ] || [[ ! "$_iid" =~ ^i- ]]; then
        echo "  SKIP: could not launch test instance (got: ${_iid:-empty})" >&2
        exit 0
    fi
    printf 'test-reap: Test 15 instance: %s (runner %s)\n' "$_iid" "$_label" >&2

    # Ensure the instance is terminated even if the test fails.
    trap 'aws ec2 terminate-instances --region "$EC2_REGION" --instance-ids "$_iid" >/dev/null 2>&1 || true' EXIT

    # Wait for the instance to reach running state before handing it to the
    # reaper; a pending instance causes describe-instances to return a launch
    # time but the state may confuse idempotency checks on a second pass.
    _ec2_wait_state "$_iid" "running" || {
        echo "  test-reap: instance $_iid did not reach running in time" >&2
        exit 0
    }

    output=$(_run_reap_ec2 2>&1 || true)

    # Verify the instance is now terminated.
    _state="$(aws ec2 describe-instances \
        --region "$EC2_REGION" \
        --instance-ids "$_iid" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo '')"

    if [ "$_state" != "terminated" ] && [ "$_state" != "shutting-down" ]; then
        printf 'test-reap: expected terminated, got: %s\n' "${_state:-unknown}" >&2
        printf '%s\n' "$output" | head -30 | sed 's/^/    /' >&2
        exit 1
    fi

    # Verify the summary reported a termination.
    printf '%s\n' "$output" | grep -qE 'EC2 instance '"$_iid"' terminated|would terminate EC2 '"$_iid" || {
        echo "test-reap: reap.sh did not log termination of $_iid" >&2
        printf '%s\n' "$output" | grep -i ec2 | head -10 | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 15: leaked EC2 runner with finished run is terminated" \
  || _fail "Test 15: leaked EC2 runner with finished run is terminated"

# ============================================================
# TEST 16: A spilled EC2 runner whose runner is currently busy is kept.
#
# The test tags a freshly launched instance with the runner name of
# the GitHub Actions job that IS CURRENTLY EXECUTING THIS TEST. That
# runner is reported as busy=true by the GitHub runners API, so the
# reaper must keep the instance.
#
# Using the real executing runner as the busy signal avoids creating a
# permanently-busy mock: it is only true when this test actually runs.
# ============================================================
echo "--- Test 16: EC2 runner whose runner is busy is kept"
(
    if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GH_ORG:-}" ]; then
        echo "  SKIP: GITHUB_TOKEN or GH_ORG not set" >&2
        exit 0
    fi

    # The runner executing this test is registered in the org under its name.
    # RUNNER_NAME is set by the GitHub Actions runner runtime.
    _busy_runner="${RUNNER_NAME:-}"
    if [ -z "$_busy_runner" ]; then
        # Not running in GitHub Actions; look for any busy runner as a proxy.
        _busy_runner="$(curl -sf \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/orgs/${GH_ORG}/actions/runners?per_page=100" \
            | python3 -c \
                'import json,sys
for r in json.load(sys.stdin).get("runners",[]):
    if r.get("busy"):
        print(r["name"]); break
' 2>/dev/null || echo '')"
    fi

    if [ -z "$_busy_runner" ]; then
        echo "  SKIP: no busy runner available to use as test signal" >&2
        exit 0
    fi

    _iid="$(_ec2_launch_test_instance "ephemeral-ci-spill" "{Key=ephemeral-ci:runner,Value=${_busy_runner}}")"

    if [ -z "$_iid" ] || [[ ! "$_iid" =~ ^i- ]]; then
        echo "  SKIP: could not launch test instance (got: ${_iid:-empty})" >&2
        exit 0
    fi
    printf 'test-reap: Test 16 instance: %s (runner %s)\n' "$_iid" "$_busy_runner" >&2

    trap 'aws ec2 terminate-instances --region "$EC2_REGION" --instance-ids "$_iid" >/dev/null 2>&1 || true' EXIT

    output=$(_run_reap_ec2 --dry-run 2>&1 || true)

    # The instance must NOT appear in "would terminate".
    if printf '%s\n' "$output" | grep -q "would terminate EC2 ${_iid}"; then
        echo "test-reap: reap.sh would terminate busy-runner instance $_iid" >&2
        printf '%s\n' "$output" | grep -i ec2 | head -10 | sed 's/^/    /' >&2
        exit 1
    fi

    # Verify it appeared in the log (so we know it was evaluated, not missed).
    printf '%s\n' "$output" | grep -q "$_iid" || {
        echo "test-reap: instance $_iid was not even evaluated by the reaper" >&2
        printf '%s\n' "$output" | grep -i ec2 | head -10 | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 16: EC2 runner whose runner is busy is kept" \
  || _fail "Test 16: EC2 runner whose runner is busy is kept"

# ============================================================
# TEST 17: Orphaned EBS volume tagged spill:owner=ephemeral-ci is deleted.
#
# An unattached (available) EBS volume with the spill tag is created,
# then the reaper is run. The volume must be absent afterwards.
# ============================================================
echo "--- Test 17: orphaned EBS volume is deleted by the reaper"
(
    _vol_id="$(aws ec2 create-volume \
        --region "$EC2_REGION" \
        --availability-zone "${EC2_REGION}a" \
        --size 1 \
        --volume-type gp3 \
        --tag-specifications "ResourceType=volume,Tags=[{Key=spill:owner,Value=ephemeral-ci},{Key=Name,Value=ephemeral-ci-test-orphan}]" \
        --query 'VolumeId' \
        --output text 2>/dev/null)" || _vol_id=""

    if [ -z "$_vol_id" ] || [[ ! "$_vol_id" =~ ^vol- ]]; then
        echo "  SKIP: could not create test EBS volume (got: ${_vol_id:-empty})" >&2
        exit 0
    fi
    printf 'test-reap: Test 17 volume: %s\n' "$_vol_id" >&2

    trap 'aws ec2 delete-volume --region "$EC2_REGION" --volume-id "$_vol_id" >/dev/null 2>&1 || true' EXIT

    # Wait for the volume to reach available state.
    local_deadline=$(( $(date +%s) + 60 ))
    while true; do
        _vstate="$(aws ec2 describe-volumes \
            --region "$EC2_REGION" \
            --volume-ids "$_vol_id" \
            --query 'Volumes[0].State' \
            --output text 2>/dev/null || echo '')"
        [ "$_vstate" = "available" ] && break
        if [ "$(date +%s)" -ge "$local_deadline" ]; then
            echo "  SKIP: volume $_vol_id did not reach available in 60s (state: ${_vstate:-unknown})" >&2
            exit 0
        fi
        sleep 3
    done

    output=$(_run_reap_ec2 2>&1 || true)

    # Verify the volume is gone.
    _vstate_after="$(aws ec2 describe-volumes \
        --region "$EC2_REGION" \
        --volume-ids "$_vol_id" \
        --query 'Volumes[0].State' \
        --output text 2>/dev/null || echo 'deleted')"

    if [ "$_vstate_after" != "deleted" ] && [ "$_vstate_after" != "deleting" ] && [ -n "$_vstate_after" ]; then
        printf 'test-reap: volume %s still exists (state: %s)\n' "$_vol_id" "$_vstate_after" >&2
        printf '%s\n' "$output" | grep -i 'vol\|ebs\|volume' | head -10 | sed 's/^/    /' >&2
        exit 1
    fi

    printf '%s\n' "$output" | grep -qE "EBS volume ${_vol_id} deleted|would delete orphaned EBS volume ${_vol_id}" || {
        echo "test-reap: reap.sh did not log deletion of volume $_vol_id" >&2
        printf '%s\n' "$output" | grep -i 'vol\|ebs\|volume' | head -10 | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 17: orphaned EBS volume is deleted" \
  || _fail "Test 17: orphaned EBS volume is deleted"

# ============================================================
# TEST 18: Stale AMI-builder instance (Name=ephemeral-ci-runner) past
#          the age cutoff is terminated in dry-run mode.
#
# The instance is young (just launched) but MAX_AGE_HOURS is set to 0
# so every instance is "past the cutoff". The DRY_RUN path is exercised
# so no actual termination occurs; the test verifies the instance appears
# in the "would terminate" output.
# ============================================================
echo "--- Test 18: stale AMI-builder instance is reaped (dry-run, age cutoff 0h)"
(
    _iid="$(_ec2_launch_test_instance "ephemeral-ci-runner" "")"

    if [ -z "$_iid" ] || [[ ! "$_iid" =~ ^i- ]]; then
        echo "  SKIP: could not launch test builder instance (got: ${_iid:-empty})" >&2
        exit 0
    fi
    printf 'test-reap: Test 18 instance: %s\n' "$_iid" >&2

    trap 'aws ec2 terminate-instances --region "$EC2_REGION" --instance-ids "$_iid" >/dev/null 2>&1 || true' EXIT

    # Use --max-age-hours 0 so any instance (including one just launched) is
    # past the cutoff. Dry-run so nothing is actually terminated.
    output=$(_run_reap_ec2 --dry-run --max-age-hours 0 2>&1 || true)

    printf '%s\n' "$output" | grep -q "would terminate EC2 builder ${_iid}" || {
        echo "test-reap: reap.sh did not flag builder instance $_iid for termination" >&2
        printf '%s\n' "$output" | grep -i ec2 | head -10 | sed 's/^/    /' >&2
        exit 1
    }
) && _pass "Test 18: stale AMI-builder instance flagged for reaping" \
  || _fail "Test 18: stale AMI-builder instance flagged for reaping"

fi  # end: EC2_BASE_AMI block
fi  # end: EC2_SUBNET/EC2_SG block
fi  # end: account check block

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
