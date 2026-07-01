#!/usr/bin/env bash
# Bootstrap or refresh the GitHub Copilot token cache used by LiteLLM.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HERE/scripts/ensure-env.sh"
# shellcheck disable=SC1091
source "$HERE/scripts/common.sh"
load_env
require_env ALPINE_IMAGE TINYPROXY_VERSION CONTAINER_HOME LITELLM_UID PROXY_UID \
  EGRESS_PORT PROXY_CONTAINER EGRESS_NETWORK AUTH_VOLUME LITELLM_MEMORY \
  PROXY_MEMORY PROXY_CPUS MIN_PODMAN_MACHINE_MEMORY_MB

LITELLM_IMAGE="$(select_litellm_image)"
TOKEN_DST="$CONTAINER_HOME/.config/litellm/github_copilot"
set_litellm_user_args

ensure_podman_ready
ensure_machine_memory
ensure_auth_volume_owned

echo ">> ensure egress proxy is available"
if ! "$PODMAN" container exists "$PROXY_CONTAINER"; then
  "$PODMAN" network exists "$EGRESS_NETWORK" || "$PODMAN" network create "$EGRESS_NETWORK"
  "$PODMAN" build \
    --build-arg ALPINE_IMAGE="$ALPINE_IMAGE" \
    --build-arg TINYPROXY_VERSION="$TINYPROXY_VERSION" \
    -t localhost/egress-proxy:1 "$HERE/proxy"
  "$PODMAN" run -d --name "$PROXY_CONTAINER" \
    --network "$EGRESS_NETWORK" \
    --user "$PROXY_UID" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --read-only \
    --pids-limit=128 \
    --memory="$PROXY_MEMORY" --memory-swap="$PROXY_MEMORY" --cpus="$PROXY_CPUS" \
    --tmpfs /tmp:rw,size=8m \
    localhost/egress-proxy:1
fi

echo ">> start GitHub Copilot device auth"
echo "   Follow the device-code prompt printed by LiteLLM, then wait for 'ok'."
"$PODMAN" run --rm -it --name litellm-copilot-auth \
  --network "$EGRESS_NETWORK" \
  "${LITELLM_USER_ARGS[@]}" \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --read-only \
  --pids-limit=128 \
  --memory="$LITELLM_MEMORY" --memory-swap="$LITELLM_MEMORY" \
  --tmpfs /tmp:rw,size=16m \
  --mount "type=volume,src=$AUTH_VOLUME,dst=$TOKEN_DST" \
  -e HOME="$CONTAINER_HOME" \
  -e HTTPS_PROXY="http://$PROXY_CONTAINER:$EGRESS_PORT" \
  -e HTTP_PROXY="http://$PROXY_CONTAINER:$EGRESS_PORT" \
  -e NO_PROXY="127.0.0.1,localhost" \
  -e LITELLM_LOG=WARNING \
  -e LITELLM_LOCAL_MODEL_COST_MAP="True" \
  --entrypoint python \
  "$LITELLM_IMAGE" \
  -c 'import litellm; litellm.completion(model="github_copilot/claude-sonnet-5", messages=[{"role":"user","content":"Reply with ok."}], max_tokens=2); print("ok")'
