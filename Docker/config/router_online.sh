#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-router:latest}"
LAN_NET="${LAN_NET:-lan0}"
LAN_IP="${LAN_IP:-10.200.0.254}"
LAN_CIDR="${LAN_CIDR:-10.200.0.0/24}"

docker rm -f router 2>/dev/null || true

docker run -d --name router \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  -e UPLINK_IF=eth0 \
  -e LAN_IF=eth1 \
  -e LAN_IP="${LAN_IP}" \
  -e LAN_CIDR="${LAN_CIDR}" \
  -e AUTH_TIMEOUT="${AUTH_TIMEOUT:-3600}" \
  -e VNC_PW="${VNC_PW:-routerpass}" \
  -e BROWSER_URL="${BROWSER_URL:-}" \
  -p 6091:6081 \
  "${IMAGE}"

docker network connect --ip "${LAN_IP}" "${LAN_NET}" router
