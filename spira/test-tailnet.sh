#!/usr/bin/env bash
# covers: scripts/tailnet.sh
# Delegates to the actual suite in scripts/; the harness runs suites from spira/.
exec bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-tailnet.sh" "$@"
