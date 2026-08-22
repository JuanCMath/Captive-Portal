#!/usr/bin/env bash
# Detiene el portal cautivo y limpia firewall/DNS/DHCP.
# Uso: sudo ./stop-portal.sh

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

CONFIG_FILE="/etc/captive-portal/portal.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi
UPLINK_IF="${UPLINK_IF:-enp0s3}"
LAN_IF="${LAN_IF:-enp0s8}"
NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-80}"
NGINX_HTTPS_PORT="${NGINX_HTTPS_PORT:-443}"
PORTAL_PORT="${PORTAL_PORT:-8080}"

# Detener servicios
systemctl stop captive-portal 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/captive-portal

# Destruir el ipset
ipset destroy authed 2>/dev/null || true

# Eliminar reglas FORWARD del portal (mismas specs que insertó start-portal.sh)
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src,src -j REJECT --reject-with tcp-reset 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src,src -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# Eliminar redirección NAT y la cadena personalizada
iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" \
  -m set ! --match-set authed src,src -j CP_REDIRECT 2>/dev/null || true
iptables -t nat -F CP_REDIRECT 2>/dev/null || true
iptables -t nat -X CP_REDIRECT 2>/dev/null || true
iptables -t nat -D POSTROUTING -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null || true

# Eliminar reglas INPUT (nginx, backend, DNS, DHCP) en LAN_IF
iptables -D INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j DROP 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p udp --dport 67 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true

# Eliminar reglas de bloqueo por la interfaz WAN
iptables -D INPUT -i "$UPLINK_IF" -p tcp --dport "$PORTAL_PORT" -j DROP 2>/dev/null || true
iptables -D INPUT -i "$UPLINK_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j DROP 2>/dev/null || true
iptables -D INPUT -i "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j DROP 2>/dev/null || true
iptables -D INPUT -i "$UPLINK_IF" -p udp --dport 53 -j DROP 2>/dev/null || true
iptables -D INPUT -i "$UPLINK_IF" -p tcp --dport 53 -j DROP 2>/dev/null || true
iptables -D INPUT -i "$UPLINK_IF" -p udp --dport 67 -j DROP 2>/dev/null || true

echo "Portal cautivo detenido"
exit 0
