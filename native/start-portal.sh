#!/usr/bin/env bash
# Aplica firewall/DNS/DHCP e inicia el portal cautivo en Linux nativo.
# Uso: sudo ./start-portal.sh [config_file]
#
# Idempotente: se puede volver a correr tras cambiar portal.conf sin
# duplicar reglas de iptables (ver ensure_rule más abajo).

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

CONFIG_FILE="${1:-/etc/captive-portal/portal.conf}"
[[ -f "$CONFIG_FILE" ]] || {
  echo "Error: no existe $CONFIG_FILE. Ejecuta primero: sudo ./install.sh"
  exit 1
}
source "$CONFIG_FILE"

# Defaults (por si portal.conf no define alguna clave)
: "${UPLINK_IF:=enp0s3}"
: "${LAN_IF:=enp0s8}"
: "${LAN_IP:=192.168.100.1}"
: "${LAN_CIDR:=192.168.100.0/24}"
: "${PORTAL_PORT:=8080}"
: "${NGINX_HTTP_PORT:=80}"
: "${NGINX_HTTPS_PORT:=443}"
: "${AUTH_TIMEOUT:=3600}"
: "${CERT_CN:=portal.hastalap}"
: "${DNS_CACHE_SIZE:=1000}"
: "${TLS_MODE:=self-signed}"
: "${TLS_CERT_PATH:=/etc/captive-portal/ssl/portal.crt}"
: "${TLS_KEY_PATH:=/etc/captive-portal/ssl/portal.key}"
: "${LETSENCRYPT_EMAIL:=}"
: "${DHCP_RANGE_START:=100}"
: "${DHCP_RANGE_END:=200}"
: "${DHCP_LEASE:=12h}"

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# Asegura que una regla iptables exista: la comprueba con -C y, si no está,
# la añade con -A. Repetir el script no duplica reglas.
ensure_rule() {
  local check_cmd="$*"
  if eval "$check_cmd" >/dev/null 2>&1; then
    return 0
  fi
  local add_cmd="${check_cmd/ -C / -A }"
  if eval "$add_cmd" >/dev/null 2>&1; then
    log_info "Regla iptables aplicada: ${add_cmd}"
    return 0
  fi
  log_error "Fallo al asegurar regla iptables. Intentos: ${check_cmd} ; ${add_cmd}"
  return 1
}

# Verificar interfaces
ip link show "$UPLINK_IF" >/dev/null 2>&1 || { log_error "Interfaz WAN $UPLINK_IF no encontrada"; exit 1; }
ip link show "$LAN_IF" >/dev/null 2>&1 || { log_error "Interfaz LAN $LAN_IF no encontrada"; exit 1; }

# Configurar IP en LAN si no existe
if ! ip addr show "$LAN_IF" | grep -q "$LAN_IP"; then
  ip addr add "$LAN_IP/${LAN_CIDR##*/}" dev "$LAN_IF" 2>/dev/null || true
  ip link set "$LAN_IF" up
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

# =========================
# NAT básico
# =========================
ensure_rule iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE || { log_error "No se pudo aplicar MASQUERADE"; exit 1; }
ensure_rule iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT || { log_error "No se pudo aplicar FORWARD RELATED,ESTABLISHED"; exit 1; }

# =========================
# DNS + DHCP (dnsmasq)
# =========================
mkdir -p /etc/dnsmasq.d
LAN_PREFIX="${LAN_IP%.*}"
DHCP_START="${LAN_PREFIX}.${DHCP_RANGE_START}"
DHCP_END="${LAN_PREFIX}.${DHCP_RANGE_END}"

cat > /etc/dnsmasq.d/captive-portal.conf <<EOF
# === DNS ===
listen-address=${LAN_IP}
interface=${LAN_IF}
bind-interfaces
resolv-file=/etc/resolv.conf
no-poll
domain-needed
bogus-priv
cache-size=${DNS_CACHE_SIZE}

# Resolver ${CERT_CN} al propio router
address=/${CERT_CN}/${LAN_IP}

# === DHCP ===
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
dhcp-option=3,${LAN_IP}
dhcp-option=6,${LAN_IP}
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF

mkdir -p /var/lib/misc
systemctl enable dnsmasq >/dev/null 2>&1 || true
systemctl restart dnsmasq || { log_error "No se pudo iniciar dnsmasq"; exit 1; }
log_info "DNS+DHCP activos: ${DHCP_START} - ${DHCP_END} (gateway/DNS=${LAN_IP}, dominio=${CERT_CN})"

ensure_rule iptables -C INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT || { log_error "No se pudo permitir DNS UDP/53"; exit 1; }
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT || { log_error "No se pudo permitir DNS TCP/53"; exit 1; }
ensure_rule iptables -C INPUT -i "$LAN_IF" -p udp --dport 67 -j ACCEPT || { log_error "No se pudo permitir DHCP UDP/67"; exit 1; }

# =========================
# ipset + iptables (portal cautivo)
# =========================
# hash:ip,mac (no hash:ip): vincula la sesión a IP+MAC, no solo a la IP,
# para que un dispositivo distinto que reciba la misma IP (p.ej. tras
# expirar un lease DHCP) no herede la sesión de quien la tuvo antes.
ipset create authed hash:ip,mac timeout "${AUTH_TIMEOUT}" -exist

iptables -t nat -N CP_REDIRECT 2>/dev/null || true
iptables -t nat -F CP_REDIRECT

# Backend Python: solo accesible vía nginx (loopback), nunca directo desde
# la LAN -- si un cliente pudiera hablarle directo, podría falsificar
# X-Real-IP y suplantar la sesión de otra IP.
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j DROP || true

ensure_rule iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -m set ! --match-set authed src,src -j CP_REDIRECT || {
  log_error "No se pudo asegurar PREROUTING (HTTP -> CP_REDIRECT)"; exit 1;
}
ensure_rule iptables -t nat -C CP_REDIRECT -p tcp -j DNAT --to-destination "${LAN_IP}:${NGINX_HTTP_PORT}" || {
  log_error "No se pudo asegurar DNAT en CP_REDIRECT"; exit 1;
}

# Limpiar reglas FORWARD previas del portal antes de reinsertarlas en orden
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src,src -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src,src -j REJECT --reject-with tcp-reset 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || true

iptables -I FORWARD 1 -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src,src -j ACCEPT || { log_error "No se pudo insertar FORWARD ACCEPT"; exit 1; }
ensure_rule iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -m set ! --match-set authed src,src -j REJECT --reject-with tcp-reset || {
  log_error "No se pudo asegurar REJECT HTTPS no autenticados"; exit 1;
}
ensure_rule iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT || { log_error "No se pudo asegurar REJECT general en FORWARD"; exit 1; }

# =========================
# nginx + TLS
# =========================
# Rutas del certificado de Let's Encrypt (certbot las gestiona internamente
# vía el symlink "live"; no cambian entre renovaciones).
LE_CERT="/etc/letsencrypt/live/${CERT_CN}/fullchain.pem"
LE_KEY="/etc/letsencrypt/live/${CERT_CN}/privkey.pem"

mkdir -p "$(dirname "$TLS_CERT_PATH")" "$(dirname "$TLS_KEY_PATH")"

# Certificado autofirmado como base: sirve de default (TLS_MODE=self-signed)
# y también de arranque inicial en TLS_MODE=letsencrypt, porque nginx
# necesita *algún* certificado ya presente para levantar su bloque HTTPS
# antes de que exista uno real (huevo y gallina con el reto ACME, que
# necesita nginx ya corriendo). Si el admin ya colocó su propio cert/key
# aquí ("traer el tuyo"), no se toca.
if [[ ! -f "$TLS_KEY_PATH" || ! -f "$TLS_CERT_PATH" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "$TLS_KEY_PATH" -out "$TLS_CERT_PATH" \
    -days 365 -subj "/CN=${CERT_CN}" >/dev/null 2>&1
fi

if [[ "$TLS_MODE" == "letsencrypt" && -f "$LE_CERT" && -f "$LE_KEY" ]]; then
  ACTIVE_CERT="$LE_CERT"
  ACTIVE_KEY="$LE_KEY"
else
  ACTIVE_CERT="$TLS_CERT_PATH"
  ACTIVE_KEY="$TLS_KEY_PATH"
fi

rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/captive-portal

# Escribe /etc/nginx/sites-available/captive-portal apuntando al cert/key
# recibidos. Se llama una vez con el certificado base (arriba) y, si
# Let's Encrypt emite uno nuevo más abajo, otra vez con ese.
write_nginx_conf() {
  local cert="$1" key="$2"
  cat > /etc/nginx/sites-available/captive-portal <<EOF
server {
    listen ${NGINX_HTTP_PORT} default_server;
    server_name _;

    # Reto ACME de Let's Encrypt (TLS_MODE=letsencrypt). Prefijo más
    # específico que el resto de location de abajo, así que siempre gana
    # cuando aplica. Inofensivo si no se usa: el directorio queda vacío.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # --- Detección automática de portal cautivo ---
    location = /generate_204 {
        return 204;  # Android
    }
    location = /connecttest.txt {
        default_type text/plain;
        return 200 "Microsoft Connect Test";  # Windows
    }
    location = /ncsi.txt {
        default_type text/plain;
        return 200 "Microsoft NCSI";
    }
    location = /hotspot-detect.html {
        default_type text/html;
        return 200 '<html><body>Success</body></html>';  # iOS/macOS
    }
    location = /check_network_status.txt {
        default_type text/plain;
        return 200 "NetworkManager";  # Linux/GNOME
    }
    location = /captive {
        default_type text/html;
        return 200 '<!doctype html><html><head><meta charset="utf-8"><title>Portal Cautivo</title></head><body><h1>Portal cautivo detectado</h1><p><a href="https://${CERT_CN}/login">Iniciar sesión</a></p></body></html>';
    }

    location / {
        return 302 https://${CERT_CN}\$request_uri;
    }
}

server {
    listen ${NGINX_HTTPS_PORT} ssl http2 default_server;
    server_name ${CERT_CN};

    ssl_certificate     ${cert};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:${PORTAL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

write_nginx_conf "$ACTIVE_CERT" "$ACTIVE_KEY"
ln -sf /etc/nginx/sites-available/captive-portal /etc/nginx/sites-enabled/captive-portal

ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT || { log_error "No se pudo permitir HTTP nginx"; exit 1; }
ensure_rule iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT || { log_error "No se pudo permitir HTTPS nginx"; exit 1; }

# Las reglas anteriores solo ACEPTAN desde LAN_IF; si el equipo tiene IP
# pública en UPLINK_IF, el panel/backend/DNS quedarían igual de alcanzables
# desde ahí. Se bloquean explícitamente por la interfaz WAN.
ensure_rule iptables -C INPUT -i "$UPLINK_IF" -p tcp --dport "$PORTAL_PORT" -j DROP || true

# El puerto 80 en WAN es la única excepción, y solo en TLS_MODE=letsencrypt:
# Let's Encrypt necesita alcanzar este equipo por HTTP para validar el
# dominio (reto ACME). 443/backend/DNS/DHCP en WAN siguen bloqueados
# siempre, en cualquier modo. Se limpia el estado previo (DROP o ACCEPT)
# antes de reaplicar, para que cambiar TLS_MODE entre corridas converja
# bien y no deje ambas reglas puestas a la vez.
iptables -D INPUT -i "$UPLINK_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j DROP 2>/dev/null || true
iptables -D INPUT -i "$UPLINK_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT 2>/dev/null || true
if [[ "$TLS_MODE" == "letsencrypt" ]]; then
  ensure_rule iptables -C INPUT -i "$UPLINK_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j ACCEPT || { log_error "No se pudo abrir el puerto 80 en WAN para Let's Encrypt"; exit 1; }
  log_info "TLS_MODE=letsencrypt: puerto 80 abierto en $UPLINK_IF para el reto ACME"
else
  ensure_rule iptables -C INPUT -i "$UPLINK_IF" -p tcp --dport "$NGINX_HTTP_PORT" -j DROP || true
fi

ensure_rule iptables -C INPUT -i "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j DROP || true
ensure_rule iptables -C INPUT -i "$UPLINK_IF" -p udp --dport 53 -j DROP || true
ensure_rule iptables -C INPUT -i "$UPLINK_IF" -p tcp --dport 53 -j DROP || true
ensure_rule iptables -C INPUT -i "$UPLINK_IF" -p udp --dport 67 -j DROP || true

nginx -t >/dev/null 2>&1 || { log_error "Configuración de nginx inválida"; exit 1; }
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx

# =========================
# Let's Encrypt (si aplica)
# =========================
if [[ "$TLS_MODE" == "letsencrypt" && ! ( -f "$LE_CERT" && -f "$LE_KEY" ) ]]; then
  if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
    log_error "TLS_MODE=letsencrypt requiere LETSENCRYPT_EMAIL en portal.conf"
    exit 1
  fi
  log_info "Solicitando certificado Let's Encrypt para ${CERT_CN}..."
  mkdir -p /var/log/captive-portal
  if certbot certonly --webroot -w /var/www/certbot -d "$CERT_CN" \
       -m "$LETSENCRYPT_EMAIL" --agree-tos --non-interactive \
       --deploy-hook "systemctl reload nginx" \
       >/var/log/captive-portal/certbot-issue.log 2>&1; then
    log_info "Certificado emitido, recargando nginx con el certificado real"
    write_nginx_conf "$LE_CERT" "$LE_KEY"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
  else
    log_error "No se pudo emitir el certificado Let's Encrypt (detalle en /var/log/captive-portal/certbot-issue.log). Seguimos con el autofirmado; verifica que ${CERT_CN} resuelva a este equipo y que el puerto 80 sea alcanzable desde Internet."
  fi
fi

# certbot.timer (paquete Debian) reintenta la renovación dos veces al día;
# el --deploy-hook de la emisión inicial queda grabado y se reutiliza en
# cada renovación automática.
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

# =========================
# Backend (systemd)
# =========================
systemctl restart captive-portal || { log_error "No se pudo iniciar el servicio captive-portal"; exit 1; }

echo ""
echo "Portal cautivo iniciado"
echo "URL: https://${CERT_CN}/login"
echo "LAN: $LAN_CIDR (gateway/DNS: $LAN_IP)"
echo "Timeout de sesión: ${AUTH_TIMEOUT}s"
exit 0
