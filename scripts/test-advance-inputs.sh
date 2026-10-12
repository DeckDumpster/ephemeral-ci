#!/usr/bin/env bash
# covers: scripts/check-advance-inputs.sh
#
# Tests the input-diff check used by advance-v1.yml.
# Positive control: a new required input without a default is refused.
# A new optional input, and a new required input WITH a default, both pass.
#
# The "seen to fail" cases are the refused tests: if the check fails to detect
# a blocking input the test itself fails, so a silent check can never appear
# green here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-advance-inputs.sh"

PASS=0
FAIL=0
_pass() { (( PASS++ )) || true; echo "  PASS: $1"; }
_fail() { (( FAIL++ )) || true; echo "  FAIL: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── V1 baseline ───────────────────────────────────────────────────────────────
cat > "$WORK/v1.yml" <<'YAML'
name: v1 action
inputs:
  existing-required:
    required: true
    description: Already required at v1
  existing-optional:
    required: false
    description: Optional at v1
    default: ''
runs:
  using: composite
  steps: []
YAML

# ── Positive control: new required input without default → must refuse ─────────
cat > "$WORK/cand-new-required.yml" <<'YAML'
name: candidate action
inputs:
  existing-required:
    required: true
    description: Already required at v1
  existing-optional:
    required: false
    description: Optional at v1
    default: ''
  new-blocker:
    required: true
    description: A new required input without a default
runs:
  using: composite
  steps: []
YAML

if ! bash "$CHECK" "$WORK/v1.yml" "$WORK/cand-new-required.yml" 2>/dev/null; then
    _pass "new required input without default is refused"
else
    _fail "new required input without default was not refused"
fi

# ── New optional input → must pass ────────────────────────────────────────────
cat > "$WORK/cand-new-optional.yml" <<'YAML'
name: candidate action
inputs:
  existing-required:
    required: true
    description: Already required at v1
  existing-optional:
    required: false
    description: Optional at v1
    default: ''
  new-optional:
    required: false
    description: A new optional input
    default: ''
runs:
  using: composite
  steps: []
YAML

if bash "$CHECK" "$WORK/v1.yml" "$WORK/cand-new-optional.yml" 2>/dev/null; then
    _pass "new optional input passes"
else
    _fail "new optional input was rejected"
fi

# ── New required input WITH a default → must pass (not breaking) ──────────────
cat > "$WORK/cand-new-required-with-default.yml" <<'YAML'
name: candidate action
inputs:
  existing-required:
    required: true
    description: Already required at v1
  existing-optional:
    required: false
    description: Optional at v1
    default: ''
  new-required-defaulted:
    required: true
    description: Required but has a default — backwards compatible
    default: 'fallback'
runs:
  using: composite
  steps: []
YAML

if bash "$CHECK" "$WORK/v1.yml" "$WORK/cand-new-required-with-default.yml" 2>/dev/null; then
    _pass "new required input with a default passes"
else
    _fail "new required input with a default was rejected"
fi

# ── Unchanged from v1 → must pass ─────────────────────────────────────────────
if bash "$CHECK" "$WORK/v1.yml" "$WORK/v1.yml" 2>/dev/null; then
    _pass "unchanged action passes"
else
    _fail "unchanged action was rejected"
fi


# ── Interface classes beyond new inputs ───────────────────────────────────────
# Each breaking class is a positive control (must be refused); the safe classes
# must pass and say so on stdout.
write_cand() {  # write_cand FILE INPUTS_YAML OUTPUTS_YAML
    printf 'name: candidate action\ninputs:\n%s\noutputs:\n%s\nruns:\n  using: composite\n  steps: []\n' "$2" "$3" > "$1"
}
BASE_IN='  existing-required:
    required: true
  existing-optional:
    required: false
    default: ""'
write_cand "$WORK/base.yml" "$BASE_IN" "  vmid:
    description: id"

expect_refused() {  # expect_refused LABEL FILE PATTERN
    local err
    if err=$(bash "$CHECK" "$WORK/base.yml" "$2" 2>&1 >/dev/null); then
        _fail "$1 was not refused"
    elif grep -q "$3" <<<"$err"; then
        _pass "$1 is refused"
    else
        _fail "$1 refused without naming it: $err"
    fi
}
expect_passes() {  # expect_passes LABEL FILE PATTERN
    local out
    if out=$(bash "$CHECK" "$WORK/base.yml" "$2" 2>/dev/null) && grep -q "$3" <<<"$out"; then
        _pass "$1 passes with a note"
    else
        _fail "$1 did not pass with a note: $out"
    fi
}

write_cand "$WORK/c-rm-in.yml" '  existing-required:
    required: true' "  vmid:
    description: id"
expect_refused "removed input" "$WORK/c-rm-in.yml" "breaking removed input: existing-optional"

write_cand "$WORK/c-rm-out.yml" "$BASE_IN" ""
expect_refused "removed output" "$WORK/c-rm-out.yml" "breaking removed output: vmid"

write_cand "$WORK/c-req.yml" "$BASE_IN
  fresh:
    required: true" "  vmid:
    description: id"
expect_refused "newly required input" "$WORK/c-req.yml" "breaking new required input without default: fresh"

write_cand "$WORK/c-became-req.yml" '  existing-required:
    required: true
  existing-optional:
    required: true' "  vmid:
    description: id"
expect_refused "input turned required" "$WORK/c-became-req.yml" "breaking input became required: existing-optional"

write_cand "$WORK/c-default.yml" '  existing-required:
    required: true
  existing-optional:
    required: false
    default: "changed"' "  vmid:
    description: id"
expect_refused "changed default" "$WORK/c-default.yml" "breaking changed default: existing-optional"

write_cand "$WORK/c-opt-default.yml" "$BASE_IN
  spill-market:
    required: false
    default: on-demand" "  vmid:
    description: id"
expect_passes "new optional input with default" "$WORK/c-opt-default.yml" "safe new optional input: spill-market"

write_cand "$WORK/c-new-out.yml" "$BASE_IN" "  vmid:
    description: id
  fresh-out:
    description: new"
expect_passes "new output" "$WORK/c-new-out.yml" "safe new output: fresh-out"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
