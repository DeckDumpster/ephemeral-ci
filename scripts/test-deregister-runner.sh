#!/usr/bin/env bash
# covers: scripts/deregister-runner.sh teardown/action.yml
#
# Cross-job cancel (sp-o6zz16): one job's teardown must never delete the
# registration of a runner that is busy running another job's gate, because
# deleting a busy runner cancels its job. gh is stubbed with an org runner list
# holding a busy runner (a "60-minute gate" in flight) beside the stale one the
# teardown targets; the busy runner must survive every teardown.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEREG="$SCRIPT_DIR/deregister-runner.sh"
ACTION="$SCRIPT_DIR/../teardown/action.yml"
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
ko() { echo "FAIL: $1"; fail=$((fail+1)); }

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
export CALLS="$SCRATCH/calls"
cat > "$SCRATCH/gh" <<'STUB'
#!/usr/bin/env python3
import json, os, re, subprocess, sys
a = sys.argv[1:]
open(os.environ["CALLS"], "a").write(" ".join(a) + "\n")
runners = [
    {"id": 11, "name": "ci-pokedumpster-100-1", "busy": True},
    {"id": 12, "name": "ci-deckdumpster-200-1", "busy": False},
    {"id": 13, "name": "ci-ephemeral-ci-300-1", "busy": False},
]
if "-X" in a:
    sys.exit(0)
jq = a[a.index("--jq") + 1]
p = subprocess.run(["jq", "-r", jq], input=json.dumps({"runners": runners}),
                   capture_output=True, text=True)
sys.stdout.write(p.stdout)
STUB
chmod +x "$SCRATCH/gh"
export PATH="$SCRATCH:$PATH"

run() { : > "$CALLS"; bash "$DEREG" acme "$1" 2>&1; }

out=$(run ci-pokedumpster-100-1)
if ! grep -q -- '-X DELETE' "$CALLS" && grep -q 'NOT removing' <<<"$out"; then
    ok "busy runner survives another job's teardown"
else ko "busy runner was deleted or not reported: $out"; fi

out=$(run ci-deckdumpster-200-1)
if grep -q -- '-X DELETE orgs/acme/actions/runners/12$' "$CALLS"; then
    ok "idle stale registration is removed"
else ko "idle registration not deleted: $out"; fi
if ! grep -q 'runners/11\|runners/13' "$CALLS"; then
    ok "only the named runner is deleted"
else ko "a different runner was deleted"; fi

out=$(run ci-gone-1-1)
if ! grep -q -- '-X DELETE' "$CALLS" && grep -q 'deregistered itself' <<<"$out"; then
    ok "absent registration is a no-op"
else ko "absent registration mishandled: $out"; fi

# The action must go through the script, not a bare DELETE.
if grep -q 'deregister-runner.sh' "$ACTION" && ! grep -q -- '-X DELETE' "$ACTION"; then
    ok "teardown action routes registration removal through the busy guard"
else ko "teardown action still deletes registrations directly"; fi

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
