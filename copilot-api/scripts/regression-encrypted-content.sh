#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
copilot_api_dir="$(cd "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d)"
capture_file="${temp_dir}/request.json"
upstream_log="${temp_dir}/upstream.log"
ingress_log="${temp_dir}/ingress.log"
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

cat >"${temp_dir}/upstream.mjs" <<'JS'
import fs from "node:fs"
import http from "node:http"

const server = http.createServer((request, response) => {
  const chunks = []
  request.on("data", (chunk) => chunks.push(chunk))
  request.on("end", () => {
    fs.writeFileSync(process.env.CAPTURE_FILE, Buffer.concat(chunks))
    response.writeHead(200, { "content-type": "application/json" })
    response.end('{"ok":true}')
  })
})

server.listen(Number.parseInt(process.env.PORT, 10), "127.0.0.1")
JS

CAPTURE_FILE="${capture_file}" PORT="${upstream_port}" \
  node "${temp_dir}/upstream.mjs" >"${upstream_log}" 2>&1 &
upstream_pid=$!

UPSTREAM_ORIGIN="http://127.0.0.1:${upstream_port}" \
  LISTEN_HOST="127.0.0.1" \
  LISTEN_PORT="${ingress_port}" \
  node "${copilot_api_dir}/ingress/proxy.mjs" >"${ingress_log}" 2>&1 &
ingress_pid=$!

for _ in {1..50}; do
  if node -e "
    const socket = require('node:net').connect(${ingress_port}, '127.0.0.1')
    socket.on('connect', () => { socket.end(); process.exit(0) })
    socket.on('error', () => process.exit(1))
  "; then
    break
  fi
  sleep 0.1
done

curl -fsS "http://127.0.0.1:${ingress_port}/responses" \
  -H "Content-Type: application/json" \
  --data-binary @- >/dev/null <<'JSON'
{
  "model": "gpt-5.6-sol",
  "input": [
    {
      "type": "compaction",
      "id": "gateway-compaction-state",
      "encrypted_content": "encrypted-conversation-summary"
    },
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "Continue from the compacted conversation."
        }
      ]
    }
  ]
}
JSON

node - "${capture_file}" <<'JS'
import fs from "node:fs"

const request = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
const compaction = request.input[0]

if (
  compaction?.type !== "compaction"
  || compaction.id !== "gateway-compaction-state"
  || compaction.encrypted_content !== "encrypted-conversation-summary"
) {
  console.error("encrypted compaction state was stripped")
  process.exit(1)
}
JS

echo "Encrypted compaction state regression passed"
