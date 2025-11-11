#!/usr/bin/env bash
set -euo pipefail

ROLE="${ROLE:-client}"
log() { echo "[$(date +'%F %T')] $*"; }

if [[ "$ROLE" = "router" ]]; then
  # ---------- ROUTER ----------
  : "${UPLINK_IF:=eth0}"      # Hacia Internet/host
  : "${LAN_IF:=eth1}"         # Hacia LAN (red 'lan0')
  : "${LAN_IP:=10.200.0.254}" # IP del router en la LAN
  : "${LAN_CIDR:=10.200.0.0/24}"

  log "Habilitando ip_forward"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  log "Asegurando reglas NAT (MASQUERADE) e inter-forwarding"
  iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$UPLINK_IF" -j MASQUERADE
  iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j ACCEPT

  # ---------- DNS LOCAL con dnsmasq ----------
  # Usa los resolvers del sistema (que Docker/host permiten).
  if ! command -v dnsmasq >/dev/null 2>&1; then
    log "Instalando dnsmasq..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
  fi

  mkdir -p /etc/dnsmasq.d
  cat > /etc/dnsmasq.d/lan.conf <<EOF
# Escucha solo en la IP LAN del router:
listen-address=${LAN_IP}
interface=${LAN_IF}
bind-interfaces

# Reenvía usando los resolvers del sistema:
resolv-file=/etc/resolv.conf
no-poll

# Higiene/caché:
domain-needed
bogus-priv
cache-size=1000
EOF

  # Abrir DNS en INPUT desde LAN
  iptables -C INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT
  iptables -C INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT

  # Arrancar/recargar dnsmasq
  if pgrep -x dnsmasq >/dev/null; then
    log "Recargando dnsmasq"
    killall -HUP dnsmasq || true
  else
    log "Iniciando dnsmasq"
    dnsmasq --keep-in-foreground --conf-dir=/etc/dnsmasq.d,*.conf >/tmp/dnsmasq.log 2>&1 &
  fi

  log "Router listo. LAN=${LAN_CIDR}  LAN_IP=${LAN_IP}  DNS activo en ${LAN_IP}:53"

else
  # ---------- CLIENTE ----------
  : "${ROUTER_IP:=10.200.0.254}"

  # Ruta por defecto hacia el router
  log "Configurando ruta por defecto vía ${ROUTER_IP}"
  ip route replace default via "${ROUTER_IP}" || true

  # NO tocamos /etc/resolv.conf; los DNS vienen de --dns
fi

log "Entrypoint terminado → ejecutando: $*"
exec "$@"
