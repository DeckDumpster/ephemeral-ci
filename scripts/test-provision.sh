#!/usr/bin/env bash
# covers: scripts/provision.sh
#
# Tests for the cloud-init/API rewrite in db-oh4.
# No hypervisor required. curl is stubbed on PATH.
#
# Test cases:
#   1. clone POST carries pool=ephemeral-ci
#   2. clone task with exitstatus != OK -> script fails before inject or start
#   3. registration token never appears in any curl argv
#   4. failure after the clone -> non-zero exit AND vmid=<n> still on stdout,
#      so the caller can tear the VM down
#   5. PVE_TOKEN_SECRET unset -> fails before calling curl, naming the cause
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROVISION="$SCRIPT_DIR/provision.sh"

pass=0
fail=0

ok() { echo "PASS: $1"; (( pass++ )) || true; }
ko() { echo "FAIL: $1"; (( fail++ )) || true; }

SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/bin"
trap 'rm -rf "$SCRATCH"' EXIT

export PATH="$SCRATCH/bin:$PATH"
export TASK_TIMEOUT=5
export AGENT_TIMEOUT=5
export CLONE_RETRIES=3
# Point CRED_FILE at a non-existent path; tests export credentials directly.
export CRED_FILE="$SCRATCH/no-such-cred-file"
# Credentials
export PVE_TOKEN_ID="test-user@pve!provision"
export PVE_TOKEN_SECRET="test-secret-abc123"
export PVE_NODE="pve"

# CURL_ARGV_FILE collects every curl invocation (one arg per line, calls
# separated by ---). Tests reset it between runs.
export CURL_ARGV_FILE="$SCRATCH/curl-argv"

# ---------------------------------------------------------------------------
# Stub: curl
#
# Dispatches responses based on the URL path extracted from argv.
# Behaviour overrides:
#   CURL_CLONE_EXITSTATUS   -- exitstatus in clone task poll response (default: OK)
#   CURL_START_EXITSTATUS   -- exitstatus in start task poll response (default: OK)
#   CURL_VMID_FREE_CODE     -- HTTP code for status/current (default: 500, the real API's
#                              response for a free VMID; provision.sh no longer uses this
#                              path for the free check — see db-ueon)
#   CURL_VMID_403_UNTIL     -- vmid probes for ids <= this return 403 (pool ACL)
#   CURL_FILEWRITE_FAIL_N   -- first N agent/file-write calls return HTTP 500
#   CURL_AGENT_PING_FAIL    -- if "1", agent/ping returns 500 (agent not ready)
#   CURL_CLONE_FAIL_N       -- first N clone POSTs return 403 (collision), then succeed
# ---------------------------------------------------------------------------
cat >"$SCRATCH/bin/curl" <<'SH'
#!/usr/bin/env bash
# Record this invocation to the argv file.
{
    printf '%s\n' "$@"
    echo '---'
} >> "${CURL_ARGV_FILE:?CURL_ARGV_FILE not set}"

# Parse argv for method, URL, output file, and whether -w was requested.
method="GET"
url=""
output_file=""
want_http_code=0
prev=""
for arg in "$@"; do
    case "$prev" in
        -X) method="$arg" ;;
        -o) output_file="$arg" ;;
        -w) want_http_code=1 ;;
    esac
    case "$arg" in https://*) url="$arg" ;; esac
    prev="$arg"
done

path="${url#https://localhost:8006/api2/json}"

# Generate response body and HTTP code based on path and method.
http_code=200
body=""

case "$path" in
    /cluster/nextid | /cluster/nextid[?]*)
        # With no vmid param: return the next free id (200).
        # With ?vmid=<n>: validate that id. If CURL_VMID_OCCUPIED matches, return
        # HTTP 500 "already used" — mirroring the real Proxmox API's response when
        # the VMID is taken. (db-ueon: assert_vmid_free was rewritten to use this
        # endpoint instead of status/current, which the real API answers with 500
        # for free VMIDs, not 404.)
        _nextid_req_vmid=""
        case "$path" in
            *[?]vmid=*) _nextid_req_vmid="$(printf '%s' "${path#*[?]vmid=}" | sed 's/&.*//')" ;;
        esac
        if [ -n "${_nextid_req_vmid:-}" ] \
           && [ -n "${CURL_VMID_OCCUPIED:-}" ] \
           && [ "$_nextid_req_vmid" = "${CURL_VMID_OCCUPIED}" ]; then
            http_code=500
            body="{\"errors\":{\"vmid\":\"vmid ${_nextid_req_vmid} already used\"}}"
        else
            body='{"data":200}'
        fi
        ;;
    /nodes/*/qemu/*/config)
        case "$method" in
            GET)
                # A pool-scoped token gets 403, not 404, for a VM outside its
                # pool. CURL_VMID_403_UNTIL models a host where the low ids are
                # occupied by VMs this token cannot see.
                _probe_vmid="${path#/nodes/}"; _probe_vmid="${_probe_vmid#*/qemu/}"; _probe_vmid="${_probe_vmid%%/*}"
                if [ -n "${CURL_VMID_403_UNTIL:-}" ] \
                   && [ "$_probe_vmid" -le "${CURL_VMID_403_UNTIL}" ] 2>/dev/null; then
                    http_code=403
                    body='{"errors":{"vmid":"Permission check failed"}}'
                else
                    http_code="${CURL_VMID_FREE_CODE:-404}"
                    body='{"errors":{"vmid":"VM not found"}}'
                fi
                ;;
            POST|PUT)
                body='{"data":null}'
                ;;
            *)
                http_code=405
                body='{"errors":{"method":"not allowed"}}'
                ;;
        esac
        ;;
    /nodes/*/qemu/*/clone)
        if [ -n "${CURL_CLONE_403_VMID:-}" ]; then
            http_code=403
            body="{\"errors\":{\"authorization\":\"Permission check failed (/vms/${CURL_CLONE_403_VMID}, VM.Clone)\"}}"
        elif [ -n "${CURL_CLONE_FAIL_N:-}" ]; then
            _cf_state="${TMPDIR:-/tmp}/clone-fail-count"
            _cf_n=$(cat "$_cf_state" 2>/dev/null || echo 0)
            _cf_n=$(( _cf_n + 1 ))
            printf '%s' "$_cf_n" > "$_cf_state"
            if [ "$_cf_n" -le "${CURL_CLONE_FAIL_N}" ]; then
                http_code=403
                body='{"errors":{"authorization":"Permission check failed (/vms/200, VM.Clone)"}}'
            else
                body='{"data":"UPID:pve:00001:00001:00000066:qmclone:101:root@pam:"}'
            fi
        else
            body='{"data":"UPID:pve:00001:00001:00000066:qmclone:101:root@pam:"}'
        fi
        ;;
    /nodes/*/tasks/*qmclone*/status)
        body="{\"data\":{\"status\":\"stopped\",\"exitstatus\":\"${CURL_CLONE_EXITSTATUS:-OK}\"}}"
        ;;
    /nodes/*/tasks/*/status)
        # Catch-all for task polls (covers start and config tasks).
        body="{\"data\":{\"status\":\"stopped\",\"exitstatus\":\"${CURL_START_EXITSTATUS:-OK}\"}}"
        ;;
    /nodes/*/qemu/*/status/start)
        body='{"data":"UPID:pve:00002:00002:00000066:qmstart:200:root@pam:"}'
        ;;
    /nodes/*/qemu/*/status/current)
        # The real Proxmox API returns HTTP 500 with "Configuration file '...'
        # does not exist" for a VMID with no VM, not 404. db-ueon fixed
        # assert_vmid_free to use /cluster/nextid?vmid=<n> instead, so
        # provision.sh no longer calls this path for the free check.
        # CURL_VMID_FREE_CODE overrides the default. CURL_VMID_OCCUPIED still
        # makes the matched id return 200 for tests that exercise this path.
        _cur_vmid="${path#/nodes/}"; _cur_vmid="${_cur_vmid#*/qemu/}"; _cur_vmid="${_cur_vmid%%/*}"
        if [ -n "${CURL_VMID_OCCUPIED:-}" ] && [ "$_cur_vmid" = "${CURL_VMID_OCCUPIED}" ]; then
            http_code=200
            body='{"data":{"status":"stopped","vmid":'"$_cur_vmid"'}}'
        else
            http_code="${CURL_VMID_FREE_CODE:-500}"
            body='{"errors":{"vmid":"does not exist"}}'
        fi
        ;;
    /nodes/*/qemu/*/agent/ping)
        if [ "${CURL_AGENT_PING_FAIL:-0}" = "1" ]; then
            http_code=500
            body='{"errors":{"exc":"qemu guest agent is not running"}}'
        else
            body='{"data":null}'
        fi
        ;;
    /nodes/*/qemu/*/agent/file-write)
        # Guest-agent calls intermittently 500 for the first seconds after the
        # agent starts answering ping. CURL_FILEWRITE_FAIL_N models that.
        if [ -n "${CURL_FILEWRITE_FAIL_N:-}" ]; then
            _fw_state="${TMPDIR:-/tmp}/fw-count"
            _fw_n=$(cat "$_fw_state" 2>/dev/null || echo 0)
            _fw_n=$(( _fw_n + 1 ))
            printf '%s' "$_fw_n" > "$_fw_state"
            if [ "$_fw_n" -le "${CURL_FILEWRITE_FAIL_N}" ]; then
                http_code=500
                body='{"errors":{"exc":"QEMU guest agent is not available"}}'
            else
                body='{"data":null}'
            fi
        else
            body='{"data":null}'
        fi
        ;;
    /nodes/*/qemu/*/agent/exec-status*)
        body="{\"data\":{\"exited\":1,\"exitcode\":${CURL_EXEC_CHECK_RC:-0},\"out-data\":\"\",\"err-data\":\"\"}}"
        ;;
    /nodes/*/qemu/*/agent/exec)
        body='{"data":{"pid":1234}}'
        ;;
    # Node-level reads for the capacity wait. LAST on purpose: a case glob's
    # * spans /, so /nodes/*/status also matches /nodes/<node>/tasks/<upid>/status
    # and would hand poll_task a memory blob instead of an exitstatus. Every
    # specific pattern above must get first refusal.
    #   CURL_NODE_CODE          -- HTTP code for both (default 200; 403 models a
    #                              pool-scoped token that cannot see the node)
    #   CURL_NODE_TOTAL_MIB     -- node RAM in MiB (default 131072)
    #   CURL_NODE_ALLOC_MIB     -- summed maxmem of running VMs in MiB (default 0)
    #   CURL_TEMPLATE_MIB       -- the template's maxmem in MiB (default 8192)
    #   CURL_NODE_CPUS          -- node physical CPU thread count (default 32)
    #   CURL_NODE_ALLOC_CPUS    -- summed cpus of running VMs (default 0)
    #   CURL_TEMPLATE_CPUS      -- the template's cpus (default 8)
    #   CURL_CPU_TIGHT_POLLS    -- if set to N, the first N /qemu list calls
    #                              return CURL_CPU_TIGHT_ALLOC_CPUS (default 120)
    #                              for the running VM's cpus, then revert to
    #                              CURL_NODE_ALLOC_CPUS. Models a concurrent VM
    #                              finishing and freeing cores mid-wait.
    #   CURL_REPO_RUNNER_COUNT  -- if set to N, inject N extra gh-runner-* VMs
    #                              tagged with CURL_NODE_REPO_TAG in the /qemu
    #                              list. Models runners from the same repo that
    #                              are already running.
    #   CURL_NODE_REPO_TAG      -- tag string to set on the injected repo VMs.
    #   CURL_REPO_TIGHT_POLLS   -- if set to N, the first N /qemu list calls
    #                              inject CURL_REPO_RUNNER_COUNT repo VMs; after
    #                              N calls they are omitted. Models a repo runner
    #                              finishing and freeing its slot mid-wait.
    /nodes/*/status)
        http_code="${CURL_NODE_CODE:-200}"
        body="{\"data\":{\"memory\":{\"total\":$(( ${CURL_NODE_TOTAL_MIB:-131072} * 1048576 ))},\"cpuinfo\":{\"cpus\":${CURL_NODE_CPUS:-32}}}}"
        ;;
    /nodes/*/qemu)
        http_code="${CURL_NODE_CODE:-200}"
        _eff_alloc_cpus="${CURL_NODE_ALLOC_CPUS:-0}"
        if [ -n "${CURL_CPU_TIGHT_POLLS:-}" ]; then
            _qemu_list_state="${TMPDIR:-/tmp}/qemu-list-count"
            _qcnt=$(cat "$_qemu_list_state" 2>/dev/null || echo 0)
            _qcnt=$(( _qcnt + 1 ))
            printf '%s' "$_qcnt" > "$_qemu_list_state"
            if [ "$_qcnt" -le "${CURL_CPU_TIGHT_POLLS}" ]; then
                _eff_alloc_cpus="${CURL_CPU_TIGHT_ALLOC_CPUS:-120}"
            fi
        fi
        # Inject gh-runner-* VMs for per-repo count testing.
        _eff_repo_count="${CURL_REPO_RUNNER_COUNT:-0}"
        if [ -n "${CURL_REPO_TIGHT_POLLS:-}" ] && [ "${_eff_repo_count:-0}" -gt 0 ]; then
            _repo_tight_state="${TMPDIR:-/tmp}/repo-tight-count"
            _rtcnt=$(cat "$_repo_tight_state" 2>/dev/null || echo 0)
            _rtcnt=$(( _rtcnt + 1 ))
            printf '%s' "$_rtcnt" > "$_repo_tight_state"
            if [ "$_rtcnt" -gt "${CURL_REPO_TIGHT_POLLS}" ]; then
                _eff_repo_count=0
            fi
        fi
        _repo_runners_json=""
        if [ "${_eff_repo_count:-0}" -gt 0 ] && [ -n "${CURL_NODE_REPO_TAG:-}" ]; then
            for _rn in $(seq 1 "${_eff_repo_count}"); do
                _rvm=$((1000 + _rn))
                _repo_runners_json="${_repo_runners_json},{\"vmid\":${_rvm},\"name\":\"gh-runner-${_rvm}\",\"status\":\"running\",\"maxmem\":$(( ${CURL_TEMPLATE_MIB:-8192} * 1048576 )),\"cpus\":${CURL_TEMPLATE_CPUS:-8},\"tags\":\"${CURL_NODE_REPO_TAG}\"}"
            done
        fi
        body="{\"data\":[{\"vmid\":900,\"status\":\"running\",\"maxmem\":$(( ${CURL_NODE_ALLOC_MIB:-0} * 1048576 )),\"cpus\":${_eff_alloc_cpus}}${_repo_runners_json},{\"vmid\":${TEMPLATE_VMID:-101},\"status\":\"stopped\",\"maxmem\":$(( ${CURL_TEMPLATE_MIB:-8192} * 1048576 )),\"cpus\":${CURL_TEMPLATE_CPUS:-8}}]}"
        ;;
    *)
        printf 'curl stub: unhandled path: %s\n' "$path" >&2
        exit 1
        ;;
esac

# Write body to -o target (or stdout if no -o).
if [ -n "$output_file" ]; then
    printf '%s' "$body" > "$output_file"
else
    printf '%s' "$body"
fi

# Print HTTP code if -w was supplied.
if [ "$want_http_code" -eq 1 ]; then
    printf '%s' "$http_code"
fi
SH
chmod +x "$SCRATCH/bin/curl"

# ---------------------------------------------------------------------------
# Helper: run provision.sh with the given args, capturing stdout and rc.
# Stderr is discarded to keep test output clean.
# ---------------------------------------------------------------------------
run_provision() {
    local out rc
    out=$(bash "$PROVISION" "$@" 2>/dev/null) && rc=0 || rc=$?
    printf '%s\n' "$out"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Test 1 -- clone POST must carry pool=ephemeral-ci
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
# REPO_SLUG is set for this case only, so the tag assertions below have a tag to
# find. provision.sh derives REPO_TAG="repo-owner-repo" from it; every later test
# in this file runs without it, as before.
REPO_SLUG="owner/repo" run_provision valid-label test-token https://github.com/owner/repo >/dev/null

if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-1: clone POST carries pool=ephemeral-ci"
else
    ko "test-1: pool=ephemeral-ci not found in curl argv"
fi

# Prove the check is grounded: the clone URL must also be present.
if grep -q '/clone' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-1: clone endpoint URL recorded in curl argv"
else
    ko "test-1: clone URL missing from curl argv (stub may not have been called)"
fi

# PER-CALL, NOT PER-FILE. The stub appends every invocation to one file with a
# "---" terminator, so a bare grep over the whole file cannot tell the clone POST
# from the config PUT that legitimately carries the tag. This reads one record at
# a time and asks each question of the call it belongs to.
_argv_record_has() {   # _argv_record_has <url-substr> <exact-arg>  -> 0 if found together
    awk -v u="$1" -v a="$2" '
        /^---$/ { if (hasu && hasa) { found = 1 }; hasu = 0; hasa = 0; next }
        index($0, u) { hasu = 1 }
        $0 == a      { hasa = 1 }
        END { exit(found ? 0 : 1) }' "$CURL_ARGV_FILE" 2>/dev/null
}
_argv_record_any() {   # _argv_record_any <url-substr> -> 0 if any record hits that url
    awk -v u="$1" 'index($0, u) { found = 1 } END { exit(found ? 0 : 1) }' \
        "$CURL_ARGV_FILE" 2>/dev/null
}
_argv_clone_has_tags() {
    awk '
        /^---$/ { if (isclone && hastag) { found = 1 }; isclone = 0; hastag = 0; next }
        index($0, "/clone") { isclone = 1 }
        /^tags=/            { hastag = 1 }
        END { exit(found ? 0 : 1) }' "$CURL_ARGV_FILE" 2>/dev/null
}

# THE CLONE POST MUST NOT CARRY tags. Proxmox 9.2.2's clone endpoint has no such
# property and answers HTTP 400 for the whole request; because the clone is also
# the VMID collision check, every retry fails identically and provisioning stops
# dead. On 2026-09-23 that took CI down on every consumer pinned to @v1.
if _argv_clone_has_tags; then
    ko "test-1: clone POST carries a tags parameter — Proxmox rejects the whole request"
else
    ok "test-1: clone POST carries no tags parameter"
fi

# AND THE TAG MUST STILL BE SET, on the config, or the per-repo cap undercounts
# every runner. Asserting only the absence above would pass just as well if the
# tag had been dropped entirely (law-absence-needs-a-positive-control).
if _argv_record_has "/config" "tags=repo-owner-repo"; then
    ok "test-1: the repo tag is set on the VM config instead"
else
    ko "test-1: no config call carrying the repo tag — the per-repo cap will undercount"
fi

# ---------------------------------------------------------------------------
# Test 2 -- clone task exitstatus != OK -> fail, no inject, no start
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
export CURL_CLONE_EXITSTATUS=FAILED
OUT=$(bash "$PROVISION" valid-label test-token https://github.com/owner/repo 2>/dev/null) && rc2=0 || rc2=$?
unset CURL_CLONE_EXITSTATUS

if [ "$rc2" -ne 0 ]; then
    ok "test-2: provision.sh exits non-zero when clone task fails"
else
    ko "test-2: provision.sh should exit non-zero on clone task failure"
fi

# vmid= must NOT appear on stdout (it is emitted after clone succeeds).
if printf '%s\n' "$OUT" | grep -qE '^vmid='; then
    ko "test-2: vmid= appeared on stdout before successful clone (ordering fault)"
else
    ok "test-2: vmid= not on stdout when clone task fails"
fi

# The start endpoint must NOT have been called.
if grep -q '/status/start' "$CURL_ARGV_FILE" 2>/dev/null; then
    ko "test-2: start was called despite clone task failure"
else
    ok "test-2: start not called after clone task failure"
fi

# ---------------------------------------------------------------------------
# Test 3 -- registration token must not appear in any curl argv
# ---------------------------------------------------------------------------
SECRET_TOKEN="SUPERSECRETTOKEN99"
rm -f "$CURL_ARGV_FILE"
run_provision valid-label "$SECRET_TOKEN" https://github.com/owner/repo >/dev/null

if grep -qF "$SECRET_TOKEN" "$CURL_ARGV_FILE" 2>/dev/null; then
    ko "test-3: registration token found in curl argv"
else
    ok "test-3: registration token not present in any curl argv"
fi

# Prove the stub recorded something (so the absence above is meaningful).
if [ -s "$CURL_ARGV_FILE" ]; then
    ok "test-3: curl argv file is non-empty (stub was called)"
else
    ko "test-3: curl argv file is empty -- stub may not have been invoked"
fi

# ---------------------------------------------------------------------------
# Test 4 -- failure after the clone -> non-zero exit AND vmid= on stdout
#
# The VMID must reach the caller even though provision.sh failed, because the
# teardown job is the only thing that can destroy the VM that was created. That
# is the whole point of the output contract at the top of provision.sh.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
export CURL_START_EXITSTATUS=FAILED
OUT4=$(bash "$PROVISION" valid-label test-token https://github.com/owner/repo 2>/dev/null) && rc4=0 || rc4=$?
unset CURL_START_EXITSTATUS

if [ "$rc4" -ne 0 ]; then
    ok "test-4: provision.sh exits non-zero when start task fails"
else
    ko "test-4: provision.sh should exit non-zero on start task failure"
fi

if printf '%s\n' "$OUT4" | grep -qE '^vmid=[0-9]+$'; then
    ok "test-4: vmid=<n> present on stdout despite start failure"
else
    ko "test-4: vmid=<n> missing from stdout on start failure (got: '$OUT4')"
fi

# No ledger assertion: provision.sh deliberately writes no ledger file. A file
# on this runner's disk cannot be read by the teardown job, which runs on a
# different ephemeral runner (db-ulfv). Ownership is established from the
# hypervisor instead — name, pool membership and the template flag.
if grep -q '/clone' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-4: the VM really was created before the failure"
else
    ko "test-4: no clone call recorded — the failure happened too early to test"
fi

# ---------------------------------------------------------------------------
# Test 5 -- PVE_TOKEN_SECRET unset -> fails before calling curl
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
(
    unset PVE_TOKEN_SECRET
    bash "$PROVISION" valid-label test-token https://github.com/owner/repo >/dev/null 2>/dev/null
) && rc5=0 || rc5=$?

if [ "$rc5" -ne 0 ]; then
    ok "test-5: provision.sh exits non-zero when PVE_TOKEN_SECRET is unset"
else
    ko "test-5: provision.sh should fail when PVE_TOKEN_SECRET is unset"
fi

if [ -f "$CURL_ARGV_FILE" ] && [ -s "$CURL_ARGV_FILE" ]; then
    ko "test-5: curl was called despite unset credentials"
else
    ok "test-5: curl not called when credentials are missing"
fi

# ---------------------------------------------------------------------------
# Test 6 -- agent/file-write must target /run/gh-runner-init
#
# provision.sh delivers the runner credentials by writing /run/gh-runner-init
# inside the guest via the qemu guest agent. Verify that the file-write call
# is made to the correct path.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null

if grep -qF '/agent/file-write' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-6: agent/file-write endpoint called"
else
    ko "test-6: agent/file-write not found in curl argv (delivery did not happen)"
fi

# Prove the check is grounded: the target path must also be present in args.
if grep -qF 'file=/run/gh-runner-init' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-6: file=/run/gh-runner-init passed to file-write"
else
    ko "test-6: file=/run/gh-runner-init not found in curl argv (wrong target path)"
fi

# ---------------------------------------------------------------------------
# Test 7 -- guest agent must be polled before file-write
#
# provision.sh waits for /agent/ping to succeed before calling file-write.
# Verify that agent/ping appears in the curl argv, proving the wait happened.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null

if grep -qF '/agent/ping' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-7: agent/ping called to wait for guest agent"
else
    ko "test-7: agent/ping not found in curl argv (agent wait was skipped)"
fi

# Prove the check is grounded: file-write must have followed ping.
if grep -qF '/agent/file-write' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-7: agent/file-write followed the ping (stub was live)"
else
    ko "test-7: agent/file-write missing (stub may not have been called at all)"
fi

# ---------------------------------------------------------------------------
# Test 8 -- agent timeout causes non-zero exit
#
# If the guest agent never responds within AGENT_TIMEOUT seconds,
# provision.sh must exit non-zero without calling file-write.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
export CURL_AGENT_PING_FAIL=1
OUT8=$(bash "$PROVISION" valid-label test-token https://github.com/owner/repo 2>/dev/null) && rc8=0 || rc8=$?
unset CURL_AGENT_PING_FAIL

if [ "$rc8" -ne 0 ]; then
    ok "test-8: provision.sh exits non-zero when agent does not become ready"
else
    ko "test-8: provision.sh should exit non-zero when agent times out"
fi

if ! grep -qF '/agent/file-write' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-8: file-write not called when agent ping times out"
else
    ko "test-8: file-write was called despite agent ping failure"
fi

# ---------------------------------------------------------------------------
# Test 9 -- PVE_API_HOST is honoured
#
# provision.sh no longer runs on the hypervisor. It runs in a GitHub-hosted job
# that reaches the host over the tailnet, so a hardcoded https://localhost:8006
# meant it could not provision anything at all from where it now runs. This
# asserts the configured host reaches curl, and that loopback does not.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
PVE_API_HOST=hv.example.test PVE_API_PORT=9999     bash "$PROVISION" valid-label test-token https://github.com/owner/repo     >/dev/null 2>&1 || true

if grep -qF 'hv.example.test:9999' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-9: PVE_API_HOST/PVE_API_PORT reach the API URL"
else
    ko "test-9: configured API host absent from curl argv"
fi

if grep -qF 'localhost:8006' "$CURL_ARGV_FILE" 2>/dev/null; then
    ko "test-9: loopback still hardcoded somewhere in the API path"
else
    ok "test-9: no hardcoded loopback in the API path"
fi

# ---------------------------------------------------------------------------
# Test 10 -- the guest script is delivered, made runnable, and lands BEFORE
#            the token
#
# start-runner.sh ships from this repository on every run rather than being
# baked into the VM template, so changing it never requires resealing the
# template. Ordering is load-bearing: the guest's ephemeral-runner.path unit
# fires the moment /run/gh-runner-init appears, so the script must already be
# in place and executable when it does.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null

if grep -qF 'file=/home/runner/start-runner.sh' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-10: guest start-runner.sh delivered"
else
    ko "test-10: guest start-runner.sh was never written"
fi

if grep -qF 'command=/bin/chmod' "$CURL_ARGV_FILE" 2>/dev/null \
   && grep -qF 'command=/bin/chown' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-10: guest script chowned and made executable"
else
    ko "test-10: guest script left root-owned or non-executable"
fi

# Ordering, by line number in the recorded argv.
_script_at=$(grep -nF 'file=/home/runner/start-runner.sh' "$CURL_ARGV_FILE" | head -1 | cut -d: -f1)
_token_at=$(grep -nF 'file=/run/gh-runner-init' "$CURL_ARGV_FILE" | head -1 | cut -d: -f1)
if [ -n "$_script_at" ] && [ -n "$_token_at" ] && [ "$_script_at" -lt "$_token_at" ]; then
    ok "test-10: script written before the token (path unit cannot fire early)"
else
    ko "test-10: token written before the script — the path unit can fire with no script present"
fi

if grep -qF 'RUNNER_GROUP' "$CURL_ARGV_FILE" 2>/dev/null \
   || grep -q 'content@' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-10: token payload delivered via a file, not inline argv"
else
    ko "test-10: token payload not delivered through content@FILE"
fi

# ---------------------------------------------------------------------------
# Test 11 -- a pool-scoped token cannot probe an id, so provisioning must not
#            depend on being able to
#
# Proxmox evaluates path permission BEFORE existence, so a token scoped to
# /pool/ephemeral-ci receives 403 for every id outside that pool — including
# ids where no VM exists. Free and occupied are indistinguishable, which is why
# there is no pre-clone probe: it rejected every candidate in turn and then
# gave up. /cluster/nextid is authoritative instead, and the clone itself is
# the collision check.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
CURL_VMID_403_UNTIL=99999 run_provision valid-label test-token https://github.com/DeckDumpster >/dev/null 2>&1 || true

if grep -qF '/clone' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-11: provisioning proceeds when every id probe would 403"
else
    ko "test-11: never reached the clone — provisioning still depends on probing an id"
fi

if grep -qF '/cluster/nextid' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-11: the id came from /cluster/nextid"
else
    ko "test-11: /cluster/nextid was not consulted"
fi

_probe_count=$(grep -cF '/config' "$CURL_ARGV_FILE" 2>/dev/null || true)
if [ "${_probe_count:-0}" -eq 0 ]; then
    ok "test-11: no pre-clone config probe is attempted"
else
    ko "test-11: still probing /config before cloning ($_probe_count call(s))"
fi

# ---------------------------------------------------------------------------
# Test 12 -- the token file appears atomically
#
# ephemeral-runner.path triggers on PathExists, which fires when the path comes
# into being rather than when writing to it finishes. Writing straight to the
# watched path let the guest source a partial file: RUNNER_LABEL was unset, the
# service failed, the path unit retriggered, and systemd rate-limited it after
# five failures in one second. So the payload goes to a path nothing watches
# and is renamed into place.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/DeckDumpster >/dev/null

if grep -qF 'file=/run/gh-runner-init.partial' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-12: payload written to an unwatched path"
else
    ko "test-12: payload written straight to the watched path (race)"
fi

_part_at=$(grep -nF 'file=/run/gh-runner-init.partial' "$CURL_ARGV_FILE" | head -1 | cut -d: -f1)
_mv_at=$(grep -nF 'command=/bin/mv' "$CURL_ARGV_FILE" | head -1 | cut -d: -f1)
if [ -n "$_part_at" ] && [ -n "$_mv_at" ] && [ "$_part_at" -lt "$_mv_at" ]; then
    ok "test-12: renamed into place after the write completed"
else
    ko "test-12: rename did not follow the write"
fi

# ---------------------------------------------------------------------------
# Test 13 -- a transient guest-agent 500 is retried, not fatal
#
# agent/file-write returned HTTP 500 on one run and succeeded on the next with
# identical inputs: the agent channel answers ping before every command is
# serviceable, and the API surfaces that as 500 rather than anything retryable.
# One such response failed an entire provision.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE" "${TMPDIR:-/tmp}/fw-count"
CURL_FILEWRITE_FAIL_N=2 run_provision valid-label test-token https://github.com/DeckDumpster >/dev/null 2>&1
_rc13=$?
rm -f "${TMPDIR:-/tmp}/fw-count"

if [ "$_rc13" -eq 0 ]; then
    ok "test-13: provision survives transient agent 500s"
else
    ko "test-13: a transient agent 500 still fails the provision (rc=$_rc13)"
fi

if grep -qF 'file=/run/gh-runner-init.partial' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-13: reached the token delivery after the retries"
else
    ko "test-13: never reached token delivery"
fi

# ---------------------------------------------------------------------------
# Test 14 -- the delivered guest script must be pure ASCII
#
# Proxmox's agent/file-write dies on any byte above 0x7F:
#   Wide character in subroutine entry at /usr/share/perl5/PVE/API2/Qemu/Agent.pm
# returned as HTTP 500 with no mention of encoding. A single em dash in a
# comment broke every provision, and the message named the hypervisor's Perl
# rather than the file responsible.
# ---------------------------------------------------------------------------
if LC_ALL=C grep -qP '[^\x00-\x7F]' "$SCRIPT_DIR/guest/start-runner.sh" 2>/dev/null; then
    ko "test-14: guest/start-runner.sh contains non-ASCII bytes"
    LC_ALL=C grep -nP '[^\x00-\x7F]' "$SCRIPT_DIR/guest/start-runner.sh" >&2
else
    ok "test-14: guest/start-runner.sh is pure ASCII"
fi

# And provision.sh must refuse rather than let the hypervisor report it.
_ascii_probe="$SCRATCH/ascii-probe.sh"
cp "$SCRIPT_DIR/guest/start-runner.sh" "$_ascii_probe"
printf '# em dash \xe2\x80\x94 here\n' >> "$_ascii_probe"
if LC_ALL=C grep -qP '[^\x00-\x7F]' "$_ascii_probe"; then
    ok "test-14: the probe itself is detectable (positive control)"
else
    ko "test-14: probe file has no non-ASCII — the check proves nothing"
fi
rm -f "$_ascii_probe"

# ---------------------------------------------------------------------------
# Test 15 -- the capacity wait: it gates on ALLOCATION, it waits rather than
# failing, and a permission gap never blocks a run.
#
# Node 131072 MiB, reserve 8192 (the default), template 16384. So with the
# other guests allocating 65536 the node has 57344 free and a runner needing
# 32768 (itself plus one slack) starts; the arithmetic is stated here rather
# than computed so a change to the formula shows up as a failing test.
# ---------------------------------------------------------------------------
export CURL_NODE_TOTAL_MIB=131072
export CURL_TEMPLATE_MIB=16384
export CAPACITY_POLL=1
export CAPACITY_TIMEOUT=3

# (a) room -- provisioning reaches the clone
rm -f "$CURL_ARGV_FILE"
CURL_NODE_ALLOC_MIB=65536 run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-15: with room on the node, the clone goes ahead"
else
    ko "test-15: the capacity wait blocked a clone that fits"
fi

# (b) no room -- it waits, then fails WITHOUT cloning. A capacity control that
# clones anyway is decoration.
rm -f "$CURL_ARGV_FILE"
_cap_err="$SCRATCH/cap-err"
CURL_NODE_ALLOC_MIB=120000 bash "$PROVISION" valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>"$_cap_err" && _cap_rc=0 || _cap_rc=$?
if [ "$_cap_rc" -ne 0 ]; then
    ok "test-15: a node with no room fails the provision"
else
    ko "test-15: provisioned onto a node with no room"
fi
if grep -qF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ko "test-15: cloned anyway — the wait did not gate the clone"
else
    ok "test-15: and NOTHING was cloned"
fi
# law-escalations-carry-their-evidence: the error has to carry the numbers, not
# point at the hypervisor. Whoever reads it is reading a job log, not a console.
if grep -q '::error::' "$_cap_err" && grep -q '131072' "$_cap_err" \
   && grep -q '120000' "$_cap_err"; then
    ok "test-15: the timeout names the node total and what is allocated"
else
    ko "test-15: timeout error does not carry the numbers it decided on"
fi

# (c) the token cannot read the node -- REFUSE (law-a-control-that-cannot-check-must-refuse).
# warn-and-proceed was the original defect (sp-7zzni): a capacity control that disables
# itself on a permission gap is worse than none at all. One red job with an actionable
# message costs less than a hypervisor and an afternoon.
rm -f "$CURL_ARGV_FILE"
CURL_NODE_CODE=403 CURL_NODE_ALLOC_MIB=0 bash "$PROVISION" valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>"$_cap_err" && _cap_rc=0 || _cap_rc=$?
if [ "$_cap_rc" -ne 0 ]; then
    ok "test-15: a missing node-read grant fails the provision"
else
    ko "test-15: a missing grant proceeded -- capacity cap silently disabled"
fi
if ! grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-15: and nothing was cloned without a capacity check"
else
    ko "test-15: cloned without a capacity check (law-a-control-that-cannot-check-must-refuse)"
fi
# law-alerts-must-be-actionable: name the failing call and HTTP status, not the
# privileges needed in general. 'GET /nodes/x/status -> 403' is actionable;
# 'needs Sys.Audit AND VM.Audit' is a restatement of the documentation and cannot
# discriminate between two calls where only one is unauthorised (sp-7zzni note).
if grep -q '403' "$_cap_err"; then
    ok "test-15: the error names the HTTP status from the failing call"
else
    ko "test-15: error does not name the HTTP status"
fi

# (d) the slack is load-bearing. Exactly one runner's worth free is NOT enough:
# two provisions can observe it at once and the API has no atomic reserve.
rm -f "$CURL_ARGV_FILE"
CURL_NODE_ALLOC_MIB=106496 bash "$PROVISION" valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>"$_cap_err" && _cap_rc=0 || _cap_rc=$?
if grep -qF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ko "test-15: room for exactly one runner was treated as room — no slack"
else
    ok "test-15: room for exactly one runner is not enough (slack held)"
fi
# Positive control: the same node WITH the slack disabled does clone, so the
# case above proves the slack and not merely that the arithmetic is off.
rm -f "$CURL_ARGV_FILE"
CURL_NODE_ALLOC_MIB=106496 CAPACITY_SLACK_RUNNERS=0 run_provision valid-label \
    test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-15: and CAPACITY_SLACK_RUNNERS=0 on the same node does clone"
else
    ko "test-15: slack=0 still refused — the refusal was not about slack"
fi

# (e) CAPACITY_UNCAPPED=1 is the explicit opt-out for a deliberately uncapped
# deployment. A missing privilege and a deliberate decision to run uncapped must
# not produce the same behaviour; a caller who wants no cap must say so.
rm -f "$CURL_ARGV_FILE"
CURL_NODE_CODE=403 CAPACITY_UNCAPPED=1 run_provision valid-label test-token \
    https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-15: CAPACITY_UNCAPPED=1 allows provisioning despite unreadable node"
else
    ko "test-15: CAPACITY_UNCAPPED=1 did not bypass the capacity check"
fi

unset CURL_NODE_TOTAL_MIB CURL_TEMPLATE_MIB CURL_NODE_ALLOC_MIB
unset CAPACITY_POLL CAPACITY_TIMEOUT

# ---------------------------------------------------------------------------
# Test 16 -- apt automation: drifted template is refused, not masked-and-warned
#
# provision.sh masks unattended-upgrades.service, apt-daily.timer, and
# apt-daily-upgrade.timer in the clone before delivering credentials. If the
# guest script returns 2 (units were enabled before masking), provision exits 1
# naming the template -- a warning that succeeds cannot surface a fault that
# appears 20 minutes later as a dpkg-lock failure. If it returns any other
# non-zero value (mask or verify failed), provision exits 1.
#
# The sp-vp0me version warned-and-proceeded on exit code 2. This case must now
# fail: law-a-control-that-cannot-check-must-refuse.
# ---------------------------------------------------------------------------

# (a) drifted template: guest script returns 2 (was enabled, now masked).
# provision must refuse with ::error:: and not deliver credentials.
rm -f "$CURL_ARGV_FILE"
export CURL_EXEC_CHECK_RC=2
_err16="$SCRATCH/err16"
bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >/dev/null 2>"$_err16" && _rc16=0 || _rc16=$?
unset CURL_EXEC_CHECK_RC

if [ "$_rc16" -ne 0 ]; then
    ok "test-16a: provision refuses a drifted template"
else
    ko "test-16a: provision proceeded despite drifted template (rc=$_rc16)"
fi

if ! grep -qF 'file=/run/gh-runner-init' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-16a: credentials not delivered when template is drifted"
else
    ko "test-16a: credentials delivered despite drifted template"
fi

if grep -q '::error::' "$_err16" 2>/dev/null; then
    ok "test-16a: ::error:: issued for drifted template"
else
    ko "test-16a: no ::error:: for drifted template (got: $(cat "$_err16"))"
fi

if grep -q '101' "$_err16" 2>/dev/null; then
    ok "test-16a: error names the template"
else
    ko "test-16a: error does not name the template (got: $(cat "$_err16"))"
fi

# (b) mask call fails: guest script returns 1. provision must exit non-zero
# and must not deliver credentials.
rm -f "$CURL_ARGV_FILE"
export CURL_EXEC_CHECK_RC=1
_err16b="$SCRATCH/err16b"
bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >/dev/null 2>"$_err16b" && _rc16b=0 || _rc16b=$?
unset CURL_EXEC_CHECK_RC

if [ "$_rc16b" -ne 0 ]; then
    ok "test-16b: provision exits non-zero when mask fails"
else
    ko "test-16b: provision succeeded despite mask failure"
fi

if grep -qF 'file=/run/gh-runner-init' "$CURL_ARGV_FILE" 2>/dev/null; then
    ko "test-16b: credentials delivered despite mask failure"
else
    ok "test-16b: credentials not delivered when mask fails"
fi

# ---------------------------------------------------------------------------
# Test 17 -- CPU is the binding constraint when memory has room
#
# The memory gate guards one dimension; the CPU gate guards another. A node
# with RAM to spare but no vCPU budget must block even though the memory check
# alone would pass. This was the actual failure mode on 2026-09-22: four PRs
# arrived together, each got a VM because the node had memory for all of them,
# and the jobs starved each other on cores.
#
# Arithmetic:
#   Node 131072 MiB / 32 CPUs; CPU_OVERCOMMIT_RATIO=4 -> budget 128 vCPUs
#   Template 16384 MiB / 8 vCPUs; CAPACITY_SLACK_RUNNERS=1
#   Running VMs allocate 8192 MiB / 116 vCPUs
#
#   Memory: free = 131072 - 8192 - 8192 = 114688 MiB, need = 32768 -> OK
#   CPU:    free = 128 - 116 - 0 = 12 vCPUs,          need = 16    -> blocked
# ---------------------------------------------------------------------------
export CURL_NODE_TOTAL_MIB=131072
export CURL_TEMPLATE_MIB=16384
export CURL_NODE_CPUS=32
export CURL_TEMPLATE_CPUS=8
export CPU_OVERCOMMIT_RATIO=4
export CAPACITY_POLL=1
export CAPACITY_TIMEOUT=3

rm -f "$CURL_ARGV_FILE"
_err17="$SCRATCH/err17"
CURL_NODE_ALLOC_MIB=8192 CURL_NODE_ALLOC_CPUS=116 bash "$PROVISION" \
    valid-label test-token https://github.com/owner/repo \
    >/dev/null 2>"$_err17" && _rc17=0 || _rc17=$?

if [ "$_rc17" -ne 0 ]; then
    ok "test-17: CPU-bound node blocks the provision"
else
    ko "test-17: provision proceeded despite insufficient vCPU budget"
fi

if ! grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-17: nothing cloned when CPU is the binding constraint"
else
    ko "test-17: a VM was cloned despite the CPU gate"
fi

if grep -q '::error::' "$_err17" && grep -q '116' "$_err17"; then
    ok "test-17: timeout error names the allocated CPU count"
else
    ko "test-17: timeout error does not carry the CPU numbers (got: $(cat "$_err17"))"
fi

# Positive control: the same node with enough CPU does proceed.
rm -f "$CURL_ARGV_FILE"
CURL_NODE_ALLOC_MIB=8192 CURL_NODE_ALLOC_CPUS=0 run_provision \
    valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-17: same node with CPU free clones successfully"
else
    ko "test-17: positive control failed -- CPU gate blocked when it should pass"
fi

unset CURL_NODE_TOTAL_MIB CURL_TEMPLATE_MIB CURL_NODE_CPUS CURL_TEMPLATE_CPUS
unset CPU_OVERCOMMIT_RATIO CAPACITY_POLL CAPACITY_TIMEOUT

# ---------------------------------------------------------------------------
# Test 18 -- the CPU gate WAITS and proceeds when a VM goes away
#
# A capacity gate that only fails is useless: a queue that never advances is
# a queue. This test verifies the wait loop actually loops: after two polls
# that see the CPU budget exhausted, the third sees it clear and proceeds.
#
# CURL_CPU_TIGHT_POLLS=2 makes the stub return 120 allocated vCPUs for the
# first two /qemu list calls, then revert to CURL_NODE_ALLOC_CPUS=0.
# With budget 128 and template_cpus=8, need=16: 128-120=8 < 16 for two polls,
# then 128-0=128 >= 16 on the third.
# ---------------------------------------------------------------------------
export CURL_NODE_TOTAL_MIB=131072
export CURL_TEMPLATE_MIB=16384
export CURL_NODE_CPUS=32
export CURL_TEMPLATE_CPUS=8
export CURL_NODE_ALLOC_CPUS=0
export CPU_OVERCOMMIT_RATIO=4
export CAPACITY_POLL=1
export CAPACITY_TIMEOUT=15

rm -f "$CURL_ARGV_FILE" "${TMPDIR:-/tmp}/qemu-list-count"
CURL_CPU_TIGHT_POLLS=2 CURL_CPU_TIGHT_ALLOC_CPUS=120 run_provision \
    valid-label test-token https://github.com/owner/repo >/dev/null
_rc18=$?
rm -f "${TMPDIR:-/tmp}/qemu-list-count"

if [ "$_rc18" -eq 0 ]; then
    ok "test-18: provision waits and proceeds when CPU clears mid-wait"
else
    ko "test-18: provision did not proceed after CPU budget freed (rc=$_rc18)"
fi

if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-18: a VM was cloned after the CPU wait resolved"
else
    ko "test-18: clone never happened after the CPU wait"
fi

unset CURL_NODE_TOTAL_MIB CURL_TEMPLATE_MIB CURL_NODE_CPUS CURL_TEMPLATE_CPUS
unset CURL_NODE_ALLOC_CPUS CPU_OVERCOMMIT_RATIO CAPACITY_POLL CAPACITY_TIMEOUT

# ---------------------------------------------------------------------------
# Test 19 -- CAPACITY_SLACK_RUNNERS still bounds overshoot for the CPU gate
#
# Two provision jobs can both observe a free vCPU slot at the same time; the
# API has no atomic reserve. CAPACITY_SLACK_RUNNERS demands room for this
# runner plus slack more, so both can clone without exhausting the budget.
#
# Arithmetic (CPU, slack=1):
#   budget 128, alloc 116, free 12 < need 16 -> blocked
#   budget 128, alloc 116, free 12 >= need 8 (slack=0) -> clones
# ---------------------------------------------------------------------------
export CURL_NODE_TOTAL_MIB=131072
export CURL_TEMPLATE_MIB=16384
export CURL_NODE_CPUS=32
export CURL_TEMPLATE_CPUS=8
export CPU_OVERCOMMIT_RATIO=4
export CAPACITY_POLL=1
export CAPACITY_TIMEOUT=3

rm -f "$CURL_ARGV_FILE"
CURL_NODE_ALLOC_CPUS=116 bash "$PROVISION" valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>/dev/null && _cap19=0 || _cap19=$?
if ! grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-19: room for exactly one vCPU slot is not enough (CPU slack held)"
else
    ko "test-19: room for exactly one vCPU slot was treated as enough -- no slack"
fi

# Positive control: slack=0 on the same node does clone.
rm -f "$CURL_ARGV_FILE"
CURL_NODE_ALLOC_CPUS=116 CAPACITY_SLACK_RUNNERS=0 run_provision \
    valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-19: CAPACITY_SLACK_RUNNERS=0 on the same CPU budget does clone"
else
    ko "test-19: slack=0 still refused -- the refusal was not about CPU slack"
fi

unset CURL_NODE_TOTAL_MIB CURL_TEMPLATE_MIB CURL_NODE_CPUS CURL_TEMPLATE_CPUS
unset CPU_OVERCOMMIT_RATIO CAPACITY_POLL CAPACITY_TIMEOUT

# ---------------------------------------------------------------------------
# Test 20 -- vmtoken= appears on stdout alongside vmid= (db-ogjn)
#
# provision.sh stamps a random hex token into the VM description and emits it
# on stdout so callers can pass it to teardown.sh. Both lines must appear in
# a single successful provision run.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
OUT20=$(run_provision valid-label test-token https://github.com/owner/repo 2>/dev/null)
_rc20=$?

if [ "$_rc20" -eq 0 ]; then
    ok "test-20: provision exits 0 (sanity)"
else
    ko "test-20: provision exited non-zero ($_rc20) — cannot check vmtoken"
fi

if printf '%s\n' "$OUT20" | grep -qE '^vmtoken=[a-f0-9]{32}$'; then
    ok "test-20: vmtoken=<32 hex chars> appears on stdout"
else
    ko "test-20: vmtoken= line missing or not 32 hex chars (got: $(printf '%s\n' "$OUT20" | grep vmtoken || echo '<nothing>'))"
fi

if printf '%s\n' "$OUT20" | grep -qE '^vmid=[0-9]+$'; then
    ok "test-20: vmid= still present on stdout alongside vmtoken"
else
    ko "test-20: vmid= missing from stdout"
fi

# ---------------------------------------------------------------------------
# Test 21 -- the token in the description matches what is on stdout (db-ogjn)
#
# The clone POST carries description=runner=<label> vmtoken=<token>.  The token
# in that description must be the same value emitted on stdout, otherwise a
# caller that captures the stdout token cannot verify it against the VM.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
OUT21=$(run_provision valid-label test-token https://github.com/owner/repo 2>/dev/null)

_stdout_token=$(printf '%s\n' "$OUT21" | grep -oE 'vmtoken=[a-f0-9]+' | cut -d= -f2 || true)
_desc_token=$(grep -oE 'vmtoken=[a-f0-9]+' "$CURL_ARGV_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)

if [ -n "$_stdout_token" ] && [ -n "$_desc_token" ] && [ "$_stdout_token" = "$_desc_token" ]; then
    ok "test-21: vmtoken on stdout matches vmtoken in clone description"
else
    ko "test-21: token mismatch or missing (stdout='$_stdout_token', description='$_desc_token')"
fi

# The description field must appear in the clone POST argv (not in a task or
# status poll), proving the token is part of the creation call itself.
if grep -qF 'vmtoken=' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-21: vmtoken= carried in a curl argv (recorded in the clone call)"
else
    ko "test-21: vmtoken= never appeared in any curl argv"
fi

# ---------------------------------------------------------------------------
# Test 22 -- provision_time= appears in the clone description (db-e1we)
#
# provision.sh stamps the clone epoch in the VM description so reap.sh can
# use it as an authoritative age source instead of meta.ctime, which Proxmox
# may copy verbatim from the template rather than updating at clone time. The
# value must be a numeric Unix epoch.
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null

if grep -qP 'provision_time=\d+' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-22: provision_time=<epoch> in clone description"
else
    ko "test-22: provision_time= missing or non-numeric in clone description"
fi

# ---------------------------------------------------------------------------
# Test 23 -- per-repo admission cap (FLEET_SHARE_PER_REPO)
#
# REPO_SLUG="owner/repo" causes provision.sh to derive REPO_TAG="repo-owner-repo"
# and count ALL gh-runner-* VMs bearing that tag before cloning. If the count
# is at or above FLEET_SHARE_PER_REPO the provision waits, not fails; it
# proceeds once the count drops below the cap.
#
# Counting stopped VMs (not just running ones) catches VMs that have been
# cloned but not yet started, narrowing the race window between concurrent
# provisions from the same repository.
# ---------------------------------------------------------------------------
export CURL_NODE_TOTAL_MIB=131072
export CURL_TEMPLATE_MIB=16384
export CURL_NODE_CPUS=32
export CURL_TEMPLATE_CPUS=8
export CURL_NODE_ALLOC_MIB=0
export CURL_NODE_ALLOC_CPUS=0
export CPU_OVERCOMMIT_RATIO=4
export CAPACITY_POLL=1
export CAPACITY_TIMEOUT=5
export FLEET_SHARE_PER_REPO=1
export REPO_SLUG="owner/repo"
# provision.sh derives REPO_TAG="repo-owner-repo" from REPO_SLUG="owner/repo"

# (a) cap hit: one repo runner already running -> provision waits, then times out
rm -f "$CURL_ARGV_FILE"
_err23="$SCRATCH/err23a"
CURL_REPO_RUNNER_COUNT=1 CURL_NODE_REPO_TAG="repo-owner-repo" bash "$PROVISION" \
    valid-label test-token https://github.com/owner/repo >/dev/null 2>"$_err23" && _rc23a=0 || _rc23a=$?
if [ "$_rc23a" -ne 0 ]; then
    ok "test-23a: per-repo cap blocks provision when at limit"
else
    ko "test-23a: provision proceeded despite per-repo cap being hit"
fi
if ! grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23a: nothing cloned while per-repo cap is at limit"
else
    ko "test-23a: clone happened despite per-repo cap"
fi

# (b) cap not hit: zero runners for this repo -> provision proceeds
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23b: provision proceeds when per-repo count is below cap"
else
    ko "test-23b: provision did not proceed with per-repo count below cap"
fi

# (c) FLEET_SHARE_PER_REPO=0 disables the cap
rm -f "$CURL_ARGV_FILE"
CURL_REPO_RUNNER_COUNT=5 CURL_NODE_REPO_TAG="repo-owner-repo" FLEET_SHARE_PER_REPO=0 \
    run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23c: FLEET_SHARE_PER_REPO=0 disables the cap"
else
    ko "test-23c: per-repo cap not disabled by FLEET_SHARE_PER_REPO=0"
fi

# (d) at exact threshold: two running, cap=2 -> blocked; cap=3 -> proceeds
rm -f "$CURL_ARGV_FILE"
_err23d="$SCRATCH/err23d"
CURL_REPO_RUNNER_COUNT=2 CURL_NODE_REPO_TAG="repo-owner-repo" FLEET_SHARE_PER_REPO=2 \
    bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >/dev/null 2>"$_err23d" && _rc23d=0 || _rc23d=$?
if [ "$_rc23d" -ne 0 ]; then
    ok "test-23d: cap at exact threshold blocks provision (count=cap -> blocked)"
else
    ko "test-23d: provision proceeded at exact threshold (off-by-one in cap check)"
fi

rm -f "$CURL_ARGV_FILE"
CURL_REPO_RUNNER_COUNT=2 CURL_NODE_REPO_TAG="repo-owner-repo" FLEET_SHARE_PER_REPO=3 \
    run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23d: count below cap (2 < 3) allows clone"
else
    ko "test-23d: clone blocked despite count being below cap"
fi

# (e) provision waits and proceeds once a repo runner goes away
rm -f "$CURL_ARGV_FILE" "${TMPDIR:-/tmp}/repo-tight-count"
CURL_REPO_RUNNER_COUNT=1 CURL_NODE_REPO_TAG="repo-owner-repo" FLEET_SHARE_PER_REPO=1 \
    CURL_REPO_TIGHT_POLLS=2 CAPACITY_TIMEOUT=15 \
    run_provision valid-label test-token https://github.com/owner/repo >/dev/null
_rc23e=$?
rm -f "${TMPDIR:-/tmp}/repo-tight-count"
if [ "$_rc23e" -eq 0 ]; then
    ok "test-23e: provision waits and proceeds when per-repo cap clears"
else
    ko "test-23e: provision did not proceed after per-repo cap cleared (rc=$_rc23e)"
fi
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23e: a VM was cloned after the per-repo wait resolved"
else
    ko "test-23e: clone never happened after per-repo wait"
fi

# (f) no REPO_SLUG -> per-repo cap is skipped regardless of FLEET_SHARE_PER_REPO
unset REPO_SLUG
rm -f "$CURL_ARGV_FILE"
CURL_REPO_RUNNER_COUNT=5 CURL_NODE_REPO_TAG="repo-owner-repo" FLEET_SHARE_PER_REPO=1 \
    run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23f: without REPO_SLUG the per-repo cap is not enforced"
else
    ko "test-23f: per-repo cap enforced despite REPO_SLUG being unset"
fi

# (g) tag goes on config PUT, not clone POST, when REPO_SLUG is set
#
# The clone endpoint (Proxmox 9.2.2) has no tags property and rejects
# the whole request with HTTP 400. The tag is set via PUT .../config
# after the clone task completes. The per-repo count comes from the qemu
# LIST endpoint, which returns tags however they were set.
#
# The pre-fix version of this sub-test used a bare grep over the whole
# argv file and was labelled "clone POST carries the repo tag". It passed
# only because the config PUT carried the tag — the grep found tags
# anywhere in the file, not specifically in the clone record. Using the
# per-call helpers added in sp-s0wdr makes the distinction explicit.
export REPO_SLUG="owner/repo"
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if _argv_clone_has_tags; then
    ko "test-23g: clone POST carries tags= — Proxmox 9.2.2 rejects the whole request"
else
    ok "test-23g: clone POST carries no tags= when REPO_SLUG is set"
fi
if _argv_record_has "/config" "tags=repo-owner-repo"; then
    ok "test-23g: the repo tag is set on the config PUT instead"
else
    ko "test-23g: repo tag missing from the config PUT"
fi
# Positive control: without REPO_SLUG neither call carries tags
unset REPO_SLUG
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if ! grep -qF 'tags=' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23g: no tags= anywhere when REPO_SLUG is unset"
else
    ko "test-23g: tags= appeared despite REPO_SLUG being unset"
fi

# (h) THE DEFAULT IS OFF. FLEET_SHARE_PER_REPO unset, five runners already carry this
# repo's tag, and the node has room -> provision proceeds. Shipped at 1, the default held
# spira to a single runner with ~34 GiB free on the node (2026-09-23). The action input
# must default to 0 too: it is always passed, so its default is the one consumers get.
export REPO_SLUG="owner/repo"
unset FLEET_SHARE_PER_REPO
rm -f "$CURL_ARGV_FILE"
CURL_REPO_RUNNER_COUNT=5 CURL_NODE_REPO_TAG="repo-owner-repo" \
    run_provision valid-label test-token https://github.com/owner/repo >/dev/null
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-23h: with FLEET_SHARE_PER_REPO unset the per-repo cap is off"
else
    ko "test-23h: per-repo cap enforced by default"
fi
_share_default="$(awk '/^  fleet-share-per-repo:/{f=1;next} f&&/^  [a-z]/{exit} f&&/^ *default:/{gsub(/[^0-9]/,"");print;exit}' "$SCRIPT_DIR/../provision/action.yml")"
if [ "$_share_default" = "0" ]; then
    ok "test-23h: provision action's fleet-share-per-repo defaults to 0"
else
    ko "test-23h: provision action's fleet-share-per-repo default is [${_share_default}], want 0"
fi

unset CURL_NODE_TOTAL_MIB CURL_TEMPLATE_MIB CURL_NODE_CPUS CURL_TEMPLATE_CPUS
unset CURL_NODE_ALLOC_MIB CURL_NODE_ALLOC_CPUS CPU_OVERCOMMIT_RATIO
unset CAPACITY_POLL CAPACITY_TIMEOUT FLEET_SHARE_PER_REPO REPO_SLUG

# ---------------------------------------------------------------------------
# Test 24 -- per-template boot lock serialises concurrent starts (sp-bmim8)
#
# Linked clones from the same template share a base volume. Two booting at
# once contend on that volume and can both miss the 120s agent window.
# provision.sh holds a flock(2) from VM start through agent-ready, so only
# one clone per template boots at a time.
#
# (a) flock timeout: when the lock cannot be acquired within BOOT_LOCK_TIMEOUT,
#     provision exits non-zero and names the template in the error message.
# (b) happy path: the lock is acquired and released; the provision succeeds
#     and the lock file is left on disk (flock semantics -- the fd is closed,
#     not the file).
# ---------------------------------------------------------------------------

# Stub flock to exit 1 immediately (models lock held by another process).
cat >"$SCRATCH/bin/flock" <<'SH'
#!/usr/bin/env bash
# When FLOCK_FAIL=1 act as if the lock could not be acquired.
if [ "${FLOCK_FAIL:-0}" = "1" ]; then
    exit 1
fi
# Otherwise delegate to the real flock.
exec /usr/bin/flock "$@"
SH
chmod +x "$SCRATCH/bin/flock"

# (a) lock held by another -- provision must exit non-zero naming the template
rm -f "$CURL_ARGV_FILE"
_err24="$SCRATCH/err24a"
FLOCK_FAIL=1 BOOT_LOCK_TIMEOUT=1 TEMPLATE_VMID=107 bash "$PROVISION" \
    valid-label test-token https://github.com/owner/repo \
    >/dev/null 2>"$_err24" && _rc24a=0 || _rc24a=$?

if [ "$_rc24a" -ne 0 ]; then
    ok "test-24a: provision exits non-zero when boot lock times out"
else
    ko "test-24a: provision succeeded despite boot lock timeout"
fi

if grep -q '107' "$_err24" 2>/dev/null; then
    ok "test-24a: error message names the template"
else
    ko "test-24a: error message does not name the template (got: $(cat "$_err24"))"
fi

if ! grep -q '/status/start' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-24a: VM was not started while lock was blocked"
else
    ko "test-24a: start was called despite lock timeout (lock must guard start, not clone)"
fi

# (b) happy path -- lock is acquired, provision completes normally
rm -f "$CURL_ARGV_FILE"
TEMPLATE_VMID=107 run_provision valid-label test-token \
    https://github.com/owner/repo >/dev/null
_rc24b=$?
if [ "$_rc24b" -eq 0 ]; then
    ok "test-24b: provision succeeds when boot lock can be acquired"
else
    ko "test-24b: provision failed with real flock (rc=$_rc24b)"
fi
if grep -qxF 'pool=ephemeral-ci' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-24b: clone proceeded after boot lock acquisition"
else
    ko "test-24b: clone did not happen on the happy path"
fi

# (c) the lock path is per-template -- template 107 and template 101 use
#     different lock files, so they do not block each other.
_lock107="/var/lock/pve-clone-107.lock"
_lock101="/var/lock/pve-clone-101.lock"
rm -f "$_lock107" "$_lock101"
TEMPLATE_VMID=107 run_provision valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>/dev/null || true
TEMPLATE_VMID=101 run_provision valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>/dev/null || true
if [ -f "$_lock107" ] && [ -f "$_lock101" ]; then
    ok "test-24c: separate lock files for template 107 and 101"
else
    ko "test-24c: lock files not distinct per template (_lock107=$([ -f "$_lock107" ] && echo exists || echo missing) _lock101=$([ -f "$_lock101" ] && echo exists || echo missing))"
fi

# Restore default TEMPLATE_VMID for any tests that follow.
export TEMPLATE_VMID=101

# ---------------------------------------------------------------------------
# Test 25 -- provision makes no per-VMID existence probe before the clone (db-zzon)
#
# pick_vmid calls /cluster/nextid (no ?vmid= parameter) to get the next id.
# That is the only pre-clone VMID call. No subsequent probe —
# /cluster/nextid?vmid=<n> (db-spsp/db-ueon) or /status/current (db-spsp) —
# may appear before the clone. The clone itself is the authoritative collision
# check: Proxmox refuses to clone onto an existing VMID, and that refusal
# requires no permission the pool-scoped token lacks. See pick_vmid.
#
# (a) normal run: neither nextid?vmid= nor status/current appears before the clone
# (b) positive control: the clone IS reached (so the absence above is grounded)
# (c) even with CURL_VMID_OCCUPIED set (which would make the old probe fail),
#     provision reaches the clone because the probe no longer exists
# (d) clone-refusal retry: a collision caught by the clone triggers a fresh
#     nextid call and a retry; the second attempt succeeds
# ---------------------------------------------------------------------------

# (a) + (b): no per-VMID probe, clone is still reached
rm -f "$CURL_ARGV_FILE"
run_provision valid-label test-token https://github.com/owner/repo >/dev/null

_vmid_probe_count=$(grep -cF '/cluster/nextid?vmid=' "$CURL_ARGV_FILE" 2>/dev/null) || _vmid_probe_count=0
_status_cur_count=$(grep -cF '/status/current' "$CURL_ARGV_FILE" 2>/dev/null) || _status_cur_count=0
_total_probes=$(( _vmid_probe_count + _status_cur_count ))

if [ "$_total_probes" -eq 0 ]; then
    ok "test-25a: no per-VMID existence probe before the clone"
else
    ko "test-25a: per-VMID probe found (nextid?vmid=$_vmid_probe_count, status/current=$_status_cur_count)"
fi

if grep -qF '/clone' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-25b: clone endpoint was reached (assertion is grounded)"
else
    ko "test-25b: clone endpoint not reached -- the absence above proves nothing"
fi

# (c) CURL_VMID_OCCUPIED=200 makes nextid?vmid=200 return 500, but provision
# no longer makes that call, so the provision reaches the clone normally.
rm -f "$CURL_ARGV_FILE"
CURL_VMID_OCCUPIED=200 run_provision valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>/dev/null
if grep -qF '/clone' "$CURL_ARGV_FILE" 2>/dev/null; then
    ok "test-25c: provision reaches the clone even when nextid?vmid= would 500"
else
    ko "test-25c: provision failed on a VMID that would have failed the old probe"
fi

# (d) clone-refusal retry: first clone returns 403 (collision), provision
# calls nextid again and retries; the second attempt succeeds.
rm -f "$CURL_ARGV_FILE" "${TMPDIR:-/tmp}/clone-fail-count"
CURL_CLONE_FAIL_N=1 run_provision valid-label test-token \
    https://github.com/owner/repo >/dev/null 2>/dev/null
_rc25d=$?
rm -f "${TMPDIR:-/tmp}/clone-fail-count"

if [ "$_rc25d" -eq 0 ]; then
    ok "test-25d: provision retries and succeeds after a clone collision"
else
    ko "test-25d: provision did not recover from a clone collision (rc=$_rc25d)"
fi

_clone_calls=$(grep -cF '/clone' "$CURL_ARGV_FILE" 2>/dev/null) || _clone_calls=0
if [ "${_clone_calls:-0}" -ge 2 ]; then
    ok "test-25d: clone was attempted more than once (retry happened)"
else
    ko "test-25d: clone called only once — retry did not happen ($_clone_calls call(s))"
fi

# ---------------------------------------------------------------------------
# Test 26 -- a 403 on the clone names the refused object, not just the target
#
# The Proxmox API returns "403 Permission check failed (/vms/<id>, <perm>)"
# when a token lacks a right on a specific object. provision.sh used to print
# "clone onto VMID <target> refused" regardless, which sent the reader to the
# wrong VM when the template was what the API actually denied (db-g8po).
#
# (a) 403 names the template (freshly created template not yet in the pool):
#     message must say "template <id>" and name the permission, not target VMID.
# (b) 403 names the target VMID (a collision):
#     message must name the target VMID.
# ---------------------------------------------------------------------------

# (a) refused object is the template
rm -f "$CURL_ARGV_FILE"
_err26a="$SCRATCH/err26a"
CLONE_RETRIES=1 TEMPLATE_VMID=107 CURL_CLONE_403_VMID=107 \
    bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >/dev/null 2>"$_err26a" && _rc26a=0 || _rc26a=$?

if [ "$_rc26a" -ne 0 ]; then
    ok "test-26a: provision fails when all clone attempts return 403 on the template"
else
    ko "test-26a: provision succeeded despite 403 on every clone attempt"
fi
if grep -q "template 107" "$_err26a"; then
    ok "test-26a: error names the template"
else
    ko "test-26a: error does not name the template (got: $(cat "$_err26a"))"
fi
if grep -q "VM.Clone" "$_err26a"; then
    ok "test-26a: error names the refused permission"
else
    ko "test-26a: error does not name the permission (got: $(cat "$_err26a"))"
fi
if ! grep -q "clone onto VMID 200" "$_err26a"; then
    ok "test-26a: error does not blame the target VMID for a template permission failure"
else
    ko "test-26a: error blames the target VMID instead of the template"
fi

# Restore TEMPLATE_VMID for subsequent tests.
export TEMPLATE_VMID=101

# (b) refused object is the target VMID (/cluster/nextid returns 200)
rm -f "$CURL_ARGV_FILE"
_err26b="$SCRATCH/err26b"
CLONE_RETRIES=1 CURL_CLONE_403_VMID=200 \
    bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >/dev/null 2>"$_err26b" && _rc26b=0 || _rc26b=$?

if [ "$_rc26b" -ne 0 ]; then
    ok "test-26b: provision fails when all clone attempts return 403 on the target"
else
    ko "test-26b: provision succeeded despite 403 on every clone attempt"
fi
if grep -q "VMID 200" "$_err26b"; then
    ok "test-26b: error names the target VMID"
else
    ko "test-26b: error does not name the target VMID 200 (got: $(cat "$_err26b"))"
fi
if ! grep -q "in the ephemeral-ci pool" "$_err26b"; then
    ok "test-26b: template pool hint absent when the target VMID was refused"
else
    ko "test-26b: template pool hint appeared for a target-VMID refusal"
fi

# ---------------------------------------------------------------------------
# Tests 27-29: EC2 spill path
#
# These tests stub the AWS CLI so no real AWS calls are made.  Each invocation
# is recorded to AWS_ARGV_FILE so assertions can inspect what was passed.
# ---------------------------------------------------------------------------

# AWS CLI stub: records every invocation to $AWS_ARGV_FILE, one line per arg
# (separated by a record separator, \x1e), then returns canned output based on
# the first few arguments.
AWS_ARGV_FILE="$SCRATCH/aws-argv"
AWS_BIN="$SCRATCH/aws"
cat > "$AWS_BIN" << 'AWSSTUB'
#!/bin/sh
SEP=$(printf '\x1e')
printf '%s\n' "$*" >> "$AWS_ARGV_FILE"
# Route by subcommand
case "$1 $2" in
    "cloudformation describe-stacks")
        printf '[{"OutputKey":"SubnetId","OutputValue":"subnet-test123"},{"OutputKey":"SecurityGroupId","OutputValue":"sg-test456"},{"OutputKey":"LaunchTemplateId","OutputValue":"lt-test789"}]\n'
        ;;
    "ec2 describe-instances")
        printf '0\n'
        ;;
    "ec2 describe-images")
        printf 'ami-testdeadbeef\n'
        ;;
    "ec2 run-instances")
        printf 'i-testinstance001\n'
        ;;
    "ssm describe-instance-information")
        printf 'Online\n'
        ;;
    "ssm put-parameter")
        ;;
    "ssm send-command")
        printf 'cmd-testcmd001\n'
        ;;
    "ssm get-command-invocation")
        printf 'Success\n'
        ;;
    "ssm delete-parameter")
        ;;
    *)
        printf 'aws-stub: unhandled: %s\n' "$*" >&2
        exit 1
        ;;
esac
AWSSTUB
chmod +x "$AWS_BIN"
export PATH="$SCRATCH:$PATH"
export AWS_ARGV_FILE

# ---------------------------------------------------------------------------
# Test 27: SPILL=off — capacity failure exits non-zero, no AWS calls
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE" "$AWS_ARGV_FILE"
_out27="$SCRATCH/out27"
_err27="$SCRATCH/err27"
# Node is at capacity: CURL_NODE_ALLOC_MIB=131072 exhausts all memory.
CURL_NODE_ALLOC_MIB=131072 CAPACITY_TIMEOUT=0 SPILL=off \
    bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >"$_out27" 2>"$_err27" && _rc27=0 || _rc27=$?

if [ "$_rc27" -ne 0 ]; then
    ok "test-27: SPILL=off capacity failure exits non-zero"
else
    ko "test-27: SPILL=off capacity failure should exit non-zero"
fi
if [ ! -f "$AWS_ARGV_FILE" ] || [ ! -s "$AWS_ARGV_FILE" ]; then
    ok "test-27: SPILL=off makes no AWS calls"
else
    ko "test-27: SPILL=off made unexpected AWS calls: $(cat "$AWS_ARGV_FILE")"
fi

# ---------------------------------------------------------------------------
# Test 28: SPILL=ec2, Proxmox has room → uses Proxmox, no AWS calls,
#          backend=proxmox on stdout
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE" "$AWS_ARGV_FILE"
_out28="$SCRATCH/out28"
_err28="$SCRATCH/err28"
SPILL=ec2 SPILL_AFTER_SECONDS=0 CAPACITY_TIMEOUT=3600 \
    bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >"$_out28" 2>"$_err28" && _rc28=0 || _rc28=$?

if [ "$_rc28" -eq 0 ]; then
    ok "test-28: SPILL=ec2 with Proxmox room succeeds"
else
    ko "test-28: SPILL=ec2 with Proxmox room failed (rc=$_rc28; err: $(cat "$_err28"))"
fi
if [ ! -f "$AWS_ARGV_FILE" ] || [ ! -s "$AWS_ARGV_FILE" ]; then
    ok "test-28: Proxmox path makes no AWS calls"
else
    ko "test-28: Proxmox path made unexpected AWS calls: $(cat "$AWS_ARGV_FILE")"
fi
if grep -q "^backend=proxmox$" "$_out28"; then
    ok "test-28: stdout contains backend=proxmox"
else
    ko "test-28: stdout missing backend=proxmox (got: $(cat "$_out28"))"
fi

# ---------------------------------------------------------------------------
# Test 29: SPILL=ec2, Proxmox exhausted → EC2 path
#   - backend=ec2 on stdout
#   - instance-id on stdout
#   - vmid= empty (not a Proxmox VMID)
#   - vmtoken on stdout
#   - run-instances has no --user-data
#   - send-command does not contain the token value
#   - run-instances carries ephemeral-ci:vmtoken tag matching stdout vmtoken
#   - put-parameter includes Key=ephemeral-ci:vmtoken tag matching stdout vmtoken
# ---------------------------------------------------------------------------
rm -f "$CURL_ARGV_FILE" "$AWS_ARGV_FILE"
_out29="$SCRATCH/out29"
_err29="$SCRATCH/err29"
# Node is at capacity: CURL_NODE_ALLOC_MIB=131072 exhausts all memory.
CURL_NODE_ALLOC_MIB=131072 CAPACITY_TIMEOUT=0 SPILL=ec2 SPILL_SSM_WAIT_SECONDS=60 \
    bash "$PROVISION" valid-label test-token https://github.com/owner/repo \
    >"$_out29" 2>"$_err29" && _rc29=0 || _rc29=$?

if [ "$_rc29" -eq 0 ]; then
    ok "test-29: EC2 spill path exits zero"
else
    ko "test-29: EC2 spill path failed (rc=$_rc29; err: $(cat "$_err29"))"
fi

_vmtoken29="$(grep "^vmtoken=" "$_out29" | sed 's/^vmtoken=//')"
_iid29="$(grep "^instance-id=" "$_out29" | sed 's/^instance-id=//')"
_vmid29="$(grep "^vmid=" "$_out29" | sed 's/^vmid=//')"
_backend29="$(grep "^backend=" "$_out29" | sed 's/^backend=//')"

if [ "$_backend29" = "ec2" ]; then
    ok "test-29: backend=ec2 on stdout"
else
    ko "test-29: expected backend=ec2, got '${_backend29}' (stdout: $(cat "$_out29"))"
fi
if [ -n "$_iid29" ]; then
    ok "test-29: instance-id on stdout (${_iid29})"
else
    ko "test-29: instance-id missing from stdout"
fi
if [ -z "$_vmid29" ]; then
    ok "test-29: vmid= is empty (EC2 path)"
else
    ko "test-29: expected empty vmid=, got '${_vmid29}'"
fi
if [ -n "$_vmtoken29" ]; then
    ok "test-29: vmtoken on stdout"
else
    ko "test-29: vmtoken missing from stdout"
fi

if [ -f "$AWS_ARGV_FILE" ]; then
    # run-instances must NOT contain --user-data
    if grep "run-instances" "$AWS_ARGV_FILE" | grep -q -- "--user-data"; then
        ko "test-29: run-instances should not carry --user-data (token must travel via SSM)"
    else
        ok "test-29: run-instances carries no --user-data"
    fi

    # send-command must not contain the token value "test-token"
    if grep "send-command" "$AWS_ARGV_FILE" | grep -q "test-token"; then
        ko "test-29: send-command must not contain the raw token value"
    else
        ok "test-29: send-command does not contain the raw token value"
    fi

    # run-instances must carry the vmtoken tag
    if [ -n "$_vmtoken29" ] && grep "run-instances" "$AWS_ARGV_FILE" | grep -q "ephemeral-ci:vmtoken,Value=${_vmtoken29}"; then
        ok "test-29: run-instances carries ephemeral-ci:vmtoken tag matching stdout vmtoken"
    else
        ko "test-29: run-instances missing ephemeral-ci:vmtoken tag (vmtoken=${_vmtoken29}; args: $(grep run-instances "$AWS_ARGV_FILE" || true))"
    fi

    # put-parameter must carry the vmtoken tag
    if [ -n "$_vmtoken29" ] && grep "put-parameter" "$AWS_ARGV_FILE" | grep -q "ephemeral-ci:vmtoken,Value=${_vmtoken29}"; then
        ok "test-29: put-parameter includes ephemeral-ci:vmtoken tag matching stdout vmtoken"
    else
        ko "test-29: put-parameter missing ephemeral-ci:vmtoken tag (vmtoken=${_vmtoken29}; args: $(grep put-parameter "$AWS_ARGV_FILE" || true))"
    fi
else
    ko "test-29: no AWS calls were made on EC2 spill path"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$(( pass + fail ))
echo ""
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ]
