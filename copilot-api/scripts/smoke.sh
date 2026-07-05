#!/usr/bin/env bash
set -euo pipefail

base_url="${COPILOT_API_BASE_URL:-http://127.0.0.1:44141}"
api_key="${COPILOT_API_KEY:-}"
model="${COPILOT_API_MODEL:-gpt-5.5}"
messages_model="${COPILOT_API_MESSAGES_MODEL:-claude-sonnet-5}"

curl_auth_args=()
if [[ -n "${api_key}" ]]; then
  curl_auth_args=(-H "Authorization: Bearer ${api_key}")
fi

echo "Checking ${base_url}/v1/models"
curl -fsS "${base_url}/v1/models" \
  "${curl_auth_args[@]}" \
  -o /tmp/copilot-api-models.json

echo "Checking ${base_url}/v1/responses with ${model}"
curl -fsS "${base_url}/v1/responses" \
  "${curl_auth_args[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${model}\",\"input\":\"Reply with exactly: ok\",\"max_output_tokens\":50}" \
  -o /tmp/copilot-api-responses.json

if ! grep -qi "ok" /tmp/copilot-api-responses.json; then
  echo "Responses smoke test did not contain expected text" >&2
  cat /tmp/copilot-api-responses.json >&2
  exit 1
fi

echo "Checking ${base_url}/v1/messages with ${messages_model}"
curl -fsS "${base_url}/v1/messages" \
  "${curl_auth_args[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${messages_model}\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}]}" \
  -o /tmp/copilot-api-messages.json

if ! grep -qi "ok" /tmp/copilot-api-messages.json; then
  echo "Messages smoke test did not contain expected text" >&2
  cat /tmp/copilot-api-messages.json >&2
  exit 1
fi

echo "Smoke tests passed"
