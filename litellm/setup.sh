#!/usr/bin/env bash
# litellm/setup.sh
# Idempotent start/restart for the hardened LiteLLM -> GitHub Copilot proxy.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HERE/scripts/ensure-env.sh"
# shellcheck disable=SC1091
source "$HERE/scripts/common.sh"
load_env
require_env ALPINE_IMAGE TINYPROXY_VERSION LISTEN_ADDR LISTEN_PORT \
  CONTAINER_HOME LITELLM_UID PROXY_UID EGRESS_PORT LITELLM_CONTAINER \
  PROXY_CONTAINER INTERNAL_NETWORK EGRESS_NETWORK AUTH_VOLUME \
  MASTER_KEY_SECRET MASTER_KEY_FILE LITELLM_MEMORY LITELLM_CPUS \
  PROXY_MEMORY PROXY_CPUS MIN_PODMAN_MACHINE_MEMORY_MB

LITELLM_IMAGE="$(select_litellm_image)"
TOKEN_DST="$CONTAINER_HOME/.config/litellm/github_copilot"
set_litellm_user_args

ensure_podman_ready
ensure_machine_memory
ensure_master_key
ensure_auth_volume_owned

echo ">> build egress proxy"
"$PODMAN" build \
  --build-arg ALPINE_IMAGE="$ALPINE_IMAGE" \
  --build-arg TINYPROXY_VERSION="$TINYPROXY_VERSION" \
  -t localhost/egress-proxy:1 "$HERE/proxy"

echo ">> networks"
"$PODMAN" network exists "$INTERNAL_NETWORK" || "$PODMAN" network create --internal "$INTERNAL_NETWORK"
"$PODMAN" network exists "$EGRESS_NETWORK" || "$PODMAN" network create "$EGRESS_NETWORK"

BASE_HARDEN=(
  --cap-drop=ALL
  --security-opt=no-new-privileges
  --read-only
  --pids-limit=128
  --restart=always
)

echo ">> (re)create egress-proxy"
"$PODMAN" rm -f "$PROXY_CONTAINER" >/dev/null 2>&1 || true
"$PODMAN" run -d --name "$PROXY_CONTAINER" \
  --network "$EGRESS_NETWORK" \
  --user "$PROXY_UID" \
  "${BASE_HARDEN[@]}" \
  --memory="$PROXY_MEMORY" --memory-swap="$PROXY_MEMORY" --cpus="$PROXY_CPUS" \
  --tmpfs /tmp:rw,size=8m \
  localhost/egress-proxy:1
"$PODMAN" network connect "$INTERNAL_NETWORK" "$PROXY_CONTAINER"

echo ">> (re)create litellm"
"$PODMAN" rm -f "$LITELLM_CONTAINER" >/dev/null 2>&1 || true
"$PODMAN" run -d --name "$LITELLM_CONTAINER" \
  --network "$INTERNAL_NETWORK" \
  "${LITELLM_USER_ARGS[@]}" \
  "${BASE_HARDEN[@]}" \
  --memory="$LITELLM_MEMORY" --memory-swap="$LITELLM_MEMORY" --cpus="$LITELLM_CPUS" \
  --tmpfs /tmp:rw,size=16m \
  --mount "type=volume,src=$AUTH_VOLUME,dst=$TOKEN_DST" \
  --mount "type=bind,src=$HERE/config/config.yaml,dst=/etc/litellm/config.yaml,ro=true" \
  --secret "$MASTER_KEY_SECRET,type=env,target=LITELLM_MASTER_KEY" \
  -e HOME="$CONTAINER_HOME" \
  -e HTTPS_PROXY="http://$PROXY_CONTAINER:$EGRESS_PORT" \
  -e HTTP_PROXY="http://$PROXY_CONTAINER:$EGRESS_PORT" \
  -e NO_PROXY="127.0.0.1,localhost" \
  -e LITELLM_LOG=WARNING \
  -e LITELLM_LOCAL_MODEL_COST_MAP="True" \
  -p "$LISTEN_ADDR:$LISTEN_PORT:4000" \
  "$LITELLM_IMAGE" \
  --config /etc/litellm/config.yaml --port 4000 --host 0.0.0.0

echo ">> waiting for health"
for i in $(seq 1 30); do
  if curl --max-time 2 -fsS "http://$LISTEN_ADDR:$LISTEN_PORT/health/liveliness" >/dev/null 2>&1; then
    echo "   litellm is live"; break
  fi; sleep 2
  [ "$i" -eq 30 ] && { echo "   timed out; check: $PODMAN logs $LITELLM_CONTAINER"; exit 1; }
done
echo ">> done"
