#!/usr/bin/env bash
# covers: scripts/runner-state.sh
#
# What GitHub says about one org runner right now (sp-ptyk2g). Sourced by
# teardown.sh so the instance-end line can say whether the instance's runner
# ever registered, and whether it was online when the instance went.
#
#   rs_query <org> <runner-name>
# sets, and never fails:
#   RS_STATE       online | offline | absent | unknown
#   RS_BUSY        true | false | null
#   RS_CHECKED_AT  UTC stamp of the query
#   RS_ERROR       why RS_STATE is unknown, else empty
# Needs GH_TOKEN in the environment. One list call, exact name match.

rs_query() {
    local org="${1:-}" name="${2:-}" out rec
    RS_STATE=unknown RS_BUSY=null RS_ERROR="" RS_CHECKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -z "$org" ]; then RS_ERROR="RUNNER_ORG is not set"; return 0; fi
    if [ -z "$name" ]; then RS_ERROR="runner name is empty"; return 0; fi
    if ! out="$(timeout 20 gh api "orgs/${org}/actions/runners" --paginate 2>&1)"; then
        RS_ERROR="gh api failed: $(printf '%s' "$out" | head -c 300 | tr '\n' ' ')"
        return 0
    fi
    # --paginate prints one JSON document per page; slurp them.
    if ! rec="$(printf '%s' "$out" | jq -c -s --arg n "$name" \
            '[.[].runners[]? | select(.name == $n)] | first // null' 2>&1)"; then
        RS_ERROR="unparseable runner list: $(printf '%s' "$rec" | head -c 200 | tr '\n' ' ')"
        return 0
    fi
    if [ "$rec" = "null" ]; then RS_STATE=absent; return 0; fi
    RS_STATE="$(printf '%s' "$rec" | jq -r '.status // "unknown"')"
    case "$RS_STATE" in online|offline) ;; *) RS_STATE=unknown RS_ERROR="unrecognised runner status" ;; esac
    RS_BUSY="$(printf '%s' "$rec" | jq -c '.busy // false')"
    return 0
}
