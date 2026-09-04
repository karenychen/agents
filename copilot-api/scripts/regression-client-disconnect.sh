#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
copilot_api_dir="$(cd "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
upstream_log="${temp_dir}/upstream.log"
ingress_log="${temp_dir}/ingress.log"
cancel_file="${temp_dir}/upstream-cancelled"
upstream_port="${COPILOT_API_TEST_UPSTREAM_PORT:-44141}"
ingress_port="${COPILOT_API_TEST_INGRESS_PORT:-44000}"
upstream_pid=""
ingress_pid=""

cleanup() {
  if [[ -n "${ingress_pid}" ]]; then
    kill "${ingress_pid}" 2>/dev/null || true
    wait "${ingress_pid}" 2>/dev/null || true
  fi
  if [[ -n "${upstream_pid}" ]]; then
    kill "${upstream_pid}" 2>/dev/null || true
    wait "${upstream_pid}" 2>/dev/null || true
  fi
  rm -rf "${temp_dir}"
}
trap cleanup EXIT

ABORT_FILE="${cancel_file}" PORT="${upstream_port}" node --input-type=module -e '
  import fs from "node:fs"
  import http from "node:http"

  const server = http.createServer((request, response) => {
    const reply = () => {
      response.writeHead(200, { "content-type": "application/json" })
      response.end("{\"ok\":true}")
    }

    if (request.url === "/slow") {
      response.on("close", () => {
        if (!response.writableEnded) {
          fs.writeFileSync(process.env.ABORT_FILE, "")
        }
      })
      setTimeout(reply, 250)
      return
    }
    reply()
  })

  server.listen(Number.parseInt(process.env.PORT, 10), "127.0.0.1")
' >"${upstream_log}" 2>&1 &
upstream_pid=$!

UPSTREAM_ORIGIN="http://127.0.0.1:${upstream_port}" \
  LISTEN_HOST="127.0.0.1" \
  LISTEN_PORT="${ingress_port}" \
  node "${copilot_api_dir}/ingress/proxy.mjs" >"${ingress_log}" 2>&1 &
ingress_pid=$!

for _ in {1..50}; do
  if curl -fsS "http://127.0.0.1:${ingress_port}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

PORT="${ingress_port}" node --input-type=module -e '
  import net from "node:net"

  const socket = net.connect(
    Number.parseInt(process.env.PORT, 10),
    "127.0.0.1",
    () => {
      socket.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
      setTimeout(() => socket.destroy(), 20)
    },
  )
  socket.on("error", () => {})
  socket.on("close", () => process.exit(0))
'

sleep 0.5

if [[ ! -f "${cancel_file}" ]]; then
  echo "ingress did not cancel the abandoned upstream request" >&2
  exit 1
fi

if ! kill -0 "${ingress_pid}" 2>/dev/null; then
  cat "${ingress_log}" >&2
  echo "ingress exited after the client disconnected" >&2
  exit 1
fi

curl -fsS "http://127.0.0.1:${ingress_port}/health" >/dev/null

echo "Client disconnect regression passed"
