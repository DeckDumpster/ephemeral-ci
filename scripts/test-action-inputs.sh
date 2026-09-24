#!/usr/bin/env bash
# covers: scripts/check-action-inputs.sh teardown/action.yml
#
# Verifies that check-action-inputs.sh catches missing required inputs and
# passes complete consumer workflows. Uses both synthetic fixtures and the
# real teardown/action.yml so the test covers the actual bug vector: a
# consumer calling teardown without template-vmid.
#
# The "seen to fail" cases (law-a-regression-test-must-be-seen-to-fail) are
# the bad-workflow tests: the check MUST exit non-zero for those to pass.
# If the check fails to detect the missing input, the test itself fails, so
# a silent check can never appear green here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CHECK="$SCRIPT_DIR/check-action-inputs.sh"

PASS=0
FAIL=0
_pass() { (( PASS++ )) || true; echo "  PASS: $1"; }
_fail() { (( FAIL++ )) || true; echo "  FAIL: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Synthetic fixtures ────────────────────────────────────────────────────
# An action with two required and one optional input.

mkdir -p "$WORK/my-action"
cat > "$WORK/my-action/action.yml" <<'YAML'
name: Synthetic test action
runs:
  using: composite
  steps: []
inputs:
  required-a:
    required: true
    description: First required input
  required-b:
    required: true
    description: Second required input
  optional-c:
    required: false
    description: Optional input
    default: ''
YAML

# Consumer missing required-b — check must exit non-zero.
cat > "$WORK/workflow-missing-b.yml" <<'YAML'
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - name: Call the action
        uses: ./my-action
        with:
          required-a: value-a
YAML

# Consumer with all required inputs — check must exit zero.
cat > "$WORK/workflow-complete.yml" <<'YAML'
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - name: Call the action
        uses: ./my-action
        with:
          required-a: value-a
          required-b: value-b
YAML

# Consumer that does not call this action at all — trivially passes.
cat > "$WORK/workflow-unrelated.yml" <<'YAML'
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - name: Other action
        uses: ./other-action
        with:
          something: value
YAML

if ! bash "$CHECK" "$WORK/my-action/action.yml" "$WORK/workflow-missing-b.yml" 2>/dev/null; then
    _pass "synthetic: missing required-b detected"
else
    _fail "synthetic: check passed a workflow missing required-b"
fi

if bash "$CHECK" "$WORK/my-action/action.yml" "$WORK/workflow-complete.yml" 2>/dev/null; then
    _pass "synthetic: complete workflow passes"
else
    _fail "synthetic: check rejected a complete workflow"
fi

if bash "$CHECK" "$WORK/my-action/action.yml" "$WORK/workflow-unrelated.yml" 2>/dev/null; then
    _pass "synthetic: unrelated workflow passes (no matching step)"
else
    _fail "synthetic: check rejected a workflow that does not call the action"
fi

# ── Real teardown/action.yml: the sp-q1sp3 bug vector ────────────────────
# Reproduces the exact condition from the incident: a workflow that calls
# teardown without template-vmid. On v1 (b39ea402) teardown.sh defaulted
# TEMPLATE_VMID to 101; Guard 2 then refused to destroy any VM cloned onto
# VMID 101. Here the check catches the missing input before it reaches a runner.

cat > "$WORK/workflow-teardown-no-template-vmid.yml" <<'YAML'
jobs:
  teardown:
    runs-on: ubuntu-latest
    steps:
      - name: Destroy runner
        uses: ./teardown
        with:
          vmid: "101"
          ts-oauth-client-id: tsid
          ts-oauth-secret: tssecret
          pve-token-id: tokenid
          pve-token-secret: tokensecret
          pve-api-host: 10.0.0.1
          pve-node: pve
          pve-ca-cert: CERTDATA
YAML

# Must detect missing template-vmid.
if ! bash "$CHECK" "$REPO_DIR/teardown/action.yml" \
       "$WORK/workflow-teardown-no-template-vmid.yml" 2>/dev/null; then
    _pass "teardown: missing template-vmid detected"
else
    _fail "teardown: check passed a workflow missing template-vmid"
fi

# The fixed workflow — all required inputs present.
cat > "$WORK/workflow-teardown-complete.yml" <<'YAML'
jobs:
  teardown:
    runs-on: ubuntu-latest
    steps:
      - name: Destroy runner
        uses: ./teardown
        with:
          vmid: "101"
          ts-oauth-client-id: tsid
          ts-oauth-secret: tssecret
          pve-token-id: tokenid
          pve-token-secret: tokensecret
          pve-api-host: 10.0.0.1
          pve-node: pve
          pve-ca-cert: CERTDATA
          template-vmid: "107"
YAML

if bash "$CHECK" "$REPO_DIR/teardown/action.yml" \
       "$WORK/workflow-teardown-complete.yml" 2>/dev/null; then
    _pass "teardown: complete workflow passes"
else
    _fail "teardown: check rejected a complete teardown workflow"
fi

# External-action reference (org/repo/teardown@v1) is also matched.
cat > "$WORK/workflow-teardown-external.yml" <<'YAML'
jobs:
  teardown:
    runs-on: ubuntu-latest
    steps:
      - name: Destroy runner
        uses: DeckDumpster/ephemeral-ci/teardown@v1
        with:
          vmid: "101"
          ts-oauth-client-id: tsid
          ts-oauth-secret: tssecret
          pve-token-id: tokenid
          pve-token-secret: tokensecret
          pve-api-host: 10.0.0.1
          pve-node: pve
          pve-ca-cert: CERTDATA
          template-vmid: "107"
YAML

if bash "$CHECK" "$REPO_DIR/teardown/action.yml" \
       "$WORK/workflow-teardown-external.yml" 2>/dev/null; then
    _pass "teardown: external reference (org/repo/teardown@v1) passes"
else
    _fail "teardown: check rejected a complete external-reference workflow"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
