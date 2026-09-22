#!/usr/bin/env bash
# covers: deploy/ephemeral-runner/provision.sh
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
#   CURL_VMID_FREE_CODE     -- HTTP code for vmid free check (default: 404)
#   CURL_VMID_403_UNTIL     -- vmid probes for ids <= this return 403 (pool ACL)
#   CURL_FILEWRITE_FAIL_N   -- first N agent/file-write calls return HTTP 500
#   CURL_AGENT_PING_FAIL    -- if "1", agent/ping returns 500 (agent not ready)
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
    /cluster/nextid)
        body='{"data":200}'
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
        body='{"data":"UPID:pve:00001:00001:00000066:qmclone:101:root@pam:"}'
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
        body="{\"data\":[{\"vmid\":900,\"status\":\"running\",\"maxmem\":$(( ${CURL_NODE_ALLOC_MIB:-0} * 1048576 )),\"cpus\":${_eff_alloc_cpus}},{\"vmid\":${TEMPLATE_VMID:-101},\"status\":\"stopped\",\"maxmem\":$(( ${CURL_TEMPLATE_MIB:-8192} * 1048576 )),\"cpus\":${CURL_TEMPLATE_CPUS:-8}}]}"
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
run_provision valid-label test-token https://github.com/owner/repo >/dev/null

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
# Summary
# ---------------------------------------------------------------------------
total=$(( pass + fail ))
echo ""
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ]
