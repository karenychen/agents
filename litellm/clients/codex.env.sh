#!/usr/bin/env bash
# Source this file before launching Codex, or execute it with a command.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/scripts/common.sh"
load_env
require_env MASTER_KEY_FILE

litellm_master_key="$(master_key)"
export LITELLM_MASTER_KEY="$litellm_master_key"

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -gt 0 ]; then
  exec "$@"
elif [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "Run with a command, for example: $0 codex" >&2
  echo "Or source it: source $0" >&2
fi
