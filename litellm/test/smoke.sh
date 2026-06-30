#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"
require_env LISTEN_ADDR LISTEN_PORT MASTER_KEY_FILE

key="$(master_key)"
health_url="http://$LISTEN_ADDR:$LISTEN_PORT/health/liveliness"

if curl -fsS "$health_url" >/dev/null; then
  pass "health endpoint is live"
else
  fail "health endpoint is live"
fi

if curl -fsS \
  -H "Authorization: Bearer $key" \
  -H "Content-Type: application/json" \
  "http://$LISTEN_ADDR:$LISTEN_PORT/v1/models" >/dev/null; then
  pass "authenticated /v1/models works"
else
  fail "authenticated /v1/models works"
fi

finish
