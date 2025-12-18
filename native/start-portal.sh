#!/usr/bin/env bash
# Inicio del portal cautivo en Linux nativo
# Uso: sudo ./start-portal.sh [config_file]
#
# Opción 2: DHCP con isc-dhcp-server + DNS externo (sin dnsmasq)

set -euo pipefail

# Verificar root
[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

# Cargar configuración
CONFIG_FILE="${1:-/etc/captive-portal/portal.conf}"
[[ -f "$CONFIG_FILE" ]] || {
  echo "Error: no existe $CONFIG_FILE. Ejecuta: sudo bash native/setup-native.sh"
  exit 1
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
: "${AUTH_TIMEOUT:=3600}"
: "${CERT_CN:=portal.hastalap}"
: "${APP_DIR:=/opt/captive-portal}"
: "${USERS_FILE:=/opt/captive-portal/app/users.json}"
: "${DHCP_DNS_1:=8.8.8.8}"
: "${DHCP_DNS_2:=1.1.1.1}"
: "${DHCP_RANGE_START:=100}"
: "${DHCP_RANGE_END:=200}"
: "${DHCP_LEASE:=12h}"

# Logging simple
log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# Asegura que una regla iptables exista. Revisa que exista (con -C) y
# prueba añadirla (con -A) si no la encuentra.
ensure_rule() {
  local check_cmd="$*"
  if eval "$check_cmd" >/dev/null 2>&1; then
    return 0
  fi
  local add_cmd="${check_cmd/ -C / -A }"
  if eval "$add_cmd" >/dev/null 2>&1; then
    log_info "Regla iptable aplicada: ${add_cmd}"
    return 0
  fi
  log_error "Fallo al asegurar regla iptable. Intentos: ${check_cmd} ; ${add_cmd}"
  return 1
}

# Util: netmask simple para /8,/16,/24 (suficiente para laboratorio)
cidr_to_netmask() {
  local cidr="$1"
  case "$cidr" in
    8)  echo "255.0.0.0" ;;
    16) echo "255.255.0.0" ;;
    24) echo "255.255.255.0" ;;
    *)  echo "255.255.255.0" ;; # fallback
  esac
}

# Verificar interfaces
ip link show "$UPLINK_IF" >/dev/null 2>&1 || { log_error "Interfaz WAN $UPLINK_IF no encontrada"; exit 1; }
ip link show "$LAN_IF" >/dev/null 2>&1 || { log_error "Interfaz LAN $LAN_IF no encontrada"; exit 1; }

# Configurar IP en LAN si no existe
if ! ip addr show "$LAN_IF" | grep -q "$LAN_IP"; then
  ip addr add "$LAN_IP/${LAN_CIDR##*/}" dev "$LAN_IF" 2>/dev/null || true
  ip link set "$LAN_IF" up
fi

# Habilitar IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# =========================
# NAT básico
# =========================
ensure_rule iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE || { log_error "Cannot apply MASQUERADE, aborting."; exit 1; }
ensure_rule iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || {
  ensure_rule iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT || { log_error "No se puede aplicar FORWARD RELATED,ESTABLISHED"; exit 1; }
}

# =========================
# DHCP con isc-dhcp-server
# =========================
# Permitir DHCP (servidor escucha UDP/67 en LAN)
ensure_rule iptables -C INPUT -i "$LAN_IF" -p udp --dport 67 -j ACCEPT || { log_error "No se pudo permitir DHCP (UDP/67)"; exit 1; }

# Forzar que isc-dhcp-server escuche SOLO en LAN_IF
cat > /etc/default/isc-dhcp-server <<EOF
INTERFACESv4="${LAN_IF}"
EOF

LAN_PREFIX="${LAN_IP%.*}"
CIDR_LEN="${LAN_CIDR##*/}"
NETMASK="$(cidr_to_netmask "$CIDR_LEN")"

DHCP_START="${LAN_PREFIX}.${DHCP_RANGE_START}"
DHCP_END="${LAN_PREFIX}.${DHCP_RANGE_END}"

cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 43200;
max-lease-time 43200;
authoritative;

subnet ${LAN_PREFIX}.0 netmask ${NETMASK} {
  range ${DHCP_START} ${DHCP_END};
  option routers ${LAN_IP};
  option domain-name-servers ${DHCP_DNS_1}, ${DHCP_DNS_2};
}
EOF

systemctl enable isc-dhcp-server >/dev/null 2>&1 || true
systemctl restart isc-dhcp-server || { log_error "No se pudo iniciar isc-dhcp-server"; exit 1; }
log_info "DHCP activo: ${DHCP_START} - ${DHCP_END} (GW=${LAN_IP}, DNS=${DHCP_DNS_1},${DHCP_DNS_2})"

# =========================
# ipset para IPs autenticadas
# =========================
ipset create authed hash:ip timeout "${AUTH_TIMEOUT}" -exist

# Cadenas personalizadas
iptables -t nat -N CP_REDIRECT 2>/dev/null || true
iptables -N CP_FILTER 2>/dev/null || true
iptables -t nat -F CP_REDIRECT 2>/dev/null || true
iptables -F CP_FILTER 2>/dev/null || true

# Permitir backend Python en LAN
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT || { log_error "No se pudo permitir backend $PORTAL_PORT"; exit 1; }

# Redirigir HTTP de no autenticados al portal (nginx en 80)
ensure_rule iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -m set ! --match-set authed src -j CP_REDIRECT || {
  log_error "No se pudo asegurar PREROUTING (HTTP→CP_REDIRECT)"; exit 1;
}
ensure_rule iptables -t nat -C CP_REDIRECT -p tcp -j DNAT --to-destination "${LAN_IP}:${NGINX_HTTP_PORT}" || {
  log_error "No se pudo asegurar DNAT en CP_REDIRECT"; exit 1;
}

# Limpiar reglas FORWARD previas
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || true

# Permitir autenticados, bloquear no autenticados
if iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null; then
  :
else
  iptables -I FORWARD 1 -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT || { log_error "No se pudo insertar FORWARD ACCEPT"; exit 1; }
  log_info "Insertada regla FORWARD ACCEPT para autenticados"
fi

ensure_rule iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -m set ! --match-set authed src -j REJECT --reject-with tcp-reset || {
  log_error "No se pudo asegurar REJECT HTTPS no autenticados"; exit 1;
}
ensure_rule iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT || { log_error "No se pudo asegurar REJECT general en FORWARD"; exit 1; }

# =========================
# Backend Python
# =========================
[[ -f "$APP_DIR/app/main.py" ]] || { echo "Error: no existe $APP_DIR/app/main.py"; exit 1; }
pkill -f "python3.*app.main" || true
sleep 1

export AUTH_TIMEOUT="$AUTH_TIMEOUT"
export USERS_FILE="$USERS_FILE"
cd "$APP_DIR"
python3 -u -m app.main "$PORTAL_PORT" >> /var/log/captive-portal/backend.log 2>&1 &
PORTAL_PID=$!
echo "$PORTAL_PID" > /var/run/captive-portal-backend.pid

# =========================
# nginx + TLS
# (no dependemos de DNS: redirigimos por IP LAN)
# =========================
TLS_KEY="/etc/captive-portal/ssl/portal.key"
TLS_CERT="/etc/captive-portal/ssl/portal.crt"

if [[ ! -f "$TLS_KEY" || ! -f "$TLS_CERT" ]]; then
  mkdir -p /etc/captive-portal/ssl
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TLS_KEY" -out "$TLS_CERT" \
    -days 365 -subj "/CN=${CERT_CN}" >/dev/null 2>&1
fi

rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true

cat > /etc/nginx/sites-available/captive-portal <<EOF
# Portal Cautivo - HTTP (detección y redirección)
server {
    listen ${NGINX_HTTP_PORT} default_server;
    server_name _;

    location = /captive {
        default_type text/html;
        return 200 '<!doctype html><html><head><meta charset="utf-8"><title>Portal cautivo</title></head><body><h1>Red con portal cautivo</h1><p>Portal detectado.</p><p><a href="https://${LAN_IP}/login">Iniciar sesión</a></p></body></html>';
    }

    # Android
    location = /generate_204 {
        return 302 https://${LAN_IP}/login;
    }

    # Windows
    location = /connecttest.txt {
        return 302 https://${LAN_IP}/login;
    }
    location = /ncsi.txt {
        return 302 https://${LAN_IP}/login;
    }

    # Apple
    location = /hotspot-detect.html {
        return 302 https://${LAN_IP}/login;
    }

    # Todo lo demás -> HTTPS por IP
    location / {
        return 302 https://${LAN_IP}\$request_uri;
    }
}

# Portal Cautivo - HTTPS (TLS)
server {
    listen ${NGINX_HTTPS_PORT} ssl;
    server_name _;

    ssl_certificate     ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:${PORTAL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/captive-portal /etc/nginx/sites-enabled/captive-portal

# Permitir nginx en firewall
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT || { log_error "No se pudo permitir HTTP nginx $NGINX_HTTP_PORT"; exit 1; }
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT || { log_error "No se pudo permitir HTTPS nginx $NGINX_HTTPS_PORT"; exit 1; }

nginx -t >/dev/null 2>&1
systemctl restart nginx

echo "Portal cautivo iniciado"
echo "URL (por IP): https://${LAN_IP}/login"
echo "Backend PID: $PORTAL_PID"
echo "LAN: $LAN_CIDR (Gateway: $LAN_IP)"
echo "Timeout: ${AUTH_TIMEOUT}s"
exit 0
