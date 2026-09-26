#!/usr/bin/env bash
# covers: provision/action.yml teardown/action.yml scripts/teardown.sh
#
# Static contract check: verifies that the provision/teardown action pair is
# internally consistent. No hypervisor required; reads only YAML and shell files.
#
# Checks:
#   1. Every env var that teardown.sh requires (via _require_env) is set in the
#      teardown action's "Destroy the runner VM" step env.
#   2. provision/action.yml declares vm-token as an output.
#   3. teardown/action.yml declares vm-token as an input.
#   4. The teardown action's "Destroy the runner VM" step sets VM_TOKEN from
#      inputs.vm-token.
#
# A failure here means the action contract is broken: teardown.sh will exit
# non-zero before its first API call, and every teardown via the action will
# silently leave the VM running until the reaper claims it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
_pass() { (( PASS++ )) || true; echo "  PASS: $1"; }
_fail() { (( FAIL++ )) || true; echo "  FAIL: $1"; }

# --- Check 1: every _require_env variable in teardown.sh is set in the action ---

# Extract variable names from teardown.sh. Two patterns are used:
#   a) for _v in VAR1 VAR2 ...; do _require_env "$_v"; done
#   b) _require_env "VARNAME"   (direct literal call)
REQUIRED_VARS=$(TEARDOWN_SH="$SCRIPT_DIR/teardown.sh" python3 - <<'PY'
import os, re

with open(os.environ['TEARDOWN_SH']) as f:
    content = f.read()

found = set()

# Pattern a: for-loop that calls _require_env "$_v" — extract the loop variable list.
# Handles the common for _v in VAR1 VAR2 ...; do\n    _require_env "$_v"\ndone shape.
for_re = re.compile(
    r'for\s+\w+\s+in\s+([^;]+);\s*do\b.*?_require_env',
    re.DOTALL,
)
for m in for_re.finditer(content):
    for tok in m.group(1).split():
        if re.match(r'^[A-Z][A-Z0-9_]*$', tok):
            found.add(tok)

# Pattern b: direct literal calls.
for m in re.finditer(r'_require_env\s+"([A-Z][A-Z0-9_]*)"', content):
    found.add(m.group(1))

print('\n'.join(sorted(found)))
PY
)

# Extract env var names from the "Destroy the runner VM" step in teardown/action.yml.
DESTROY_ENV=$(python3 - <<PY
import sys, yaml
with open("$REPO_DIR/teardown/action.yml") as f:
    action = yaml.safe_load(f)
for step in (action.get("runs") or {}).get("steps") or []:
    if (step.get("name") or "") == "Destroy the runner VM":
        for k in (step.get("env") or {}):
            print(k)
        break
PY
)

for var in $REQUIRED_VARS; do
    if printf '%s\n' "$DESTROY_ENV" | grep -qx "$var"; then
        _pass "teardown action Destroy step sets \$${var} (required by teardown.sh)"
    else
        _fail "teardown action Destroy step does NOT set \$${var} (required by teardown.sh)"
    fi
done

if [ -z "$REQUIRED_VARS" ]; then
    _pass "teardown.sh has no _require_env calls (nothing to check)"
fi

# --- Check 2: provision/action.yml declares vm-token output ---

PROVISION_OUTPUTS=$(python3 - <<PY
import sys, yaml
with open("$REPO_DIR/provision/action.yml") as f:
    action = yaml.safe_load(f)
for k in (action.get("outputs") or {}):
    print(k)
PY
)

if printf '%s\n' "$PROVISION_OUTPUTS" | grep -qx "vm-token"; then
    _pass "provision/action.yml declares vm-token output"
else
    _fail "provision/action.yml does NOT declare vm-token output"
fi

# --- Check 3: teardown/action.yml declares vm-token input ---

TEARDOWN_INPUTS=$(python3 - <<PY
import sys, yaml
with open("$REPO_DIR/teardown/action.yml") as f:
    action = yaml.safe_load(f)
for k in (action.get("inputs") or {}):
    print(k)
PY
)

if printf '%s\n' "$TEARDOWN_INPUTS" | grep -qx "vm-token"; then
    _pass "teardown/action.yml declares vm-token input"
else
    _fail "teardown/action.yml does NOT declare vm-token input"
fi

# --- Check 4: teardown Destroy step wires VM_TOKEN from inputs.vm-token ---

VM_TOKEN_VALUE=$(python3 - <<PY
import sys, yaml
with open("$REPO_DIR/teardown/action.yml") as f:
    action = yaml.safe_load(f)
for step in (action.get("runs") or {}).get("steps") or []:
    if (step.get("name") or "") == "Destroy the runner VM":
        env = step.get("env") or {}
        print(env.get("VM_TOKEN", ""))
        break
PY
)

if [ "$VM_TOKEN_VALUE" = "\${{ inputs.vm-token }}" ]; then
    _pass "teardown Destroy step sets VM_TOKEN from inputs.vm-token"
else
    _fail "teardown Destroy step VM_TOKEN value is '${VM_TOKEN_VALUE}', expected '\${{ inputs.vm-token }}'"
fi

# --- Check 5: teardown/action.yml declares template-vmid input (db-b2gh) ---
# Without the input declaration GitHub supplies nothing; TEMPLATE_VMID is unset;
# teardown.sh's _require_env exits non-zero before the first API call, and every
# VM leaks until the reaper picks it up.

if printf '%s\n' "$TEARDOWN_INPUTS" | grep -qx "template-vmid"; then
    _pass "teardown/action.yml declares template-vmid input"
else
    _fail "teardown/action.yml does NOT declare template-vmid input"
fi

# --- Check 6: teardown Destroy step wires TEMPLATE_VMID from inputs.template-vmid ---

TEMPLATE_VMID_VALUE=$(python3 - <<PY
import sys, yaml
with open("$REPO_DIR/teardown/action.yml") as f:
    action = yaml.safe_load(f)
for step in (action.get("runs") or {}).get("steps") or []:
    if (step.get("name") or "") == "Destroy the runner VM":
        env = step.get("env") or {}
        print(env.get("TEMPLATE_VMID", ""))
        break
PY
)

if [ "$TEMPLATE_VMID_VALUE" = "\${{ inputs.template-vmid }}" ]; then
    _pass "teardown Destroy step sets TEMPLATE_VMID from inputs.template-vmid"
else
    _fail "teardown Destroy step TEMPLATE_VMID value is '${TEMPLATE_VMID_VALUE}', expected '\${{ inputs.template-vmid }}'"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
