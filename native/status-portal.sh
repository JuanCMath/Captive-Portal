#!/usr/bin/env bash
# Verificación del estado del portal cautivo
# Uso: sudo ./status-portal.sh
#
# Opción 2: isc-dhcp-server (DHCP) + DNS externo (sin dnsmasq)

[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

echo "=== ESTADO DEL PORTAL CAUTIVO ==="
echo ""

echo "SERVICIOS:"
pgrep -f "python3.*app.main" >/dev/null && echo "  Backend Python: activo (PID: $(pgrep -f 'python3.*app.main'))" || echo "  Backend Python: detenido"
systemctl is-active --quiet nginx 2>/dev/null && echo "  nginx: activo" || echo "  nginx: detenido"
systemctl is-active --quiet isc-dhcp-server 2>/dev/null && echo "  DHCP (isc-dhcp-server): activo" || echo "  DHCP (isc-dhcp-server): detenido"
echo ""

echo "CONFIGURACIÓN:"
if [[ -f /etc/captive-portal/portal.conf ]]; then
  source /etc/captive-portal/portal.conf
  echo "  WAN: ${UPLINK_IF:-no configurado}"
  echo "  LAN: ${LAN_IF:-no configurado} (${LAN_IP:-no configurado})"
  echo "  Portal: https://${LAN_IP:-192.168.100.1}/login"
  echo "  Timeout: ${AUTH_TIMEOUT:-3600}s"
else
  echo "  Sin archivo de configuración"
fi
echo ""

echo "IPS AUTENTICADAS:"
if ipset list authed >/dev/null 2>&1; then
  COUNT=$(ipset list authed | grep -c "^[0-9]" || echo 0)
  echo "  Total: $COUNT IP(s)"
  if [[ $COUNT -gt 0 ]]; then
    ipset list authed | grep "^[0-9]" | sed 's/^/    /'
  fi
else
  echo "  Conjunto ipset no existe"
fi
echo ""

echo "REGLAS IPTABLES:"
iptables -t nat -L CP_REDIRECT >/dev/null 2>&1 && echo "  Cadena CP_REDIRECT: configurada" || echo "  Cadena CP_REDIRECT: no existe"
[[ $(cat /proc/sys/net/ipv4/ip_forward) -eq 1 ]] && echo "  IP forwarding: habilitado" || echo "  IP forwarding: deshabilitado"
echo ""

echo "LOGS (últimas 5 líneas):"
if [[ -f /var/log/captive-portal/backend.log ]]; then
  echo "  Backend:"
  tail -5 /var/log/captive-portal/backend.log | sed 's/^/    /'
fi
echo ""

exit 0
