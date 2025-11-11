#!/usr/bin/env bash
set -euo pipefail

# Cliente entrypoint para conectarse a la LAN del portal cautivo
: "${ROUTER_IP:=10.200.0.254}"

log() { echo "[$(date +'%F %T')] $*"; }

# Ruta por defecto hacia el router
log "Configurando ruta por defecto vía ${ROUTER_IP}"
ip route replace default via "${ROUTER_IP}" || true

log "Entrypoint (client) terminado → ejecutando: $*"
exec "$@"
