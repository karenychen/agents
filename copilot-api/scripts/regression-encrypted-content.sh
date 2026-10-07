#!/usr/bin/env bash
set -euo pipefail

base_url="${COPILOT_API_BASE_URL:-http://127.0.0.1:4000}"
request_file="$(mktemp)"
response_file="$(mktemp)"
trap 'rm -f "${request_file}" "${response_file}"' EXIT

cat >"${request_file}" <<'JSON'
{
  "model": "gpt-5.5[1m]",
  "stream": true,
  "input": [
    {
      "type": "compaction",
      "id": "compaction-item-with-stale-encrypted-state",
      "encrypted_content": "gAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    },
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "Ignore prior encrypted reasoning state. Reply with exactly: ok"
        }
      ]
    }
  ]
}
JSON

curl -fsS -N "${base_url}/responses" \
  -H "Content-Type: application/json" \
  --data-binary @"${request_file}" \
  -o "${response_file}"

if grep -Eq "encrypted content|encrypted_content" "${response_file}"; then
  echo "encrypted content reached upstream" >&2
  cat "${response_file}" >&2
  exit 1
fi

if ! grep -q "response.completed" "${response_file}"; then
  echo "response stream did not complete" >&2
  cat "${response_file}" >&2
  exit 1
fi

echo "Encrypted content regression passed"
