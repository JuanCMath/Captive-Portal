#!/usr/bin/env bash
set -euo pipefail

# Inicia y conecta un router de pruebas para la LAN del portal cautivo
IMAGE="${1:-router:latest}"

# Parámetros de red y entorno
LAN_NET="${LAN_NET:-lan0}"
LAN_IP="${LAN_IP:-10.200.0.254}"
LAN_CIDR="${LAN_CIDR:-10.200.0.0/24}"

# Limpieza previa
docker rm -f router 2>/dev/null || true

# Inicio del contenedor con capacidades de red y UI VNC
docker run -d --name router \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --sysctl net.ipv4.ip_forward=1 \
  -e ROLE=router \
  -e UPLINK_IF=eth0 \
  -e LAN_IF=eth1 \
  -e LAN_IP="${LAN_IP}" \
  -e LAN_CIDR="${LAN_CIDR}" \
  -e VNC_PW="${VNC_PW:-routerpass}" \
  -e BROWSER_URL="${BROWSER_URL:-https://example.com}" \
  -p 6091:6081 \
  "${IMAGE}" bash -lc '/entrypoint.sh /usr/local/bin/start-ui.sh'

# Conexión a la LAN con IP fija del gateway
docker network connect --ip "${LAN_IP}" "${LAN_NET}" router
