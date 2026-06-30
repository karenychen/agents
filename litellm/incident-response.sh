#!/usr/bin/env bash
# litellm/incident-response.sh
# Contain a suspected LiteLLM/Copilot proxy compromise and preserve host-side evidence.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/scripts/common.sh"
load_env
require_env LITELLM_CONTAINER PROXY_CONTAINER INTERNAL_NETWORK EGRESS_NETWORK \
  AUTH_VOLUME MASTER_KEY_SECRET MASTER_KEY_FILE

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
incident_dir="$HOME/.local/state/litellm-copilot/incidents/$timestamp"
mkdir -p "$incident_dir"
chmod 700 "$HOME/.local/state/litellm-copilot" "$HOME/.local/state/litellm-copilot/incidents" "$incident_dir"

capture() {
  local name="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@" 2>&1 || true
  } > "$incident_dir/$name.txt"
  chmod 600 "$incident_dir/$name.txt" 2>/dev/null || true
}

capture podman-ps "$PODMAN" ps -a

for container in "$LITELLM_CONTAINER" "$PROXY_CONTAINER"; do
  if "$PODMAN" container exists "$container"; then
    capture "container-$container-inspect" "$PODMAN" inspect "$container"
    capture "container-$container-logs" "$PODMAN" logs --timestamps "$container"
  fi
done

for network in "$INTERNAL_NETWORK" "$EGRESS_NETWORK"; do
  if "$PODMAN" network exists "$network"; then
    capture "network-$network-inspect" "$PODMAN" network inspect "$network"
  fi
done

image_names="$("$PODMAN" inspect "$LITELLM_CONTAINER" "$PROXY_CONTAINER" --format '{{.ImageName}}' 2>/dev/null | sort -u || true)"
for image in $image_names; do
  [ -n "$image" ] || continue
  safe_image="${image//[^A-Za-z0-9_.-]/_}"
  capture "image-$safe_image-inspect" "$PODMAN" image inspect "$image"
done

echo ">> stop compromised stack"
"$PODMAN" rm -f "$LITELLM_CONTAINER" "$PROXY_CONTAINER" >/dev/null 2>&1 || true

if "$PODMAN" volume exists "$AUTH_VOLUME"; then
  auth_archive="$incident_dir/${AUTH_VOLUME}.tar"
  echo ">> export and remove auth volume"
  "$PODMAN" volume export "$AUTH_VOLUME" -o "$auth_archive"
  chmod 600 "$auth_archive"
  "$PODMAN" volume rm "$AUTH_VOLUME" >/dev/null
else
  echo ">> auth volume '$AUTH_VOLUME' not present"
fi

echo ">> rotate LiteLLM master key"
"$PODMAN" secret rm "$MASTER_KEY_SECRET" >/dev/null 2>&1 || true
new_key="sk-$(openssl rand -hex 32)"
printf '%s' "$new_key" | "$PODMAN" secret create "$MASTER_KEY_SECRET" - >/dev/null
mkdir -p "$(dirname "$MASTER_KEY_FILE")"
( umask 077; printf '%s\n' "$new_key" > "$MASTER_KEY_FILE" )
chmod 600 "$MASTER_KEY_FILE"

cat <<EOF
Incident response artifacts written to:
  $incident_dir

Manual follow-up required:
1. Revoke the GitHub OAuth/Copilot authorization used by LiteLLM.
2. Review the evidence bundle before deleting it.
3. Rebuild and re-authenticate from trusted pins:
   cd "$HERE"
   ./auth.sh
   ./setup.sh
   ./test/smoke.sh
   ./test/hardening.sh
   ./test/egress.sh

Treat prompts, responses, model names, request metadata, and the old Copilot auth
cache from the suspected window as exposed.
EOF
