#!/usr/bin/env bash
# Proves the apt cache serves a cached package: fetches the same .deb through the
# proxy twice, requires a non-empty identical body, and (when run on the cache host
# with APT_CACHE_DIR) that the file sits in the cache directory.
#   bash scripts/apt-cache/check.sh http://HOST:3142
set -euo pipefail

URL="${1:?usage: check.sh http://host:3142}"
MIRROR="${APT_CACHE_MIRROR:-http://archive.ubuntu.com/ubuntu}"
PKG="${APT_CACHE_PKG:-pool/main/h/hello/hello_2.10-3build1_amd64.deb}"
DIR="${APT_CACHE_DIR:-}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for n in 1 2; do
    curl -fsS --max-time 60 -x "$URL" -o "$tmp/$n.deb" "$MIRROR/$PKG" \
        || { echo "check.sh: fetch $n via $URL failed" >&2; exit 1; }
done
[ -s "$tmp/1.deb" ] || { echo "check.sh: empty body" >&2; exit 1; }
cmp -s "$tmp/1.deb" "$tmp/2.deb" || { echo "check.sh: two fetches differ" >&2; exit 1; }
if [ -n "$DIR" ]; then
    found="$(find "$DIR" -name "$(basename "$PKG")" -size +0 | head -1)"
    [ -n "$found" ] || { echo "check.sh: $(basename "$PKG") not in cache dir $DIR" >&2; exit 1; }
fi
echo "check.sh: ok -- $(basename "$PKG") served twice through $URL"
