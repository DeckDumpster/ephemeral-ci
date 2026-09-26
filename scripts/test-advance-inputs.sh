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

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
