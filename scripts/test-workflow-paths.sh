#!/usr/bin/env bash
# covers: .github/workflows/*.yml
#
# Every `bash <path>.sh` a workflow step runs must exist in the tree. A step
# that names a missing script exits 127 and masks what the job found (the spill
# probe's verdict step, sp-vhj1wg). Paths resolve as the step would: under the
# `ephemeral-ci/` checkout prefix or $GITHUB_WORKSPACE, they map to this repo's
# root; a step with a working-directory (a consumer checkout) is skipped, as is
# any path built from an expression.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

python3 - "$REPO_DIR" <<'PY'
import glob, os, re, sys, yaml

root = sys.argv[1]
checked = missing = 0
pat = re.compile(r'''(?:^|[;&|(]\s*|\s)bash\s+(?:-\w+\s+)*["']?([^\s"'|;&)]+\.sh)\b''')

def steps(doc):
    for job in (doc.get('jobs') or {}).values():
        yield from job.get('steps') or []

for wf in sorted(glob.glob(os.path.join(root, '.github/workflows/*.yml'))):
    doc = yaml.safe_load(open(wf))
    for step in steps(doc):
        run = step.get('run')
        if not run or step.get('working-directory'):
            continue
        for m in pat.finditer(run):
            path = m.group(1)
            for prefix in ('$GITHUB_WORKSPACE/', '${GITHUB_WORKSPACE}/'):
                if path.startswith(prefix):
                    path = path[len(prefix):]
            if path.startswith('ephemeral-ci/'):
                path = path[len('ephemeral-ci/'):]
            if '$' in path or '{' in path or path.startswith('/'):
                continue
            checked += 1
            if os.path.isfile(os.path.join(root, path)):
                print(f"  PASS: {os.path.basename(wf)}: bash {path}")
            else:
                missing += 1
                print(f"  FAIL: {os.path.basename(wf)}: step {step.get('name', '?')!r} runs bash {path}, which does not exist")

if checked == 0:
    print("  FAIL: no workflow bash paths found; the lint is blind")
    sys.exit(1)
print(f"{checked} path(s) checked, {missing} missing")
sys.exit(1 if missing else 0)
PY
