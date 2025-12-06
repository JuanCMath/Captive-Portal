#!/usr/bin/env bash
# Detención del portal cautivo en Linux nativo
# Uso: sudo ./stop-portal.sh

set -euo pipefail

# Verificar root
[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

# Detener backend Python
if [[ -f /var/run/captive-portal-backend.pid ]]; then
  PID=$(cat /var/run/captive-portal-backend.pid)
  kill "$PID" 2>/dev/null || true
  rm -f /var/run/captive-portal-backend.pid
fi
pkill -f "python3.*app.main" || true

# Detener nginx
systemctl stop nginx 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/captive-portal

# Detener dnsmasq
killall dnsmasq 2>/dev/null || true
rm -f /etc/dnsmasq.d/captive-portal.conf

# Destruir ipset
ipset destroy authed 2>/dev/null || true

# Limpiar iptables
CONFIG_FILE="/etc/captive-portal/portal.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi
UPLINK_IF="${UPLINK_IF:-enp0s3}"
LAN_IF="${LAN_IF:-enp0s8}"
NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-80}"
NGINX_HTTPS_PORT="${NGINX_HTTPS_PORT:-443}"
PORTAL_PORT="${PORTAL_PORT:-8080}"

# Eliminar reglas FORWARD
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null || true

# Eliminar redirección NAT
iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" \
  -m set ! --match-set authed src -j CP_REDIRECT 2>/dev/null || true

# Eliminar cadenas personalizadas
iptables -t nat -F CP_REDIRECT 2>/dev/null || true
iptables -F CP_FILTER 2>/dev/null || true
iptables -t nat -X CP_REDIRECT 2>/dev/null || true
iptables -X CP_FILTER 2>/dev/null || true

# Eliminar reglas INPUT
iptables -D INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true

echo "Portal cautivo detenido"
exit 0
