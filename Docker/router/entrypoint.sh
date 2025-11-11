#!/usr/bin/env bash
set -euo pipefail  # Exit on error, undefined var, or pipe failure

# Variables por defecto
: "${UPLINK_IF:=eth0}"      # Interfaz WAN (internet externa)
: "${LAN_IF:=eth1}"         # Interfaz LAN interna
: "${LAN_IP:=10.200.0.254}" # IP del router en la LAN
: "${LAN_CIDR:=10.200.0.0/24}" # Classless Inter-Domain Routing (la mascara vaya)

log() { echo "[$(date +'%F %T')] $*"; } # Para leer los logs mejor

log "Habilitando ip_forward"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true  # Necesario para que eth0 y eth1 se comuniquen

log "Asegurando reglas NAT (MASQUERADE) e inter-forwarding"
iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null ||   iptables -t nat -A POSTROUTING -o "$UPLINK_IF" -j MASQUERADE # SNAT para salir a internet
iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||   iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT # Activando la comunicacion eth0 → eth1
iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j ACCEPT 2>/dev/null ||   iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j ACCEPT # Activando la comunicacion eth1 → eth0

# ---------- DNS LOCAL con dnsmasq ----------
# Usa los resolvers del sistema (que Docker/host permiten).
if ! command -v dnsmasq >/dev/null 2>&1; then
  log "Instalando dnsmasq..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
fi

mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/lan.conf <<EOF  #Escribimos la configuración básica en dnsmasq
listen-address=${LAN_IP}            #Solo va a resolver peticiones DNS en la IP del router
interface=${LAN_IF}                 #Solo escucha en la interfaz LAN
bind-interfaces                     #Se asegura de ligar a la interfaz correcta

resolv-file=/etc/resolv.conf        #Usa los DNS del host/Docker (en este caso es Docker)
no-poll                             #No vigila cambios en resolv.conf

domain-needed                       #No resuelve nombres sin dominio
bogus-priv                          #No resuelve IPs privadas (RFC1918) desde WAN
cache-size=1000                    #Tamaño de caché DNS
EOF

# Abrir DNS en INPUT desde LAN
iptables -C INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null ||   iptables -A INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT  # DNS UDP
iptables -C INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null ||   iptables -A INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT  # DNS TCP

# Arrancar/recargar dnsmasq
if pgrep -x dnsmasq >/dev/null; then
  log "Recargando dnsmasq"
  killall -HUP dnsmasq || true
else
  log "Iniciando dnsmasq"
  dnsmasq --keep-in-foreground --conf-dir=/etc/dnsmasq.d,*.conf >/tmp/dnsmasq.log 2>&1 &
fi

log "Router listo. LAN=${LAN_CIDR}  LAN_IP=${LAN_IP}  DNS activo en ${LAN_IP}:53"
log "Entrypoint (router) terminado → ejecutando: $*"
exec "$@"
