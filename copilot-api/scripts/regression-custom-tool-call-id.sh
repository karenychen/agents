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
  "tools": [
    {
      "type": "custom",
      "name": "apply_patch",
      "description": "Use the apply_patch tool to edit files."
    }
  ],
  "input": [
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "A file was already created. Reply with exactly: DONE"
        }
      ]
    },
    {
      "type": "custom_tool_call",
      "call_id": "call_1",
      "name": "apply_patch",
      "status": "completed",
      "id": "gAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
      "input": "*** Begin Patch\n*** Add File: a.txt\n+hi\n*** End Patch"
    },
    {
      "type": "custom_tool_call_output",
      "call_id": "call_1",
      "output": "Success. Updated the following files:\nA a.txt"
    },
    {
      "type": "message",
      "role": "user",
      "content": [
        {
          "type": "input_text",
          "text": "Reply with exactly: DONE"
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

if grep -q "string_above_max_length" "${response_file}"; then
  echo "custom_tool_call id reached upstream" >&2
  cat "${response_file}" >&2
  exit 1
fi

if ! grep -q "response.completed" "${response_file}"; then
  echo "response stream did not complete" >&2
  cat "${response_file}" >&2
  exit 1
fi

echo "Custom tool call id regression passed"
