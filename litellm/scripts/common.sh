#!/usr/bin/env bash
# Shared helpers for the Podman-backed LiteLLM Copilot setup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PODMAN="${PODMAN:-$(command -v podman || true)}"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

if [ -z "$PODMAN" ]; then
  echo "podman not found in PATH" >&2
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

  case "$("$PODMAN" info --format '{{.Host.Arch}}')" in
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
      LITELLM_USER_ARGS=(--userns=keep-id --user "$(id -u):$(id -g)")
      ;;
    *)
      LITELLM_USER_ARGS=(--user "$LITELLM_UID")
      ;;
  esac
}

ensure_podman_ready() {
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
  if ! "$PODMAN" secret exists "$MASTER_KEY_SECRET" || [ ! -f "$MASTER_KEY_FILE" ]; then
    "$PODMAN" secret rm "$MASTER_KEY_SECRET" >/dev/null 2>&1 || true
    local key
    key="sk-$(openssl rand -hex 32)"
    printf '%s' "$key" | "$PODMAN" secret create "$MASTER_KEY_SECRET" -
    mkdir -p "$(dirname "$MASTER_KEY_FILE")"
    ( umask 077; printf '%s\n' "$key" > "$MASTER_KEY_FILE" )
    chmod 600 "$MASTER_KEY_FILE"
    echo ">> master key regenerated at $MASTER_KEY_FILE"
  else
    echo ">> master key secret and key file present"
  fi
}

ensure_auth_volume_owned() {
  "$PODMAN" volume exists "$AUTH_VOLUME" || "$PODMAN" volume create "$AUTH_VOLUME" >/dev/null
  set_litellm_user_args
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
}

master_key() {
  if [ ! -f "$MASTER_KEY_FILE" ]; then
    echo "Missing $MASTER_KEY_FILE. Run ./setup.sh first." >&2
    exit 1
  fi
  sed -n '1p' "$MASTER_KEY_FILE"
}
