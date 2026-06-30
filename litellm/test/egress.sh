#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"
require_env PROXY_CONTAINER EGRESS_PORT

if "$PODMAN" exec "$PROXY_CONTAINER" sh -c "nc -z 127.0.0.1 '$EGRESS_PORT'"; then
  pass "egress proxy is listening"
else
  fail "egress proxy is listening"
fi

if "$PODMAN" exec "$PROXY_CONTAINER" sh -c "printf 'CONNECT api.github.com:443 HTTP/1.1\r\nHost: api.github.com:443\r\n\r\n' | nc -w 5 127.0.0.1 '$EGRESS_PORT' | grep -q '200'"; then
  pass "allowlisted GitHub CONNECT succeeds"
else
  fail "allowlisted GitHub CONNECT succeeds"
fi

if "$PODMAN" exec "$PROXY_CONTAINER" sh -c "printf 'CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n' | nc -w 5 127.0.0.1 '$EGRESS_PORT' | grep -q '403'"; then
  pass "non-allowlisted CONNECT is denied"
else
  fail "non-allowlisted CONNECT is denied"
fi

finish
