#!/usr/bin/env bash
set -euo pipefail

# ---------- Vars ----------
: "${UPLINK_IF:=eth0}"            # Interfaz con salida a internet 
: "${LAN_IF:=eth1}"               # Interfaz de la LAN
: "${LAN_IP:=10.200.0.254}"       # IP del router
: "${LAN_CIDR:=10.200.0.0/24}"    # LAN MASK
: "${PORTAL_PORT:=80}"            # Portal HTTP (donde se levanta el servidor de FastAPI)
: "${DNS_CACHE_SIZE:=1000}"
: "${AUTH_TIMEOUT:=3600}"         # seg. en ipset
: "${BROWSER_URL:=}"              # URL por defecto al abrir noVNC

log(){ echo "[$(date +'%F %T')] $*"; }

# ---------- Routing base ----------
log "Habilitando ip_forward"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true  #Activa el reenvio de paquetes entre interfaces (eth0 <-> eth1)

log "Reglas NAT WAN<->LAN"
iptables -t nat -C POSTROUTING -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$UPLINK_IF" -j MASQUERADE # Enmascara todos los paquetes que salgan por eth0 dandole la misma IP a todos
iptables -C FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT #Acepta el trafico eth0 -> eth1 si cumple con RELATED o ESTABLISHED

# ---------- Esperar a que la interfaz LAN exista con la IP correcta ----------
for i in {1..20}; do
  if ip addr show "$LAN_IF" >/dev/null 2>&1 && ip addr show "$LAN_IF" | grep -q "$LAN_IP"; then
    log "Interfaz ${LAN_IF} lista con IP ${LAN_IP}"
    break
  fi
  log "Esperando a que ${LAN_IF} tenga IP ${LAN_IP}..."
  sleep 1
done

# ---------- DNS local con dnsmasq ----------
if ! command -v dnsmasq >/dev/null 2>&1; then
  apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq
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
EOF

# ---------Abren el DNS del router para que los clientes LAN puedan usarlo como servidor DNS.---------------
iptables -C INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -A INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT   # UDP
iptables -C INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -A INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT   # TCP

if pgrep -x dnsmasq >/dev/null; then
  log "Recargando dnsmasq"; killall -HUP dnsmasq || true
else
  log "Iniciando dnsmasq"
  dnsmasq --keep-in-foreground --conf-dir=/etc/dnsmasq.d,*.conf >/tmp/dnsmasq.log 2>&1 &
fi

# ---------- Captive Portal (iptables/ipset) ----------
log "Configurando ipset 'authed' (IPs autenticadas, timeout=${AUTH_TIMEOUT}s)"
ipset create authed hash:ip timeout "${AUTH_TIMEOUT}" -exist || true

# Cadenas personalizadas
iptables -t nat -N CP_REDIRECT 2>/dev/null || true
iptables -N CP_FILTER 2>/dev/null || true

# Limpia reglas previas 
iptables -t nat -F CP_REDIRECT || true
iptables -F CP_FILTER || true

# 1) Permitir acceso al portal HTTP en el propio router desde la LAN
iptables -C INPUT -i "$LAN_IF" -p tcp --dport "${PORTAL_PORT}" -j ACCEPT 2>/dev/null || \
iptables -A INPUT -i "$LAN_IF" -p tcp --dport "${PORTAL_PORT}" -j ACCEPT

# 2) Redirigir tráfico HTTP de clientes NO autenticados hacia el portal
#    PREROUTING (solo LAN) → DNAT a LAN_IP:PORTAL_PORT si src !in ipset authed
# Redirigir HTTP de NO autenticados -> portal
iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport 80 \
  -m set ! --match-set authed src -j CP_REDIRECT 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$LAN_IF" -p tcp --dport 80 \
  -m set ! --match-set authed src -j CP_REDIRECT

# En la cadena CP_REDIRECT, repetir -p tcp porque usas :PORT en el DNAT
iptables -t nat -F CP_REDIRECT || true
iptables -t nat -A CP_REDIRECT -p tcp -j DNAT --to-destination "${LAN_IP}:${PORTAL_PORT}"


# 3) Bloquear FORWARD por defecto desde LAN→WAN si NO está autenticado
#    Solo dejar pasar si src ∈ authed
iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT

# Por seguridad, añade un DROP explícito después de la aceptación condicional
iptables -C FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT 2>/dev/null || \
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT

# ---------- Arrancar portal FastAPI ----------
log "Levantando portal en :${PORTAL_PORT}"
# Nota: workers>1 = concurrencia (hilos/ procesos gestionados por uvicorn)
uvicorn app.main:app --host 0.0.0.0 --port "${PORTAL_PORT}" --workers 2 &
PORTAL_PID=$!

# ---------- UI opcional (noVNC/navegador) ----------
if [[ -n "${BROWSER_URL}" ]]; then
  /usr/local/bin/start-ui.sh &
fi

log "Router listo. LAN=${LAN_CIDR} LAN_IP=${LAN_IP} Portal=http://${LAN_IP}:${PORTAL_PORT}"
wait "${PORTAL_PID}"
