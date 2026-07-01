#!/usr/bin/env bash
# Shared helpers for the Docker-backed LiteLLM Copilot setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-${LITELLM_CONTAINER_RUNTIME:-}}"
if [ -z "$CONTAINER_RUNTIME" ]; then
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
  fi
fi
PODMAN="${PODMAN:-$(command -v "$CONTAINER_RUNTIME" 2>/dev/null || true)}"

if [ -z "$PODMAN" ]; then
  echo "Docker not found in PATH; install Docker or set CONTAINER_RUNTIME explicitly" >&2
  exit 1
fi

load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "Missing $ENV_FILE (copy $ROOT/.env.example)" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

require_env() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "Missing required setting: $name" >&2
      exit 1
    fi
  done
}

select_litellm_image() {
  if [ -n "${LITELLM_IMAGE:-}" ]; then
    printf '%s\n' "$LITELLM_IMAGE"
    return
  fi

  local arch
  arch="$("$PODMAN" info --format '{{.Architecture}}')"
  arch="$(printf '%s' "$arch" | tr -d '[:space:]')"
  case "$arch" in
    amd64|x86_64)
      printf '%s\n' "${LITELLM_IMAGE_AMD64:?}"
      ;;
    arm64|aarch64)
      printf '%s\n' "${LITELLM_IMAGE_ARM64:?}"
      ;;
    *)
      echo "No pinned LiteLLM image configured for this architecture" >&2
      exit 1
      ;;
  esac
}

set_litellm_user_args() {
  LITELLM_USER_ARGS=()
  case "${LITELLM_UID:-keep-id}" in
    keep-id|auto)
      LITELLM_USER_ARGS=(--user "$(id -u):$(id -g)")
      ;;
    *)
      LITELLM_USER_ARGS=(--user "$LITELLM_UID")
      ;;
  esac
}

ensure_runtime_ready() {
  "$PODMAN" info >/dev/null
}

set_tty_args() {
  TTY_ARGS=()
  if [ -t 0 ] && [ -t 1 ]; then
    TTY_ARGS=(-it)
  fi
}

ensure_master_key() {
  if [ ! -f "$MASTER_KEY_FILE" ]; then
    local key
    key="sk-$(openssl rand -hex 32)"
    mkdir -p "$(dirname "$MASTER_KEY_FILE")"
    ( umask 077; printf '%s\n' "$key" > "$MASTER_KEY_FILE" )
    chmod 600 "$MASTER_KEY_FILE"
    echo ">> master key regenerated at $MASTER_KEY_FILE"
  else
    echo ">> master key file present"
  fi
}

ensure_auth_volume_owned() {
  volume_exists "$AUTH_VOLUME" || "$PODMAN" volume create "$AUTH_VOLUME" >/dev/null
  set_litellm_user_args
  "$PODMAN" run --rm \
    --network none \
    --user 0:0 \
    --cap-drop=ALL \
    --cap-add=CHOWN \
    --cap-add=DAC_OVERRIDE \
    --cap-add=FOWNER \
    --security-opt=no-new-privileges \
    --read-only \
    --pids-limit=64 \
    --memory=64m --memory-swap=64m \
    --mount "type=volume,src=$AUTH_VOLUME,dst=/auth" \
    "$ALPINE_IMAGE" \
    sh -c "chown -R $(id -u):$(id -g) /auth && chmod 700 /auth && touch /auth/.writetest && rm -f /auth/.writetest"
}

master_key() {
  if [ ! -f "$MASTER_KEY_FILE" ]; then
    echo "Missing $MASTER_KEY_FILE. Run ./setup.sh first." >&2
    exit 1
  fi
  sed -n '1p' "$MASTER_KEY_FILE"
}

container_exists() {
  "$PODMAN" container inspect "$1" >/dev/null 2>&1
}

network_exists() {
  "$PODMAN" network inspect "$1" >/dev/null 2>&1
}

volume_exists() {
  "$PODMAN" volume inspect "$1" >/dev/null 2>&1
}

set_litellm_secret_args() {
  LITELLM_SECRET_ARGS=()
  export LITELLM_MASTER_KEY
  LITELLM_MASTER_KEY="$(master_key)"
  LITELLM_SECRET_ARGS=(-e LITELLM_MASTER_KEY)
}

config_mount_arg() {
  printf 'type=bind,src=%s/config/config.yaml,dst=/etc/litellm/config.yaml,readonly' "$ROOT"
}
