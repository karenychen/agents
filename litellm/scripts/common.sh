#!/usr/bin/env bash
# Shared helpers for the Podman-backed LiteLLM Copilot setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-${LITELLM_CONTAINER_RUNTIME:-}}"
if [ -z "$CONTAINER_RUNTIME" ]; then
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_RUNTIME="podman"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_RUNTIME="docker"
  fi
fi
PODMAN="${PODMAN:-$(command -v "$CONTAINER_RUNTIME" 2>/dev/null || true)}"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [ -z "$PODMAN" ]; then
  echo "container runtime not found in PATH; install Podman or Docker" >&2
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
  arch="$("$PODMAN" info --format '{{.Host.Arch}}' 2>/dev/null || "$PODMAN" info --format '{{.Architecture}}')"
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
      if is_podman; then
        LITELLM_USER_ARGS=(--userns=keep-id --user "$(id -u):$(id -g)")
      else
        LITELLM_USER_ARGS=(--user "$(id -u):$(id -g)")
      fi
      ;;
    *)
      LITELLM_USER_ARGS=(--user "$LITELLM_UID")
      ;;
  esac
}

ensure_podman_ready() {
  if is_docker; then
    "$PODMAN" info >/dev/null
    return
  fi
  local state
  if state="$("$PODMAN" machine inspect --format '{{.State}}' 2>/dev/null)"; then
    if [ "$state" != "running" ]; then
      echo "Start the Podman machine first: $PODMAN machine start" >&2
      exit 1
    fi
  fi
}

ensure_machine_memory() {
  local required="${MIN_PODMAN_MACHINE_MEMORY_MB:-0}"
  local memory_bytes
  local required_bytes
  if [ "$required" -eq 0 ]; then
    return
  fi
  if memory_bytes="$("$PODMAN" info --format '{{.Host.MemTotal}}' 2>/dev/null)"; then
    required_bytes=$((required * 1024 * 1024))
    if [ -n "$memory_bytes" ] && [ "$memory_bytes" -lt "$required_bytes" ]; then
      echo "Podman has $((memory_bytes / 1024 / 1024)) MB available; LiteLLM needs at least ${required} MB for this setup." >&2
      echo "For Podman Machine: $PODMAN machine stop && $PODMAN machine set --memory $required && $PODMAN machine start" >&2
      exit 1
    fi
  fi
}

ensure_master_key() {
  if { is_podman && ! secret_exists "$MASTER_KEY_SECRET"; } || [ ! -f "$MASTER_KEY_FILE" ]; then
    is_podman && "$PODMAN" secret rm "$MASTER_KEY_SECRET" >/dev/null 2>&1 || true
    local key
    key="sk-$(openssl rand -hex 32)"
    if is_podman; then
      printf '%s' "$key" | "$PODMAN" secret create "$MASTER_KEY_SECRET" - >/dev/null
    fi
    mkdir -p "$(dirname "$MASTER_KEY_FILE")"
    ( umask 077; printf '%s\n' "$key" > "$MASTER_KEY_FILE" )
    chmod 600 "$MASTER_KEY_FILE"
    echo ">> master key regenerated at $MASTER_KEY_FILE"
  else
    echo ">> master key secret and key file present"
  fi
}

ensure_auth_volume_owned() {
  volume_exists "$AUTH_VOLUME" || "$PODMAN" volume create "$AUTH_VOLUME" >/dev/null
  set_litellm_user_args
  if is_docker; then
    "$PODMAN" run --rm \
      --network none \
      --user 0:0 \
      --cap-drop=ALL \
      --security-opt=no-new-privileges \
      --read-only \
      --pids-limit=64 \
      --memory=64m --memory-swap=64m \
      --mount "type=volume,src=$AUTH_VOLUME,dst=/auth" \
      "$ALPINE_IMAGE" \
      sh -c "chown -R $(id -u):$(id -g) /auth && chmod 700 /auth && touch /auth/.writetest && rm -f /auth/.writetest"
  else
    "$PODMAN" run --rm \
      --network none \
      "${LITELLM_USER_ARGS[@]}" \
      --cap-drop=ALL \
      --security-opt=no-new-privileges \
      --read-only \
      --pids-limit=64 \
      --memory=64m --memory-swap=64m \
      --mount "type=volume,src=$AUTH_VOLUME,dst=/auth" \
      "$ALPINE_IMAGE" \
      sh -c "chmod 700 /auth && touch /auth/.writetest && rm -f /auth/.writetest"
  fi
}

master_key() {
  if [ ! -f "$MASTER_KEY_FILE" ]; then
    echo "Missing $MASTER_KEY_FILE. Run ./setup.sh first." >&2
    exit 1
  fi
  sed -n '1p' "$MASTER_KEY_FILE"
}

is_podman() {
  [ "$(basename "$PODMAN")" = "podman" ]
}

is_docker() {
  [ "$(basename "$PODMAN")" = "docker" ]
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

secret_exists() {
  is_podman && "$PODMAN" secret exists "$1" >/dev/null 2>&1
}

set_litellm_secret_args() {
  LITELLM_SECRET_ARGS=()
  if is_podman; then
    LITELLM_SECRET_ARGS=(--secret "$MASTER_KEY_SECRET,type=env,target=LITELLM_MASTER_KEY")
  else
    export LITELLM_MASTER_KEY
    LITELLM_MASTER_KEY="$(master_key)"
    LITELLM_SECRET_ARGS=(-e LITELLM_MASTER_KEY)
  fi
}

config_mount_arg() {
  if is_docker; then
    printf 'type=bind,src=%s/config/config.yaml,dst=/etc/litellm/config.yaml,readonly' "$ROOT"
  else
    printf 'type=bind,src=%s/config/config.yaml,dst=/etc/litellm/config.yaml,ro=true' "$ROOT"
  fi
}
