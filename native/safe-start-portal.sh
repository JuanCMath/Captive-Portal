#!/usr/bin/env bash
# Inicio del portal cautivo en Linux nativo
# Uso: sudo ./start-portal.sh [config_file]

set -euo pipefail

# Verificar root
[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

# Cargar configuración
CONFIG_FILE="${1:-/etc/captive-portal/portal.conf}"
[[ -f "$CONFIG_FILE" ]] || 
{ 
  echo "Error: no existe $CONFIG_FILE. Ejecuta: sudo bash native/setup-native.sh"; 
  exit 1; 
}
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

# Simple logging
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# Ensure an iptables rule exists: provide the check form (with -C); function
# will try the equivalent -A if -C fails, and error out if both fail.
ensure_rule() {
  local check_cmd="$*"
  # If check succeeds, we're done
  if eval "$check_cmd" >/dev/null 2>&1; then
    return 0
  fi
  # Try replacing first ' -C ' with ' -A ' to add the rule
  local add_cmd="${check_cmd/ -C / -A }"
  if eval "$add_cmd" >/dev/null 2>&1; then
    log_info "Applied iptables rule: ${add_cmd}"
    return 0
  fi
  log_error "Failed to ensure iptables rule. Tried: ${check_cmd} ; then: ${add_cmd}"
  return 1
}

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
ensure_rule iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE || { log_error "Cannot apply MASQUERADE, aborting."; exit 1; }
# Prefer conntrack match but keep the same check form; ensure_rule will try to add if missing.
ensure_rule iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || {
  # Fallback to state match for older systems
  ensure_rule iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT || { log_error "Cannot apply FORWARD RELATED,ESTABLISHED rule, aborting."; exit 1; }
}

# Configurar dnsmasq
mkdir -p /etc/dnsmasq.d

# Eliminar antiguas configuraciones que puedan contener directivas repetidas.
rm -f /etc/dnsmasq.d/captive-portal.conf /etc/dnsmasq.d/lan.conf 2>/dev/null || true

# Usar un único archivo de configuración consistente (/etc/dnsmasq.d/portal.conf)
cat > /etc/dnsmasq.d/portal.conf <<EOF
# DNS/DHCP configuration for captive portal
listen-address=${LAN_IP}
interface=${LAN_IF}
bind-interfaces
resolv-file=/etc/resolv.conf
# Upstream DNS servers
server=8.8.8.8
server=8.8.4.4
no-poll
domain-needed
bogus-priv
cache-size=${DNS_CACHE_SIZE}
# Map portal hostname to router
address=/${CERT_CN}/${LAN_IP}
# DHCP range and options
dhcp-range=${LAN_IP%.*}.100,${LAN_IP%.*}.200,12h
dhcp-option=3,${LAN_IP}
dhcp-option=6,${LAN_IP}
dhcp-option=28,${LAN_IP%.*}.255
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

# Permitir DNS en firewall
ensure_rule iptables -C INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT || { log_error "Failed to allow UDP DNS on $LAN_IF"; exit 1; }
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT || { log_error "Failed to allow TCP DNS on $LAN_IF"; exit 1; }

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
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT || { log_error "Failed to allow backend port $PORTAL_PORT on $LAN_IF"; exit 1; }

# Redirigir HTTP de no autenticados al portal
ensure_rule iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -m set ! --match-set authed src -j CP_REDIRECT || { log_error "Failed to ensure PREROUTING redirect rule"; exit 1; }
ensure_rule iptables -t nat -C CP_REDIRECT -p tcp -j DNAT --to-destination "${LAN_IP}:${NGINX_HTTP_PORT}" || { log_error "Failed to ensure CP_REDIRECT DNAT"; exit 1; }

# Limpiar reglas FORWARD previas
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || true

# Permitir autenticados, bloquear no autenticados (idempotente)
# Aceptar tráfico autenticado: preferimos insertar al principio si no existe
if iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null; then
  :
else
  iptables -I FORWARD 1 -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT || { log_error "Failed to insert FORWARD ACCEPT for authed"; exit 1; }
  log_info "Inserted FORWARD ACCEPT for authed"
fi

ensure_rule iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -m set ! --match-set authed src -j REJECT --reject-with tcp-reset || { log_error "Failed to ensure HTTPS REJECT for unauthenticated"; exit 1; }
ensure_rule iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT || { log_error "Failed to ensure general FORWARD REJECT"; exit 1; }

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


# Eliminar cualquier sitio nginx previamente habilitado para evitar 'duplicate default server'
rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true

# Crear configuración de nginx
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
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT || { log_error "Failed to allow nginx HTTP port $NGINX_HTTP_PORT on $LAN_IF"; exit 1; }
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT || { log_error "Failed to allow nginx HTTPS port $NGINX_HTTPS_PORT on $LAN_IF"; exit 1; }

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
