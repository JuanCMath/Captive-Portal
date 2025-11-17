#!/usr/bin/env bash
set -euo pipefail

#####################################
#           VARIABLES
#####################################
: "${UPLINK_IF:=eth0}"                 # WAN
: "${LAN_IF:=eth1}"                    # LAN
: "${LAN_IP:=10.200.0.254}"            # IP router LAN
: "${LAN_CIDR:=10.200.0.0/24}"         # Subred LAN
: "${PORTAL_PORT:=8080}"               # Puerto backend Python
: "${NGINX_HTTP_PORT:=80}"             # Puerto HTTP (redirige a HTTPS)
: "${NGINX_HTTPS_PORT:=443}"           # Puerto HTTPS
: "${DNS_CACHE_SIZE:=1000}"
: "${AUTH_TIMEOUT:=3600}"              # Timeout ipset
: "${CERT_CN:=portal.local}"           # Nombre del certificado TLS
: "${BROWSER_URL:=}"                   # noVNC (opcional)

log(){ echo "[$(date +'%F %T')] $*"; }

#####################################
#        CONFIG SISTEMA BASE
#####################################

log "Habilitando ip_forward"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

log "Configurando NAT (LAN -> WAN)"
iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$UPLINK_IF" -j MASQUERADE

iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

#####################################
#  ESPERAR LAN IP
#####################################

for i in {1..20}; do
  if ip addr show "$LAN_IF" | grep -q "$LAN_IP"; then
    log "Interfaz LAN lista con IP $LAN_IP"
    break
  fi
  log "Esperando IP en $LAN_IF..."
  sleep 1
done

#####################################
#              DNSMASQ
#####################################

if ! command -v dnsmasq >/dev/null; then
  apt-get update -y && apt-get install -y dnsmasq
fi

mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/lan.conf <<EOF
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

iptables -C INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null || \
iptables -A INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT

iptables -C INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
iptables -A INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT

pgrep -x dnsmasq >/dev/null \
  && killall -HUP dnsmasq || \
  dnsmasq --keep-in-foreground --conf-dir=/etc/dnsmasq.d >/tmp/dnsmasq.log 2>&1 &

#####################################
#     IPSET + IPTABLES (PORTAL)
#####################################

log "Creando ipset authed"
ipset create authed hash:ip timeout "${AUTH_TIMEOUT}" -exist

# Cadenas
iptables -t nat -N CP_REDIRECT 2>/dev/null || true
iptables -N CP_FILTER 2>/dev/null || true
iptables -t nat -F CP_REDIRECT || true
iptables -F CP_FILTER || true

# Permitir backend Python en LAN
iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT 2>/dev/null || \
iptables -A INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT

# Redirigir NO autenticados HTTP 80 -> portal
iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" \
  -m set ! --match-set authed src -j CP_REDIRECT 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" \
       -m set ! --match-set authed src -j CP_REDIRECT

# CP_REDIRECT → DNAT hacia nginx:80
iptables -t nat -F CP_REDIRECT
iptables -t nat -A CP_REDIRECT -p tcp -j DNAT --to-destination "${LAN_IP}:${NGINX_HTTP_PORT}"

# --- Orden correcto de reglas FORWARD ---

iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || true

# AUTENTICADOS → Internet OK
iptables -I FORWARD 1 -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT

# NO autenticados → HTTPS Bloqueado
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport "$NGINX_HTTPS_PORT" \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset

# NO autenticados → bloquear todo
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT

#####################################
#        BACKEND PYTHON
#####################################

log "Iniciando backend Python en puerto ${PORTAL_PORT}"
cd /app
python3 -u -m app.main "${PORTAL_PORT}" &
PORTAL_PID=$!

#####################################
#        NGINX + TLS
#####################################

TLS_KEY="/etc/ssl/private/portal.key"
TLS_CERT="/etc/ssl/certs/portal.crt"

rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

if [[ ! -f "$TLS_KEY" || ! -f "$TLS_CERT" ]]; then
  log "Generando certificado TLS CN=${CERT_CN}"
  mkdir -p /etc/ssl/private /etc/ssl/certs
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TLS_KEY" \
    -out "$TLS_CERT" \
    -days 365 \
    -subj "/CN=${CERT_CN}" >/dev/null 2>&1
fi

cat >/etc/nginx/conf.d/portal.conf <<EOF
server {
    listen ${NGINX_HTTP_PORT} default_server;
    server_name _;

    # --- Endpoint explícito de detección manual ---
    # Si en un cliente abres http://<IP_ROUTER>/captive ves una página clara.
    location = /captive {
        default_type text/html;
        return 200 '<!doctype html><html><head><meta charset="utf-8"><title>Portal cautivo</title></head><body><h1>Red con portal cautivo</h1><p>Tu dispositivo ha detectado un portal cautivo en esta red.</p><p><a href="https://${CERT_CN}/login">Haz clic aquí para iniciar sesión de forma segura</a>.</p></body></html>';
    }

    # --- Rutas típicas de detección de portal cautivo ---
    # Android
    location = /generate_204 {
        return 302 https://${CERT_CN}/login;
    }

    # Windows
    location = /connecttest.txt {
        return 302 https://${CERT_CN}/login;
    }

    location = /ncsi.txt {
        return 302 https://${CERT_CN}/login;
    }

    # Apple
    location = /hotspot-detect.html {
        return 302 https://${CERT_CN}/login;
    }

    location = / {
        # Cualquier otro HTTP (usuario no autenticado, gracias a iptables)
        # también será redirigido al portal HTTPS.
        return 302 https://${CERT_CN}\$request_uri;
    }
}

server {
    listen ${NGINX_HTTPS_PORT} ssl;
    server_name ${CERT_CN};

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


iptables -C INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT 2>/dev/null \
  || iptables -A INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT

log "Arrancando nginx"
nginx -g "daemon off;" &

#####################################
#              UI opcional
#####################################

if [[ -n "$BROWSER_URL" ]]; then
  /usr/local/bin/start-ui.sh &
fi

log "Router listo. Portal en https://${CERT_CN}"

wait "$PORTAL_PID"
