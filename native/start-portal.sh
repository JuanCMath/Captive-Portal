#!/usr/bin/env bash
# Inicio del portal cautivo en Linux nativo
# Uso: sudo ./start-portal.sh [config_file]

set -euo pipefail

# Verificar root
[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

# Cargar configuración
CONFIG_FILE="${1:-/etc/captive-portal/portal.conf}"
[[ -f "$CONFIG_FILE" ]] || { echo "Error: no existe $CONFIG_FILE"; exit 1; }
source "$CONFIG_FILE"

# Defaults
: "${UPLINK_IF:=enp0s3}"
: "${LAN_IF:=enp0s8}"
: "${LAN_IP:=192.168.100.1}"
: "${LAN_CIDR:=192.168.100.0/24}"
: "${PORTAL_PORT:=8080}"
: "${NGINX_HTTP_PORT:=80}"
: "${NGINX_HTTPS_PORT:=443}"
: "${DNS_CACHE_SIZE:=1000}"
: "${AUTH_TIMEOUT:=3600}"
: "${CERT_CN:=portal.local}"
: "${APP_DIR:=/opt/captive-portal}"
: "${USERS_FILE:=/opt/captive-portal/app/users.json}"

# Verificar interfaces
ip link show "$UPLINK_IF" >/dev/null 2>&1 || { echo "Error: interfaz WAN $UPLINK_IF no encontrada"; exit 1; }
ip link show "$LAN_IF" >/dev/null 2>&1 || { echo "Error: interfaz LAN $LAN_IF no encontrada"; exit 1; }

# Configurar IP en LAN si no existe
if ! ip addr show "$LAN_IF" | grep -q "$LAN_IP"; then
  ip addr add "$LAN_IP/${LAN_CIDR##*/}" dev "$LAN_IF" 2>/dev/null || true
  ip link set "$LAN_IF" up
fi

# Habilitar IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# Configurar NAT
iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$UPLINK_IF" -j MASQUERADE
iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

# Configurar dnsmasq
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/captive-portal.conf <<EOF
listen-address=${LAN_IP}
interface=${LAN_IF}
bind-interfaces
resolv-file=/etc/resolv.conf
no-poll
domain-needed
bogus-priv
cache-size=${DNS_CACHE_SIZE}
address=/${CERT_CN}/${LAN_IP}
EOF

# Permitir DNS en firewall
iptables -C INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT
iptables -C INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT

# Iniciar/reiniciar dnsmasq
if pgrep -x dnsmasq >/dev/null; then
  killall -HUP dnsmasq
else
  dnsmasq --conf-dir=/etc/dnsmasq.d --log-facility=/var/log/captive-portal/dnsmasq.log &
fi

# Configurar ipset para IPs autenticadas
ipset create authed hash:ip timeout "${AUTH_TIMEOUT}" -exist

# Crear cadenas personalizadas
iptables -t nat -N CP_REDIRECT 2>/dev/null || true
iptables -N CP_FILTER 2>/dev/null || true
iptables -t nat -F CP_REDIRECT 2>/dev/null || true
iptables -F CP_FILTER 2>/dev/null || true

# Permitir backend Python en LAN
iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT

# Redirigir HTTP de no autenticados al portal
iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" \
  -m set ! --match-set authed src -j CP_REDIRECT 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" \
  -m set ! --match-set authed src -j CP_REDIRECT
iptables -t nat -A CP_REDIRECT -p tcp -j DNAT --to-destination "${LAN_IP}:${NGINX_HTTP_PORT}"

# Limpiar reglas FORWARD previas
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || true

# Permitir autenticados, bloquear no autenticados
iptables -I FORWARD 1 -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT

# Iniciar backend Python
[[ -f "$APP_DIR/app/main.py" ]] || { echo "Error: no existe $APP_DIR/app/main.py"; exit 1; }
pkill -f "python3.*app.main" || true
sleep 1

export AUTH_TIMEOUT="$AUTH_TIMEOUT"
export USERS_FILE="$USERS_FILE"
cd "$APP_DIR"
python3 -u -m app.main "$PORTAL_PORT" >> /var/log/captive-portal/backend.log 2>&1 &
PORTAL_PID=$!
echo "$PORTAL_PID" > /var/run/captive-portal-backend.pid

# Configurar nginx con TLS
TLS_KEY="/etc/captive-portal/ssl/portal.key"
TLS_CERT="/etc/captive-portal/ssl/portal.crt"

# Generar certificado TLS si no existe
if [[ ! -f "$TLS_KEY" || ! -f "$TLS_CERT" ]]; then
  mkdir -p /etc/captive-portal/ssl
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TLS_KEY" -out "$TLS_CERT" \
    -days 365 -subj "/CN=${CERT_CN}" >/dev/null 2>&1
fi

# Crear configuración de nginx
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

cat > /etc/nginx/sites-available/captive-portal <<EOF
# Portal Cautivo - HTTP (redirecciones)
server {
    listen ${NGINX_HTTP_PORT} default_server;
    server_name _;

    # Endpoint de detección manual
    location = /captive {
        default_type text/html;
        return 200 '<!doctype html><html><head><meta charset="utf-8"><title>Portal cautivo</title></head><body><h1>Red con portal cautivo</h1><p>Tu dispositivo ha detectado un portal cautivo en esta red.</p><p><a href="https://${CERT_CN}/login">Haz clic aquí para iniciar sesión</a>.</p></body></html>';
    }

    # Detección automática - Android
    location = /generate_204 {
        return 302 https://${CERT_CN}/login;
    }

    # Detección automática - Windows
    location = /connecttest.txt {
        return 302 https://${CERT_CN}/login;
    }

    location = /ncsi.txt {
        return 302 https://${CERT_CN}/login;
    }

    # Detección automática - Apple
    location = /hotspot-detect.html {
        return 302 https://${CERT_CN}/login;
    }

    # Redirigir todo lo demás a HTTPS
    location / {
        return 302 https://${CERT_CN}\$request_uri;
    }
}

# Portal Cautivo - HTTPS (TLS)
server {
    listen ${NGINX_HTTPS_PORT} ssl;
    server_name ${CERT_CN};

    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;

    # Proxy hacia backend Python
    location / {
        proxy_pass http://127.0.0.1:${PORTAL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Activar sitio nginx
ln -sf /etc/nginx/sites-available/captive-portal /etc/nginx/sites-enabled/captive-portal

# Permitir nginx en firewall
iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT
iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT

# Reiniciar nginx
nginx -t >/dev/null 2>&1
systemctl restart nginx

# Resumen
echo "Portal cautivo iniciado"
echo "URL: https://${CERT_CN}"
echo "Backend PID: $PORTAL_PID"
echo "LAN: $LAN_CIDR (Gateway: $LAN_IP)"
echo "Timeout: ${AUTH_TIMEOUT}s"
exit 0
