#!/usr/bin/env bash
# Source this file before launching Claude Code, or execute it with a command.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/scripts/common.sh"
load_env
require_env LISTEN_ADDR LISTEN_PORT MASTER_KEY_FILE

export ANTHROPIC_BASE_URL="http://$LISTEN_ADDR:$LISTEN_PORT"
anthropic_auth_token="$(master_key)"
export ANTHROPIC_AUTH_TOKEN="$anthropic_auth_token"
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-5}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_DEFAULT_SONNET_MODEL:-claude-sonnet-5}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_DEFAULT_OPUS_MODEL:-claude-opus-4.8}"
unset ANTHROPIC_API_KEY

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -gt 0 ]; then
  exec "$@"
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Run with a command, for example: $0 claude" >&2
  echo "Or source it: source $0" >&2
fi
