#!/usr/bin/env bash
# covers: docs/TEMPLATE.md (the "Warm caches" section)
#
# Bakes each consumer's own warm state into the runner image, so a job starts with its
# toolchain, registry, deps-only target dir, builder-image layers and runner deps already
# on disk instead of compiling them from zero on a VM that is destroyed afterwards (sp-tu41vm).
#
#   warm-cache.sh [--manifest FILE] bake       run on the AMI builder, as the runner user
#   warm-cache.sh [--manifest FILE] lock-sha   print the hash of every input a bake depends on
#
# WHAT IS RUN IS THE CONSUMER'S DECLARATION, in warm/consumers.json: its own runner-deps.sh
# (so its apt/node/rustup list is never copied here), then the same cargo/podman/npm commands
# its CI runs, with the same CARGO_TARGET_DIR its ci.sh defaults to. This script changes what
# is already on disk, never what CI runs. A consumer tool still does not belong in the
# substrate (docs/TEMPLATE.md): the bake runs the consumer's own scripts at build time.
#
# FAIL CLOSED. A step that fails fails the bake and the AMI build; a half-warm image that
# looks warm is the failure this exists to prevent. The one exception is a step declared
# {"run": ..., "optional": true}: it needs something the AMI builder cannot always reach (the
# tailnet Cargo registry, sp-7c7zgx). Its failure warns, and the consumer's remaining optional
# steps are skipped, so a registry outage never stops an AMI build; what was not warmed is
# fetched at job time on the tailnet-joined runner. Mandatory steps still fail the bake.
#
# REFRESH. lock-sha hashes the manifest and every lockfile the manifest names, as they are at
# each consumer's ref. ami-build.sh tags it on the image as warm-lock-sha; the warm-refresh
# workflow rebuilds when the tag no longer matches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../warm/consumers.json"

note() { printf 'warm-cache: %s\n' "$*" >&2; }
die()  { printf 'warm-cache: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --manifest) MANIFEST="$2"; shift 2 ;;
        *) break ;;
    esac
done
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
CMD="${1:-}"

raw_url() { # <repo-url> <ref> <path>
    local u="${1%.git}"
    printf '%s/%s/%s' "${u/github.com/raw.githubusercontent.com}" "$2" "$3"
}

lock_sha() {
    local name repo ref f
    {
        cat "$MANIFEST"
        while IFS=$'\t' read -r name repo ref f; do
            printf '%s:%s\n' "$name" "$f"
            curl -fsSL "$(raw_url "$repo" "$ref" "$f")" || die "cannot fetch $f of $name at $ref"
        done < <(jq -r '.consumers[] | . as $c | $c.lockfiles[] | [$c.name, $c.repo, $c.ref, .] | @tsv' "$MANIFEST")
    } | sha256sum | cut -d' ' -f1
}

bake() {
    local dir n i name repo ref s e k v s0
    dir="$(jq -r '.dir' "$MANIFEST")"
    sudo install -d -o "$(id -u)" "$dir"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    n="$(jq '.consumers | length' "$MANIFEST")"
    [ "$n" -gt 0 ] || die "manifest names no consumers"
    for i in $(seq 0 $((n - 1))); do
        name="$(jq -r ".consumers[$i].name" "$MANIFEST")"
        [ -n "$name" ] && [ "$name" != null ] || die "consumer $i has no name"
        repo="$(jq -r ".consumers[$i].repo" "$MANIFEST")"
        ref="$(jq -r ".consumers[$i].ref" "$MANIFEST")"
        note "== $name ($repo @ $ref)"
        git clone --quiet --depth 1 --branch "$ref" "$repo" "$work/$name"
        (
            cd "$work/$name"
            export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
            while IFS=$'\t' read -r k v; do
                [ -n "$k" ] || continue
                export "$k=$(eval "printf '%s' \"$v\"")"
            done < <(jq -r ".consumers[$i].env // {} | to_entries[] | [.key, .value] | @tsv" "$MANIFEST")
            skipped=""
            while IFS=$'\t' read -r opt s; do
                if [ "$opt" = true ] && [ -n "$skipped" ]; then
                    note "[$name] skipped (an earlier optional step failed): $s"
                    continue
                fi
                note "[$name] $s"
                s0=$SECONDS
                if bash -c "$s"; then
                    note "[$name] took $((SECONDS - s0))s"
                elif [ "$opt" = true ]; then
                    note "WARNING [$name] optional step failed, image stays cold for it: $s"
                    skipped=1
                else
                    die "[$name] step failed: $s"
                fi
            done < <(jq -r ".consumers[$i].steps[] | if type == \"string\" then [\"false\", .] else [(.optional // false | tostring), .run] end | @tsv" "$MANIFEST")
        )
        e="$(git -C "$work/$name" rev-parse HEAD)"
        printf '%s %s\n' "$name" "$e" >> "$work/baked"
        rm -rf "${work:?}/${name:?}"
    done
    { cat "$work/baked"; printf 'lock-sha %s\n' "$(lock_sha)"; } > "$dir/BAKED"
    note "baked: $(tr '\n' ';' < "$dir/BAKED")"
}

case "$CMD" in
    bake)     bake ;;
    lock-sha) lock_sha ;;
    *) printf 'usage: warm-cache.sh [--manifest FILE] bake|lock-sha\n' >&2; exit 2 ;;
esac
