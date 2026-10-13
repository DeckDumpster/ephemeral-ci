#!/usr/bin/env bash
# advance-v1.yml's dispatch must offer only v2 and default to it: no consumer
# pins v1, so a hand dispatch that defaults there moves a tag nobody reads
# (sp-burbrw).
set -euo pipefail

wf="$(dirname "$0")/../.github/workflows/advance-v1.yml"
block=$(awk '/^      tag:$/{f=1;next} f&&/^      [a-z-]+:$/{exit} f' "$wf")

fail=0
grep -qE '^        options: \[v2\]$' <<<"$block" \
  || { echo "FAIL: tag input must offer only v2"; fail=1; }
grep -qE '^        default: v2$' <<<"$block" \
  || { echo "FAIL: tag input must default to v2"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: tag input offers only v2 and defaults to it"
exit "$fail"
