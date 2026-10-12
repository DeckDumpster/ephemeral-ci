#!/usr/bin/env bash
#
# scripts/spill-probe-spira.sh <spira-checkout>
#
# Spira's own first-test path, the one its gate.yml suites job takes, run on the
# spilled runner: fetch the newest published release (it carries testenv and the
# other binaries, so the probe needs no Rust toolchain), stage it, acquire the
# test image, then hand one suite to testenv. testenv's own "running N suite(s)"
# line is the started-marker; spill-probe-first-test.sh watches for it and stops
# this script, so the suite itself never needs to finish.
#
# Needs in the environment: GH_TOKEN (read access to the spira repo and its
# packages), GITHUB_REPOSITORY, RUNNER_TEMP, GITHUB_ACTOR (registry login).
set -euo pipefail

checkout="${1:?usage: spill-probe-spira.sh <spira-checkout>}"
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}" "${RUNNER_TEMP:?}"
owner="${GITHUB_REPOSITORY%%/*}"
suite="${SPILL_PROBE_SPIRA_SUITE:-test-cadence-tool.sh}"

dl="$(mktemp -d "$RUNNER_TEMP/spira-release-dl.XXXXXX")"
rel="$RUNNER_TEMP/spira-release"
rm -rf "$rel"; mkdir -p "$rel"

echo "==> fetch the newest published spira release"
gh release download --repo "$owner/spira" --pattern 'spira-*.tar.gz' --dir "$dl"
tar -xzf "$dl"/spira-*.tar.gz -C "$rel" --strip-components=1
test -x "$rel/bin/testenv" || { echo "ERROR: the release carries no executable bin/testenv" >&2; exit 1; }

echo "==> stage it"
export SPIRA_RELEASE="$rel" SPIRA_REPO="$checkout"
export PATH="$rel/bin:$rel/spira:/usr/local/bin:/usr/bin:/bin:$PATH"
bash "$checkout/spira/ci-config.sh" "$checkout"
export SPIRA_TOML="$RUNNER_TEMP/ci-config.toml"
lower_owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
export SPIRA_TESTENV_REGISTRY="ghcr.io/$lower_owner"

echo "==> log in to the registry"
# A failed login only costs a cache miss: testenv builds the image instead.
printf '%s' "$GH_TOKEN" | podman login ghcr.io -u "${GITHUB_ACTOR:-$owner}" --password-stdin \
    || echo "WARN: registry login failed; testenv will build the image"

echo "==> acquire the test image"
testenv container image

echo "==> start the first suite"
testenv --artifacts "$rel/bin" --suites "$suite" "$(git -C "$checkout" rev-parse HEAD)"
