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

connect_status() {
  local host="$1"
  "$PODMAN" exec "$LITELLM_CTR" python -c 'import socket, sys
proxy_host, proxy_port, target = sys.argv[1], int(sys.argv[2]), sys.argv[3]
request = f"CONNECT {target}:443 HTTP/1.1\r\nHost: {target}:443\r\n\r\n".encode()
with socket.create_connection((proxy_host, proxy_port), timeout=10) as sock:
    sock.sendall(request)
    print(sock.recv(256).decode("utf-8", "replace").splitlines()[0])
' "$PROXY_CONTAINER" "$EGRESS_PORT" "$host"
}

if connect_status api.github.com | grep -q '200'; then
  pass "allowlisted GitHub CONNECT succeeds"
else
  fail "allowlisted GitHub CONNECT succeeds"
fi

if connect_status example.com | grep -q '403'; then
  pass "non-allowlisted CONNECT is denied"
else
  fail "non-allowlisted CONNECT is denied"
fi

finish
