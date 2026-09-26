# shellcheck shell=bash
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
#   PVE_API_HOST     — Proxmox IP or hostname to connect to (default: localhost)
#   PVE_API_PORT     — Proxmox API port (default: 8006)
#   PVE_API_HOSTNAME — Hostname as it appears in the Proxmox TLS certificate.
#                      When set, pvapi() uses this name in the HTTPS URL and
#                      adds --resolve <hostname>:<port>:<PVE_API_HOST> so curl
#                      connects to PVE_API_HOST (e.g. a tailnet IP) but
#                      validates the certificate against PVE_API_HOSTNAME.
#                      Required when PVE_API_HOST is an IP address and the
#                      Proxmox certificate carries no SAN for that address —
#                      the certificate is issued for the node name, not the IP.
#                      On-node callers that leave PVE_API_HOST at the default
#                      (localhost) need not set this.
#   PVE_CA_CERT_FILE — path to the Proxmox cluster CA certificate (PEM).
#                      Defaults to /etc/pve/pve-root-ca.pem, which exists on
#                      the hypervisor itself. Callers running off-node (e.g. a
#                      GitHub-hosted runner) must set this to a temp file
#                      written from a repository variable (vars.PVE_CA_CERT).
#                      If the file does not exist curl exits 77; that is the
#                      intended loud failure — do not fall back to --insecure.
#
# Transport notes:
#   --cacert: TLS verification uses the cluster CA. The token authenticates
#       the caller; TLS verification authenticates the server the token is
#       sent to. Neither can substitute for the other.
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
    local _port="${PVE_API_PORT:-8006}"
    local _host="${PVE_API_HOST:-localhost}"
    local _url_host="$_host"
    local _resolve_args=()
    if [ -n "${PVE_API_HOSTNAME:-}" ]; then
        _url_host="$PVE_API_HOSTNAME"
        _resolve_args=(--resolve "${PVE_API_HOSTNAME}:${_port}:${_host}")
    fi
    _tmpfile=$(mktemp)
    _status=$(curl -sS \
        --cacert "${PVE_CA_CERT_FILE:-/etc/pve/pve-root-ca.pem}" \
        ${_resolve_args[@]+"${_resolve_args[@]}"} \
        -o "$_tmpfile" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
        "https://${_url_host}:${_port}/api2/json${path}" \
        "$@") || _rc=$?
    PVAPI_STATUS="$_status"
    PVAPI_BODY=$(cat "$_tmpfile")
    rm -f "$_tmpfile"
    return "$_rc"
}
