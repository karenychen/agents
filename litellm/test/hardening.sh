#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

cid="$("$PODMAN" inspect "$LITELLM_CTR" --format '{{.Id}}' 2>/dev/null || true)"
if [ -n "$cid" ]; then pass "$LITELLM_CTR exists"; else fail "$LITELLM_CTR exists"; fi

pid_mode="$("$PODMAN" inspect "$LITELLM_CTR" --format '{{.HostConfig.PidMode}}' 2>/dev/null || true)"
if [ "$pid_mode" != "host" ]; then pass "pid namespace is private"; else fail "pid namespace is private"; fi

readonly_rootfs="$("$PODMAN" inspect "$LITELLM_CTR" --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || true)"
if [ "$readonly_rootfs" = "true" ]; then pass "litellm rootfs is read-only"; else fail "litellm rootfs is read-only"; fi

cap_eff="$("$PODMAN" exec "$LITELLM_CTR" sh -c "awk '/^CapEff:/ {print \$2}' /proc/1/status" 2>/dev/null || true)"
if [ "$cap_eff" = "0000000000000000" ]; then pass "litellm has no effective capabilities"; else fail "litellm has no effective capabilities ($cap_eff)"; fi

nnp="$("$PODMAN" inspect "$LITELLM_CTR" --format '{{range .HostConfig.SecurityOpt}}{{println .}}{{end}}' 2>/dev/null | grep -c '^no-new-privileges$' || true)"
if [ "$nnp" -gt 0 ]; then pass "no-new-privileges enabled"; else fail "no-new-privileges enabled"; fi

litellm_published="$("$PODMAN" port "$LITELLM_CTR" 4000/tcp 2>/dev/null || true)"
if [ -z "$litellm_published" ]; then pass "litellm has no published port"; else fail "litellm has no published port ($litellm_published)"; fi

ingress_readonly="$("$PODMAN" inspect "$INGRESS_CTR" --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || true)"
if [ "$ingress_readonly" = "true" ]; then pass "ingress rootfs is read-only"; else fail "ingress rootfs is read-only"; fi

published="$("$PODMAN" port "$INGRESS_CTR" 4000/tcp 2>/dev/null || true)"
case "$published" in
  127.0.0.1:*) pass "published port is localhost-only" ;;
  *) fail "published port is localhost-only ($published)" ;;
esac

finish
