#!/usr/bin/env bash
# litellm/teardown.sh
# Remove containers and networks. Keeps images, auth volume, and master-key secret.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/scripts/common.sh"
load_env
require_env LITELLM_CONTAINER PROXY_CONTAINER INTERNAL_NETWORK EGRESS_NETWORK MASTER_KEY_SECRET AUTH_VOLUME

"$PODMAN" rm -f "$LITELLM_CONTAINER" "$PROXY_CONTAINER" >/dev/null 2>&1 || true
"$PODMAN" network rm "$INTERNAL_NETWORK" >/dev/null 2>&1 || true
"$PODMAN" network rm "$EGRESS_NETWORK" >/dev/null 2>&1 || true
echo "torn down; kept secret '$MASTER_KEY_SECRET', auth volume '$AUTH_VOLUME', and images"
