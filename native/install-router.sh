#!/usr/bin/env bash

################################################################################
#                                                                              #
#  SCRIPT DE INSTALACIÓN: PORTAL CAUTIVO (NATIVO EN LINUX)                   #
#                                                                              #
#  Objetivo: Instalar todas las dependencias e iniciar el portal cautivo      #
#            en una máquina Linux (física o VM)                               #
#                                                                              #
#  Uso: sudo bash install-router.sh                                           #
#                                                                              #
#  Variables de entorno opcionales:                                           #
#    - LAN_IF: Interfaz de red LAN (default: eth1)                            #
#    - UPLINK_IF: Interfaz de red WAN/uplink (default: eth0)                  #
#    - LAN_IP: IP del router en la LAN (default: 10.200.0.254)               #
#    - LAN_CIDR: Subred LAN (default: 10.200.0.0/24)                         #
#    - AUTH_TIMEOUT: Timeout de sesión en segundos (default: 3600)            #
#                                                                              #
################################################################################

set -euo pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Verificar que se ejecuta como root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR] Este script debe ejecutarse como root (usa 'sudo')${NC}"
  exit 1
fi

# Configuración por defecto
: "${LAN_IF:=enp0s8}"
: "${UPLINK_IF:=enp0s3}"
: "${LAN_IP:=10.200.0.254}"
: "${LAN_CIDR:=10.200.0.0/24}"
: "${PORTAL_PORT:=8080}"
: "${NGINX_HTTP_PORT:=80}"
: "${NGINX_HTTPS_PORT:=443}"
: "${AUTH_TIMEOUT:=3600}"
: "${CERT_CN:=portal.hastalap}"
: "${DNS_CACHE_SIZE:=1000}"

# Funciones de logging
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $*"
}

log_error() {
  echo -e "${RED}[✗]${NC} $*"
}

log_step() {
  echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}$*${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Verificar conectividad de red
check_network() {
  log_info "Verificando conectividad de red..."
  
  if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    log_error "No hay acceso a Internet. Verifica tu conexión de red."
    exit 1
  fi
  
  log_success "Conectividad de red OK"
}

# Actualizar repositorios
update_repos() {
  log_info "Actualizando repositorios..."
  
  apt-get update -y >/dev/null 2>&1 || {
    log_error "Error al actualizar repositorios"
    exit 1
  }
  
  log_success "Repositorios actualizados"
}

# Instalar dependencias
install_dependencies() {
  log_step "INSTALANDO DEPENDENCIAS"
  
  local packages=(
    "curl"
    "wget"
    "git"
    "iptables"
    "ipset"
    "dnsmasq"
    "nginx"
    "python3"
    "python3-pip"
    "net-tools"
    "iproute2"
    "openssl"
    "ufw"
  )
  
  for package in "${packages[@]}"; do
    log_info "Instalando: $package"
    apt-get install -y "$package" >/dev/null 2>&1 || {
      log_error "Error al instalar $package"
      exit 1
    }
  done
  
  log_success "Todas las dependencias instaladas"
}

# Instalar dependencias de Python
install_python_deps() {
  log_step "INSTALANDO DEPENDENCIAS DE PYTHON"
  
  log_info "Instalando python packages..."
  apt-get install python3-requests >/dev/null 2>&1 || {
    log_error "Error al instalar python packages"
    exit 1
  }
  
  log_success "Dependencias de Python instaladas"
}

# Habilitar IP forwarding
enable_ip_forward() {
  log_step "CONFIGURANDO SISTEMA"
  
  log_info "Habilitando IP forwarding..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  
  # Hacer permanente
  echo "net.ipv4.ip_forward=1" | tee /etc/sysctl.d/99-portal-cautivo.conf >/dev/null
  
  log_success "IP forwarding habilitado"
}

# Configurar interfaces de red
configure_network() {
  log_step "VERIFICANDO INTERFACES DE RED"
  
  log_info "Interfaz LAN: $LAN_IF"
  log_info "Interfaz WAN: $UPLINK_IF"
  log_info "IP del router: $LAN_IP"
  
  if ! ip link show "$LAN_IF" >/dev/null 2>&1; then
    log_error "Interfaz $LAN_IF no encontrada"
    log_info "Interfaces disponibles:"
    ip link show | grep "^[0-9]" | awk '{print $2}' | tr -d ':'
    exit 1
  fi
  
  log_success "Interfaces verificadas"
}

# Configurar NAT y MASQUERADE
setup_nat() {
  log_step "CONFIGURANDO NAT Y FIREWALL"
  
  log_info "Configurando NAT (LAN → WAN)"
  
  # Limpiar reglas anteriores
  iptables -t nat -F POSTROUTING 2>/dev/null || true
  
  # NAT MASQUERADE
  iptables -t nat -A POSTROUTING -o "$UPLINK_IF" -j MASQUERADE
  
  # FORWARD básico
  iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
  
  log_success "NAT configurado"
}

# Crear ipset
create_ipset() {
  log_step "CREANDO IPSET PARA AUTENTICACIÓN"
  
  log_info "Creando ipset 'authed'..."
  
  # Eliminar si ya existe
  ipset destroy authed 2>/dev/null || true
  
  # Crear ipset con timeout
  ipset create authed hash:ip timeout "$AUTH_TIMEOUT" -exist
  
  log_success "Ipset creado"
}

# Configurar reglas de iptables para portal
setup_portal_rules() {
  log_step "CONFIGURANDO REGLAS DE IPTABLES"
  
  log_info "Permitir DNS en LAN"
  iptables -A INPUT -i "$LAN_IF" -p udp --dport 53 -j ACCEPT 2>/dev/null || true
  iptables -A INPUT -i "$LAN_IF" -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
  
  log_info "Permitir backend Python en LAN"
  iptables -A INPUT -i "$LAN_IF" -p tcp --dport "$PORTAL_PORT" -j ACCEPT 2>/dev/null || true
  
  log_info "Permitir HTTPS del portal"
  iptables -A INPUT -i "$LAN_IF" -p tcp --dport "$NGINX_HTTPS_PORT" -j ACCEPT 2>/dev/null || true
  
  log_info "Redirigir HTTP no autenticado → portal"
  iptables -t nat -A PREROUTING -i "$LAN_IF" -p tcp --dport "$NGINX_HTTP_PORT" \
    -m set ! --match-set authed src -j DNAT --to-destination "${LAN_IP}:${NGINX_HTTP_PORT}" 2>/dev/null || true
  
  log_info "Bloquear HTTPS no autenticado"
  iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" \
    -p tcp --dport "$NGINX_HTTPS_PORT" -m set ! --match-set authed src \
    -j REJECT --reject-with tcp-reset 2>/dev/null || true
  
  log_info "Bloquear todo el tráfico no autenticado"
  iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" \
    -m set ! --match-set authed src -j REJECT 2>/dev/null || true
  
  log_info "Permitir tráfico autenticado"
  iptables -I FORWARD 1 -i "$LAN_IF" -o "$UPLINK_IF" \
    -m set --match-set authed src -j ACCEPT 2>/dev/null || true
  
  log_success "Reglas de iptables configuradas"
}

# Configurar dnsmasq
setup_dnsmasq() {
  log_step "CONFIGURANDO DNSMASQ"
  
  log_info "Creando archivo de configuración..."
  
  mkdir -p /etc/dnsmasq.d
  
  # Extraer prefijo de red para DHCP
  LAN_PREFIX=$(echo "$LAN_IP" | cut -d. -f1-3)
  DHCP_START="${LAN_PREFIX}.100"
  DHCP_END="${LAN_PREFIX}.200"
  DHCP_LEASE="12h"
  
  cat > /etc/dnsmasq.d/portal.conf <<EOF
# ═══════════════════════════════════════════════════════
# PORTAL CAUTIVO - Configuración DNS + DHCP
# ═══════════════════════════════════════════════════════

# === DNS Configuration ===
listen-address=${LAN_IP}
interface=${LAN_IF}
bind-interfaces

# Resolver el portal.hastalap
address=/${CERT_CN}/${LAN_IP}

# DNS servidores upstream (para resolver dominios reales)
server=8.8.8.8
server=8.8.4.4

# Cache y performance
cache-size=${DNS_CACHE_SIZE}
no-poll
domain-needed
bogus-priv

# === DHCP Server ===
# Entrega IPs automáticas a clientes conectados a la LAN
# Rango: ${DHCP_START} - ${DHCP_END}
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}

# Gateway = este router (todo el tráfico pasa por aquí)
dhcp-option=3,${LAN_IP}

# DNS = este router (captura todas las consultas DNS)
dhcp-option=6,${LAN_IP}

# Broadcast address
dhcp-option=28,${LAN_PREFIX}.255

# Archivo de leases (IPs asignadas)
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
EOF
  
  # Crear directorio para leases
  mkdir -p /var/lib/misc
  
  log_info "Iniciando dnsmasq..."
  systemctl restart dnsmasq
  
  log_success "dnsmasq configurado"
}

# Configurar nginx
setup_nginx() {
  log_step "CONFIGURANDO NGINX"
  
  log_info "Generando certificado TLS..."
  
  mkdir -p /etc/ssl/private /etc/ssl/certs
  
  if [[ ! -f /etc/ssl/private/portal.key || ! -f /etc/ssl/certs/portal.crt ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout /etc/ssl/private/portal.key \
      -out /etc/ssl/certs/portal.crt \
      -days 365 \
      -subj "/CN=${CERT_CN}" >/dev/null 2>&1
  fi
  
  log_info "Configurando nginx..."
  
  # Crear configuración HTTP (redirección y detección de portal)
  cat > /etc/nginx/sites-available/portal.conf <<'EOF'
server {
    listen 80 default_server;
    server_name portal.hastalap _;

    # URLs de detección de portal cautivo
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
        return 200 '<html><body>Success</body></html>';  # iOS
    }

    location = /captive {
        default_type text/html;
        return 200 '<!doctype html><html><body><h1>Portal Cautivo</h1></body></html>';
    }

    # Redirigir todo lo demás a HTTPS
    location / {
        return 302 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2 default_server;
    server_name _;

    ssl_certificate /etc/ssl/certs/portal.crt;
    ssl_certificate_key /etc/ssl/private/portal.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Proxy al backend Python
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
EOF

  # Habilitar sitio
  # Eliminar cualquier sitio previamente habilitado para evitar 'duplicate default server'
  rm -f /etc/nginx/sites-enabled/*
  ln -sf /etc/nginx/sites-available/portal.conf /etc/nginx/sites-enabled/portal.conf
  
  # Verificar sintaxis
  nginx -t >/dev/null 2>&1 || {
    log_error "Error en configuración de nginx"
    exit 1
  }
  
  systemctl restart nginx
  
  log_success "Nginx configurado"
}

# Clonar o preparar la aplicación
prepare_application() {
  log_step "PREPARANDO APLICACIÓN"
  
  # Determinar dónde está el script
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  
  if [[ ! -d "$script_dir/app" ]]; then
    log_error "Directorio 'app' no encontrado en $script_dir"
    log_info "Clonando repositorio..."
    
    git clone https://github.com/JuanCMath/Captive-Portal.git /opt/portal-cautivo
    local app_dir="/opt/portal-cautivo/app"
  else
    local app_dir="$script_dir/app"
  fi
  
  log_info "Directorio de aplicación: $app_dir"
  log_success "Aplicación preparada"
  
  echo "$app_dir"  # Retornar para usar después
}

# Crear servicio systemd
create_systemd_service() {
  local app_dir="$1"
  
  log_step "CREANDO SERVICIO SYSTEMD"
  
  cat > /etc/systemd/system/portal-cautivo.service <<EOF
[Unit]
Description=Portal Cautivo - Sistema de Autenticación de Red
After=network-online.target dnsmasq.service nginx.service
Wants=network-online.target
ConditionPathExists=${app_dir}

[Service]
Type=simple
User=root
WorkingDirectory=${app_dir}
ExecStart=/usr/bin/python3 -u -m app.main ${PORTAL_PORT}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable portal-cautivo
  
  log_success "Servicio systemd creado"
}

# Iniciar servicios
start_services() {
  log_step "INICIANDO SERVICIOS"
  
  log_info "Iniciando dnsmasq..."
  systemctl start dnsmasq
  
  log_info "Iniciando nginx..."
  systemctl start nginx
  
  log_info "Iniciando portal cautivo..."
  systemctl start portal-cautivo
  
  sleep 2
  
  log_success "Servicios iniciados"
}

# Verificar estado
verify_installation() {
  log_step "VERIFICANDO INSTALACIÓN"
  
  local errors=0
  
  # Verificar servicios
  for service in dnsmasq nginx portal-cautivo; do
    if systemctl is-active --quiet "$service"; then
      log_success "$service está activo"
    else
      log_error "$service NO está activo"
      ((errors++))
    fi
  done
  
  # Verificar puertos
  if ss -tlnp 2>/dev/null | grep -q "LISTEN.*:80"; then
    log_success "Puerto 80 (HTTP) está escuchando"
  else
    log_error "Puerto 80 (HTTP) NO está escuchando"
    ((errors++))
  fi
  
  if ss -tlnp 2>/dev/null | grep -q "LISTEN.*:443"; then
    log_success "Puerto 443 (HTTPS) está escuchando"
  else
    log_error "Puerto 443 (HTTPS) NO está escuchando"
    ((errors++))
  fi
  
  if ss -tlnp 2>/dev/null | grep -q "LISTEN.*:8080"; then
    log_success "Puerto 8080 (Backend) está escuchando"
  else
    log_error "Puerto 8080 (Backend) NO está escuchando"
    ((errors++))
  fi
  
  if ss -tlnp 2>/dev/null | grep -q "LISTEN.*:53"; then
    log_success "Puerto 53 (DNS) está escuchando"
  else
    log_error "Puerto 53 (DNS) NO está escuchando"
    ((errors++))
  fi
  
  if ipset list authed >/dev/null 2>&1; then
    log_success "Ipset 'authed' creado"
  else
    log_error "Ipset 'authed' NO existe"
    ((errors++))
  fi
  
  return $errors
}

# Mostrar información final
show_summary() {
  log_step "RESUMEN DE CONFIGURACIÓN"
  
  echo -e "${CYAN}Servicios:${NC}"
  echo "  • dnsmasq (DNS): puerto 53"
  echo "  • nginx (HTTP/HTTPS): puertos 80, 443"
  echo "  • Python backend: puerto 8080"
  echo "  • iptables: firewall y NAT"
  echo ""
  
  echo -e "${CYAN}Red:${NC}"
  echo "  • Interfaz LAN: $LAN_IF ($LAN_IP)"
  echo "  • Interfaz WAN: $UPLINK_IF"
  echo "  • Subred LAN: $LAN_CIDR"
  echo ""
  
  echo -e "${CYAN}Portal:${NC}"
  echo "  • Dominio: $CERT_CN"
  echo "  • Puerto backend: $PORTAL_PORT"
  echo "  • Timeout de sesión: ${AUTH_TIMEOUT}s"
  echo ""
  
  echo -e "${CYAN}Comandos útiles:${NC}"
  echo "  Ver logs:              sudo journalctl -u portal-cautivo -f"
  echo "  Ver IPs autenticadas:  sudo ipset list authed"
  echo "  Ver reglas iptables:   sudo iptables -L FORWARD -v -n"
  echo "  Reiniciar servicio:    sudo systemctl restart portal-cautivo"
  echo "  Estado del servicio:   sudo systemctl status portal-cautivo"
  echo ""
  
  echo -e "${GREEN}¡Instalación completada! El portal cautivo está listo.${NC}"
}

# Main
main() {
  log_step "INSTALACIÓN DEL PORTAL CAUTIVO"
  
  check_network
  update_repos
  install_dependencies
  install_python_deps
  enable_ip_forward
  configure_network
  setup_nat
  create_ipset
  setup_portal_rules
  setup_dnsmasq
  setup_nginx
  
  local app_dir
  app_dir=$(prepare_application)
  
  create_systemd_service "$app_dir"
  start_services
  verify_installation
  
  if [[ $? -eq 0 ]]; then
    show_summary
    exit 0
  else
    log_error "Algunos servicios no están disponibles. Revisa los logs."
    exit 1
  fi
}

# Ejecutar main
main "$@"
