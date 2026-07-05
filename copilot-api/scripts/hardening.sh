#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

host_port="${COPILOT_API_HOST_PORT:-44141}"

fail() {
  echo "hardening check failed: $*" >&2
  exit 1
}

ingress_ports="$(docker inspect copilot-api-ingress --format '{{range $containerPort, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp ":" .HostPort}}{{end}}{{end}}')"
api_ports="$(docker inspect copilot-api --format '{{json .NetworkSettings.Ports}}')"
egress_ports="$(docker inspect copilot-api-egress --format '{{json .NetworkSettings.Ports}}')"

grep -q "127.0.0.1 : ${host_port}" <<<"${ingress_ports}" || fail "ingress is not bound to 127.0.0.1:${host_port}"
[[ "${api_ports}" != *"HostPort"* ]] || fail "copilot-api publishes a host port"
[[ "${egress_ports}" != *"HostPort"* ]] || fail "egress publishes a host port"

api_mounts="$(docker inspect copilot-api --format '{{range .Mounts}}{{println .Destination}}{{end}}')"
ingress_mounts="$(docker inspect copilot-api-ingress --format '{{range .Mounts}}{{println .Destination}}{{end}}')"
egress_mounts="$(docker inspect copilot-api-egress --format '{{range .Mounts}}{{println .Destination}}{{end}}')"

grep -qx "/data" <<<"${api_mounts}" || fail "copilot-api does not mount /data"
! grep -qx "/data" <<<"${ingress_mounts}" || fail "ingress can read auth data"
! grep -qx "/data" <<<"${egress_mounts}" || fail "egress can read auth data"

for container in copilot-api-ingress copilot-api copilot-api-egress; do
  privileged="$(docker inspect "${container}" --format '{{.HostConfig.Privileged}}')"
  readonly_rootfs="$(docker inspect "${container}" --format '{{.HostConfig.ReadonlyRootfs}}')"
  cap_drop="$(docker inspect "${container}" --format '{{json .HostConfig.CapDrop}}')"
  security_opt="$(docker inspect "${container}" --format '{{json .HostConfig.SecurityOpt}}')"

  [[ "${privileged}" == "false" ]] || fail "${container} is privileged"
  [[ "${readonly_rootfs}" == "true" ]] || fail "${container} root filesystem is writable"
  [[ "${cap_drop}" == *"ALL"* ]] || fail "${container} does not drop all capabilities"
  [[ "${security_opt}" == *"no-new-privileges:true"* ]] || fail "${container} missing no-new-privileges"
done

echo "Hardening checks passed"
