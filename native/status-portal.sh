#!/usr/bin/env bash
# Verificación del estado del portal cautivo
# Uso: sudo ./status-portal.sh

[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

echo "=== ESTADO DEL PORTAL CAUTIVO ==="
echo ""

echo "VERSIÓN:"
echo "  Instalada: $(cat /etc/captive-portal/VERSION 2>/dev/null || echo 'desconocida (instalación previa a update.sh)')"
echo ""

echo "SERVICIOS:"
systemctl is-active --quiet captive-portal 2>/dev/null && echo "  Backend (captive-portal): activo" || echo "  Backend (captive-portal): detenido"
systemctl is-active --quiet nginx 2>/dev/null && echo "  nginx: activo" || echo "  nginx: detenido"
systemctl is-active --quiet dnsmasq 2>/dev/null && echo "  DNS+DHCP (dnsmasq): activo" || echo "  DNS+DHCP (dnsmasq): detenido"
echo ""

echo "CONFIGURACIÓN:"
if [[ -f /etc/captive-portal/portal.conf ]]; then
  source /etc/captive-portal/portal.conf
  echo "  WAN: ${UPLINK_IF:-no configurado}"
  echo "  LAN: ${LAN_IF:-no configurado} (${LAN_IP:-no configurado})"
  echo "  Portal: https://${CERT_CN:-portal.hastalap}/login"
  echo "  Timeout: ${AUTH_TIMEOUT:-3600}s"
else
  echo "  Sin archivo de configuración (/etc/captive-portal/portal.conf)"
fi
echo ""

echo "TLS:"
TLS_MODE="${TLS_MODE:-self-signed}"
echo "  Modo: ${TLS_MODE}"
if [[ "$TLS_MODE" == "letsencrypt" ]]; then
  LE_CERT="/etc/letsencrypt/live/${CERT_CN:-portal.hastalap}/fullchain.pem"
  if [[ -f "$LE_CERT" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$LE_CERT" 2>/dev/null | sed 's/notAfter=//')
    echo "  Certificado Let's Encrypt: vigente, expira ${EXPIRY:-desconocido}"
  else
    echo "  Certificado Let's Encrypt: NO emitido todavía (usando autofirmado de respaldo)"
  fi
  systemctl is-active --quiet certbot.timer 2>/dev/null && echo "  Renovación automática (certbot.timer): activa" || echo "  Renovación automática (certbot.timer): inactiva"
else
  echo "  Certificado: autofirmado (o el que hayas colocado en TLS_CERT_PATH/TLS_KEY_PATH)"
fi
echo ""

echo "SESIONES AUTENTICADAS (IP,MAC):"
if ipset list authed >/dev/null 2>&1; then
  COUNT=$(ipset list authed | grep -c "^[0-9]" || echo 0)
  echo "  Total: $COUNT"
  if [[ $COUNT -gt 0 ]]; then
    ipset list authed | grep "^[0-9]" | sed 's/^/    /'
  fi
else
  echo "  Conjunto ipset 'authed' no existe"
fi
echo ""

echo "REGLAS IPTABLES:"
iptables -t nat -L CP_REDIRECT >/dev/null 2>&1 && echo "  Cadena CP_REDIRECT: configurada" || echo "  Cadena CP_REDIRECT: no existe"
[[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]] && echo "  IP forwarding: habilitado" || echo "  IP forwarding: deshabilitado"
echo ""

echo "LOGS (últimas 5 líneas):"
echo "  Backend (journalctl):"
journalctl -u captive-portal -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || echo "    (sin datos)"
echo ""

exit 0
