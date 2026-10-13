#!/usr/bin/env bash
# covers: nix/flake.nix
#
# The pinned runner environment, as one tool shared by the image builds and the probe.
#
#   runner-env.sh install      install Nix if absent, build #runner-env, link it at
#                              $RUNNER_ENV_LINK and write the PATH snippet start-runner.sh sources
#   runner-env.sh built-path   the store path the image carries (resolved $RUNNER_ENV_LINK)
#   runner-env.sh expected-path  the store path this checkout's flake evaluates to (no build)
#   runner-env.sh check        built-path must equal expected-path; exit 1 naming both otherwise
#
# The flake is nix/flake.nix in this repository, on the same nixpkgs revision as spira's
# spira-env. The Proxmox template and the spill AMI both run `install` from the same checkout,
# so a drifted image (different podman, different store path) fails `check` rather than a job.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="${RUNNER_ENV_FLAKE_DIR:-$HERE/../nix}"
RUNNER_ENV_LINK="${RUNNER_ENV_LINK:-/opt/ephemeral-ci/runner-env}"
PATH_SNIPPET="${RUNNER_ENV_PATH_SNIPPET:-/etc/ephemeral-ci/runner-env.sh}"
NIX_VERSION="${NIX_VERSION:-2.24.10}"
NIX_PROFILE_SH=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
NIX_FLAGS=(--extra-experimental-features 'nix-command flakes')

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

die() { printf 'runner-env: %s\n' "$*" >&2; exit 1; }

use_nix() {
    # shellcheck disable=SC1090
    command -v nix >/dev/null 2>&1 || { [ -r "$NIX_PROFILE_SH" ] && . "$NIX_PROFILE_SH"; }
    command -v nix >/dev/null 2>&1 || die "nix is not installed"
}

install_nix() {
    command -v nix >/dev/null 2>&1 && return 0
    [ -r "$NIX_PROFILE_SH" ] && return 0
    local d; d="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$d/install" "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" \
        || die "could not download the Nix ${NIX_VERSION} installer"
    sh "$d/install" --daemon --yes || die "Nix installer failed"
    rm -rf "$d"
}

expected_path() {
    use_nix
    nix "${NIX_FLAGS[@]}" eval --raw "path:${FLAKE_DIR}#packages.x86_64-linux.runner-env.outPath"
}

built_path() {
    [ -L "$RUNNER_ENV_LINK" ] || die "$RUNNER_ENV_LINK is not a link; the runner env was never installed"
    readlink -f "$RUNNER_ENV_LINK"
}

case "${1:-}" in
    install)
        install_nix
        use_nix
        want="$(expected_path)"
        $SUDO mkdir -p "$(dirname "$RUNNER_ENV_LINK")" "$(dirname "$PATH_SNIPPET")"
        $SUDO "$(command -v nix)" "${NIX_FLAGS[@]}" build --no-link --out-link "$RUNNER_ENV_LINK" \
            "path:${FLAKE_DIR}#runner-env" >&2 || die "nix build of runner-env failed"
        got="$(built_path)"
        [ "$got" = "$want" ] || die "built $got but the flake evaluates to $want"
        # The env goes FIRST on PATH: its podman must shadow any distro one.
        printf 'export PATH="%s/bin:$PATH"\n' "$RUNNER_ENV_LINK" | $SUDO tee "$PATH_SNIPPET" >/dev/null
        printf 'runner-env: %s\n' "$got" >&2
        ;;
    built-path) built_path ;;
    expected-path) expected_path ;;
    check)
        want="$(expected_path)"; got="$(built_path)"
        [ "$got" = "$want" ] || die "runner env $got is not the lock's $want"
        printf 'runner-env: %s matches the lock\n' "$got" >&2
        ;;
    *) printf 'usage: runner-env.sh install|built-path|expected-path|check\n' >&2; exit 2 ;;
esac
