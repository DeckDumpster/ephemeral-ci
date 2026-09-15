#!/usr/bin/env bash
#
# Proxmox HTTP API wrapper — sourced by scripts in this directory.
#
# Provides pvapi(), which makes a single authenticated request.
# After each call:
#   PVAPI_STATUS — HTTP status code (empty on curl transport error)
#   PVAPI_BODY   — response body (empty on curl transport error)
#
# A connection error (curl exit ≠ 0) returns that exit code and leaves both
# globals empty. Callers must distinguish a curl failure from a 4xx response:
# curl failing means the API was not reached at all, which is not the same as
# "VM not found" (404). Never treat a connection failure as a 404.
#
# Both globals are reset at the start of every call so a stale value from a
# prior call is never read as the current one.
#
# Required environment variables (caller's responsibility):
#   PVE_TOKEN_ID     — Proxmox API token id (user@realm!tokenname)
#   PVE_TOKEN_SECRET — Proxmox API token secret
#
# Optional environment variables (have defaults):
#   PVE_API_HOST — Proxmox hostname or IP (default: localhost)
#   PVE_API_PORT — Proxmox API port (default: 8006)
#
# Transport notes:
#   -k/--insecure: the Proxmox API on a loopback address ships with a
#       self-signed certificate; the token carries the credential, not TLS
#       chain trust. Do not copy this flag to a call that goes over the
#       network.
#   -sS: -s suppresses the progress meter; -S restores curl's transport-error
#       messages to stderr. Never use -s alone — connection refused, TLS
#       failure, and a malformed URL from an unset variable all produce empty
#       output with no indication of cause.
#   Never -f/--fail: it discards the response body on HTTP >=400. The Proxmox
#       API returns its error reason in that body; discarding it makes every
#       auth and validation failure arrive as a bare exit code with nothing to
#       act on.
#
# Usage: pvapi <METHOD> <path> [extra-curl-args...]
#
# Extra curl arguments (e.g. --data-urlencode, -H) are passed through after
# the path.

PVAPI_STATUS=""
PVAPI_BODY=""

pvapi() {
    local method="$1" path="$2"
    shift 2
    PVAPI_STATUS=""
    PVAPI_BODY=""
    local _tmpfile _status _rc=0
    _tmpfile=$(mktemp)
    _status=$(curl -sS --insecure \
        -o "$_tmpfile" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
        "https://${PVE_API_HOST:-localhost}:${PVE_API_PORT:-8006}/api2/json${path}" \
        "$@") || _rc=$?
    PVAPI_STATUS="$_status"
    PVAPI_BODY=$(cat "$_tmpfile")
    rm -f "$_tmpfile"
    return "$_rc"
}
