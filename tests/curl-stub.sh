#!/usr/bin/env bash
# Stub curl for tests/reap.rs. Routes on the URL and answers from STUB_*
# environment variables; no hypervisor or network required.
#
#   STUB_VM_LIST          JSON for GET /nodes/{node}/qemu
#   STUB_VM_{N}_CONFIG    JSON for GET /nodes/{node}/qemu/{N}/config
#   STUB_VM_{N}_STATUS    JSON for GET /nodes/{node}/qemu/{N}/status/current
#   STUB_RUN_{N}          JSON for GET /repos/{o}/{r}/actions/runs/{N}
#   STUB_RUNNERS          JSON for GET https://api.github.com/.../runners
#   STUB_FAIL_URL         ERE; matching URLs exit 6 (connection failure)
#   STUB_DESTROYED        Path to append destroyed VMIDs (one per line)
url=""; method=GET; output_file=""; write_out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--request) method=${2^^}; shift 2 ;;
    -o|--output) output_file=$2; shift 2 ;;
    -w|--write-out) write_out=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[ -n "$url" ] || exit 0

if [ -n "${STUB_FAIL_URL:-}" ] && [[ $url =~ $STUB_FAIL_URL ]]; then
  echo "curl: (6) Could not resolve host" >&2
  exit 6
fi

# pvapi.sh calls curl with -o tmpfile -w '%{http_code}': body to the file,
# status code to stdout. Without -o the body goes to stdout.
respond() {
  if [ -n "$output_file" ]; then
    printf '%s\n' "$1" > "$output_file"
    [ "$write_out" = '%{http_code}' ] && printf 200
  else
    printf '%s\n' "$1"
  fi
  exit 0
}

# Owning-run check. Must precede the runners route: both live on
# api.github.com and the runners route is a catch-all.
if [[ $url =~ /repos/[^/]+/[^/]+/actions/runs/([0-9]+)$ ]]; then
  key="STUB_RUN_${BASH_REMATCH[1]}"
  [ -n "${!key+x}" ] && respond "${!key}"
  echo "curl: (22) not found" >&2
  exit 22
fi

if [[ $url == *api.github.com* ]]; then
  respond "${STUB_RUNNERS:-{\"runners\": []\}}"
fi

if [[ $url =~ /qemu$ && $method == GET ]]; then
  respond "${STUB_VM_LIST:-{\"data\": []\}}"
fi

if [[ $url =~ /qemu/([0-9]+)/config ]]; then
  id=${BASH_REMATCH[1]}; key="STUB_VM_${id}_CONFIG"
  [ -n "${!key+x}" ] && respond "${!key}"
  respond "{\"data\": {\"name\": \"gh-runner-$id\", \"meta\": \"\"}}"
fi

if [[ $url =~ /qemu/([0-9]+)/status/current ]]; then
  key="STUB_VM_${BASH_REMATCH[1]}_STATUS"
  [ -n "${!key+x}" ] && respond "${!key}"
  respond '{"data": {"status": "stopped"}}'
fi

if [[ $url =~ /qemu/[0-9]+/status/stop ]]; then
  respond '{"data": "UPID:test"}'
fi

if [[ $url =~ /qemu/([0-9]+) && $method == DELETE ]]; then
  [ -n "${STUB_DESTROYED:-}" ] && echo "${BASH_REMATCH[1]}" >> "$STUB_DESTROYED"
  respond '{"data": "UPID:destroy"}'
fi

respond '{}'
