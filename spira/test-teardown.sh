#!/usr/bin/env bash
# covers: scripts/teardown.sh
# Delegates to the actual suite in scripts/; the harness runs suites from spira/.
exec bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/test-teardown.sh" "$@"
