#!/bin/sh
set -eu

# Defaults seguros por si no pasas variables
UPLINK_IF="${UPLINK_IF:-eth0}"
LAN_IF="${LAN_IF:-eth1}"
LAN_CIDR="${LAN_CIDR:-10.200.0.0/24}"

log() { echo "[router] $*"; }

wait_iface() {
  name="$1"
  tries=30
  while ! ip link show "$name" >/dev/null 2>&1; do
    tries=$((tries-1)) || true
    [ "$tries" -le 0 ] && log "ERROR: interfaz $name no aparece" && exit 1
    log "esperando interfaz $name ..."
    sleep 1
  done
}

# 1) Activar ip_forward (no fallar si el host lo prohíbe)
#  -> Lo ideal: pasar --sysctl net.ipv4.ip_forward=1 en docker run
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

# 2) Esperar a que existan ambas interfaces
wait_iface "$UPLINK_IF"
wait_iface "$LAN_IF"

# 3) Limpiar reglas previas (no fallar si no existen)
iptables -t nat -F || true
iptables -F || true

# 4) NAT LAN -> UPLINK (idempotente)
iptables -t nat -C POSTROUTING -s "$LAN_CIDR" -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$LAN_CIDR" -o "$UPLINK_IF" -j MASQUERADE

# 5) FORWARD LAN->UPLINK y retorno (idempotente)
iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -s "$LAN_CIDR" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -s "$LAN_CIDR" -j ACCEPT

iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -d "$LAN_CIDR" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -d "$LAN_CIDR" -m state --state ESTABLISHED,RELATED -j ACCEPT

log "reglas aplicadas. Manteniendo el contenedor vivo..."
exec "$@"
