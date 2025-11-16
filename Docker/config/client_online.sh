#!/usr/bin/env bash
set -euo pipefail

# Lanza clientes de prueba conectados a la LAN del portal cautivo
IMAGE="${IMAGE:-client:latest}"
# Nombre de la red LAN en Docker
LAN_NET="${LAN_NET:-lan0}"
# IP del gateway/router dentro de la LAN
ROUTER_IP="${ROUTER_IP:-10.200.0.254}"

# Función para crear un cliente con IP fija y acceso VNC
run_client () {
  local NAME="$1"; local IP="$2"; local PORT="$3"; local PW="$4"

  # Reemplaza si existe y arranca el contenedor con DNS apuntando al router
  docker rm -f "${NAME}" 2>/dev/null || true
  docker run -d --name "${NAME}" \
    --network "${LAN_NET}" --ip "${IP}" \
    --cap-add=NET_ADMIN \
    --dns "${ROUTER_IP}" \
    -e ROUTER_IP="${ROUTER_IP}" \
    -e VNC_PW="${PW}" \
    -e BROWSER_URL="${BROWSER_URL:-https://example.com}" \
    -p "${PORT}:6081" \
    "${IMAGE}" bash -lc '/entrypoint.sh /usr/local/bin/start-ui.sh'
}

# Tres clientes de ejemplo con diferentes IPs y puertos VNC
run_client c1 10.200.0.11 6081 "${C1_VNC_PW:-c1pass}"
run_client c2 10.200.0.12 6082 "${C2_VNC_PW:-c2pass}"
run_client c3 10.200.0.13 6083 "${C3_VNC_PW:-c3pass}"
