#!/usr/bin/env bash
set -euo pipefail
LAN_NET="${LAN_NET:-lan0}"
SUBNET="${SUBNET:-10.200.0.0/24}"
GATEWAY="${GATEWAY:-10.200.0.1}"

if docker network inspect "${LAN_NET}" >/dev/null 2>&1; then
  echo "La red ${LAN_NET} ya existe."
else
  docker network create \
    --driver bridge \
    --subnet "${SUBNET}" \
    --gateway "${GATEWAY}" \
    "${LAN_NET}"
  echo "Red ${LAN_NET} creada."
fi
