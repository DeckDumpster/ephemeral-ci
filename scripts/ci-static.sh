#!/usr/bin/env bash
# Static repository checks, in one place so CI, `work checks` and the testenv
# `static` tier run the same thing (sp-4rim2v).
#
#   ci-static.sh [--root <dir>] [--full]
#
# Default: script mode consistency and gate-scripts-present, needing only bash
# and find, reporting every failure. --full adds shellcheck and the two
# composite-action parses (CI installs shellcheck and has python3).
set -u

root=.
full=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="${2:?--root needs a directory}"; shift 2 ;;
    --full) full=1; shift ;;
    *) echo "usage: ci-static.sh [--root <dir>] [--full]" >&2; exit 2 ;;
  esac
done
cd "$root" || { echo "ci-static: cannot enter $root" >&2; exit 2; }

fail=0
bad() { echo "$1"; fail=1; }

# A .sh with a shebang but no execute bit cannot be run by an operator without
# an explicit `bash` prefix; an executable .sh without a shebang is rejected by
# the OS at exec. The shebang test requires a `/` after `#!` so that
# inline-block markers like `#!maxpar-begin` are not mistaken for interpreters.
while IFS= read -r path; do
  path=${path#./}
  first=
  IFS= read -r first < "$path" || true
  shebang=0
  case "$first" in '#!'*/*) shebang=1 ;; esac
  if [ -x "$path" ]; then
    [ "$shebang" = 1 ] || bad "executable but no shebang: $path"
  else
    [ "$shebang" = 0 ] || bad "has shebang but not executable: $path"
  fi
done < <(find . \( -name .git -o -name .runtime -o -name target -o -name node_modules \) -prune \
  -o -type f -name '*.sh' -print | sort)

# The spira gate command (repo-map) names the same scripts CI runs. A clause
# naming a script that does not exist would block every branch at gate time
# with NO_VERDICT (scar: sp-h08ym).
for script in \
    scripts/test-provision.sh \
    scripts/test-teardown.sh \
    scripts/test-reap.sh \
    scripts/test-template-substrate.sh \
    scripts/test-advance-inputs.sh \
    scripts/test-advance-credentials.sh \
    scripts/test-check-ami-for-ref.sh \
    scripts/test-ami-build.sh \
    scripts/test-spill-params.sh \
    scripts/test-spill-probe.sh \
    scripts/test-spill-probe-first-test.sh \
    scripts/test-tailnet.sh \
    scripts/test-warm-cache.sh \
    scripts/test-workflow-paths.sh; do
  [ -f "$script" ] || bad "gate command references $script but it is missing"
done

if [ "$full" = 1 ]; then
  # The exclusions are named individually, never widened to "all warnings".
  #   SC1091, SC1090  sourced paths are resolved at runtime on the hypervisor.
  #   SC2034          pvapi.sh sets PVAPI_STATUS and PVAPI_BODY for its callers.
  #   SC2015          `a && b || c` is a deliberate idiom throughout.
  #   SC2016          command strings for remote execution (SSH, SSM) need the
  #                   $ unexpanded, so single quotes are the required spelling.
  shellcheck -e SC1091,SC1090,SC2034,SC2015,SC2016 scripts/*.sh scripts/guest/*.sh || fail=1

  # A malformed composite action fails in the consumer's run, naming this
  # repository; parse them here, where the break is made. Checks `runs.using`,
  # a shell on every `run` step, and that declared and used inputs agree.
  python3 - <<'PY' || fail=1
import sys, re, yaml, pathlib
bad = 0
for f in sorted(pathlib.Path(".").glob("*/action.yml")):
    text = f.read_text()
    d = yaml.safe_load(text)
    runs = d.get("runs", {})
    if runs.get("using") != "composite":
        print(f"{f}: runs.using is {runs.get('using')!r}, expected 'composite'"); bad += 1
    for i, step in enumerate(runs.get("steps", [])):
        if "run" in step and "shell" not in step:
            print(f"{f}: step {i} ({step.get('name','?')}) has `run` with no `shell`"); bad += 1
    declared = set(d.get("inputs", {}) or {})
    used = set(re.findall(r"inputs\.([a-zA-Z0-9_-]+)", text))
    for x in sorted(declared - used):
        print(f"{f}: input '{x}' is declared but never used"); bad += 1
    # The three characters "$" "{" "{" MUST NOT appear adjacent in an action's
    # run: block (GitHub lexes it as an expression and the workflow becomes a
    # startup_failure), so the sequence is assembled from pieces here.
    expr = "$" + "{{ inputs.%s }}"
    for x in sorted(used - declared):
        print(f"{f}: '{expr % x}' is used but never declared"); bad += 1
sys.exit(1 if bad else 0)
PY
fi

exit "$fail"
