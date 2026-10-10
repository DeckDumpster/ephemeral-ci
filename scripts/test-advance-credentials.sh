#!/usr/bin/env bash
# covers: .github/workflows/advance-v1.yml
#
# The "Advance tag" step pushes with V1_TAG_PAT in the remote URL. If the job's
# checkout persisted GITHUB_TOKEN as http.https://github.com/.extraheader, git
# sends that instead and the push is refused across a workflow-file change
# (sp-ku3ugt, run 38074627406). Asserts the job that holds the push step checks
# out with persist-credentials: false and that the step clears the header.
# The negative control feeds the checker the broken shape and requires refusal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${1:-$SCRIPT_DIR/../.github/workflows/advance-v1.yml}"

# check <workflow>: the job containing "name: Advance tag" must have a checkout
# step with persist-credentials: false, and the step must unset the extraheader.
check() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
jobs = re.split(r'\n  (?=[A-Za-z0-9_-]+:\n)', text.split('\njobs:\n', 1)[1])
job = next((j for j in jobs if 'name: Advance tag' in j), None)
if job is None:
    sys.exit('no job contains the Advance tag step')
steps = re.split(r'\n      - ', job)
checkouts = [s for s in steps if s.startswith('uses: actions/checkout')]
if not checkouts:
    sys.exit('advance job has no checkout step')
for c in checkouts:
    if not re.search(r'persist-credentials:\s*false', c):
        sys.exit('advance job checkout persists credentials')
adv = next(s for s in steps if s.startswith('name: Advance tag'))
if 'unset-all http.https://github.com/.extraheader' not in adv:
    sys.exit('Advance tag step does not clear the extraheader')
PY
}

FAIL=0
if check "$WF"; then echo "  PASS: advance job does not persist credentials"
else echo "  FAIL: advance workflow"; FAIL=1; fi

BAD="$(mktemp)"; trap 'rm -f "$BAD"' EXIT
sed '/persist-credentials: false/d' "$WF" > "$BAD"
if check "$BAD" 2>/dev/null; then echo "  FAIL: checker accepted a persisting checkout"; FAIL=1
else echo "  PASS: checker refuses a persisting checkout"; fi

exit "$FAIL"
