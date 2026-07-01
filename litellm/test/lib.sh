#!/usr/bin/env bash
# litellm/test/lib.sh
# Shared helpers for verification scripts. Source me: . "$(dirname "$0")/lib.sh"
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"
load_env
LITELLM_CTR="${LITELLM_CONTAINER:-litellm-copilot}"
PROXY_CTR="${PROXY_CONTAINER:-litellm-copilot-egress}"
INGRESS_CTR="${INGRESS_CONTAINER:-litellm-copilot-ingress}"
export LITELLM_CTR PROXY_CTR INGRESS_CTR
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
finish() { echo "---- $PASS passed, $FAIL failed ----"; [ "$FAIL" -eq 0 ]; }
