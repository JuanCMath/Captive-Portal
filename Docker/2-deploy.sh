#!/usr/bin/env bash

################################################################################
#                                                                              #
#  SCRIPT 2: DESPLIEGUE DEL SISTEMA                                           #
#                                                                              #
#  Objetivo: Desplegar el portal cautivo en contenedores Docker              #
#  Acciones:                                                                  #
#    1. Eliminar contenedores anteriores (si existen)                         #
#    2. Crear red Docker aislada para la LAN simulada                         #
#    3. Iniciar contenedor del Router (portal cautivo)                        #
#    4. Iniciar 2 contenedores de Cliente                                     #
#    5. Informar puertos de acceso para noVNC (interfaz gráfica)              #
#                                                                              #
#  Uso: ./2-deploy.sh                                                         #
#                                                                              #
#  Variables de entorno opcionales:                                           #
#    - SKIP_CLEAN: Si es 1, no elimina contenedores existentes                #
#    - AUTH_TIMEOUT: Duración de sesión autenticada (segundos, default: 3600) #
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

# Configuración por defecto
SKIP_CLEAN="${SKIP_CLEAN:-0}"
LAN_NET="${LAN_NET:-portal-lan}"
LAN_SUBNET="${LAN_SUBNET:-10.200.0.0/24}"
LAN_GATEWAY="${LAN_GATEWAY:-10.200.0.1}"
ROUTER_IP="${ROUTER_IP:-10.200.0.254}"
AUTH_TIMEOUT="${AUTH_TIMEOUT:-3600}"

# IPs de clientes
CLIENT1_IP="10.200.0.11"
CLIENT1_PORT="6081"
CLIENT2_IP="10.200.0.12"
CLIENT2_PORT="6082"

# Imágenes Docker
ROUTER_IMAGE="portal-router:latest"
CLIENT_IMAGE="portal-client:latest"

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
  echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}$*${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

log_table_header() {
  echo -e "${CYAN}$*${NC}"
}

# Verificación de dependencias
check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker no está instalado o no está en el PATH"
    exit 1
  fi
  log_success "Docker disponible"
}

# Verificación de imágenes
check_images() {
  log_info "Verificando imágenes Docker..."
  
  if ! docker images --quiet "$ROUTER_IMAGE" >/dev/null 2>&1; then
    log_error "Imagen no encontrada: $ROUTER_IMAGE"
    log_info "Ejecuta primero: ./1-prepare.sh"
    exit 1
  fi
  log_success "Imagen encontrada: $ROUTER_IMAGE"
  
  if ! docker images --quiet "$CLIENT_IMAGE" >/dev/null 2>&1; then
    log_error "Imagen no encontrada: $CLIENT_IMAGE"
    log_info "Ejecuta primero: ./1-prepare.sh"
    exit 1
  fi
  log_success "Imagen encontrada: $CLIENT_IMAGE"
}

# Limpiar contenedores existentes
cleanup_containers() {
  if [[ "$SKIP_CLEAN" == "1" ]]; then
    log_info "Saltando limpieza (SKIP_CLEAN=1)"
    return
  fi

  log_info "Eliminando contenedores existentes..."
  
  for container in router client-1 client-2; do
    if docker inspect "$container" >/dev/null 2>&1; then
      log_info "Eliminando contenedor: $container"
      docker rm -f "$container" 2>/dev/null || true
      sleep 1
    fi
  done
  
  log_success "Contenedores anteriores eliminados"
}

# Crear red Docker
create_network() {
  log_info "Verificando red Docker: $LAN_NET"
  
  if docker network inspect "$LAN_NET" >/dev/null 2>&1; then
    log_info "La red $LAN_NET ya existe"
    return
  fi
  
  log_info "Creando red LAN..."
  log_info "  - Nombre: $LAN_NET"
  log_info "  - Subred: $LAN_SUBNET"
  log_info "  - Gateway: $LAN_GATEWAY"
  
  docker network create \
    --driver bridge \
    --subnet "$LAN_SUBNET" \
    --gateway "$LAN_GATEWAY" \
    "$LAN_NET"
  
  log_success "Red LAN creada: $LAN_NET"
}

# Iniciar contenedor del Router
start_router() {
  log_info "Iniciando contenedor del Router..."
  log_info "  - Nombre: router"
  log_info "  - Imagen: $ROUTER_IMAGE"
  log_info "  - IP LAN: $ROUTER_IP"
  log_info "  - Puerto noVNC: 6091 → 6081 (contenedor)"
  log_info "  - Auth timeout: ${AUTH_TIMEOUT}s"
  
  # Primero conectar a bridge (eth0 = uplink a Internet)
  # Luego conectar a LAN (eth1 = red de clientes)
  docker run -d \
    --name router \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    -e UPLINK_IF=eth0 \
    -e LAN_IF=eth1 \
    -e LAN_IP="$ROUTER_IP" \
    -e LAN_CIDR="$LAN_SUBNET" \
    -e AUTH_TIMEOUT="$AUTH_TIMEOUT" \
    -e BROWSER_URL="" \
    -p 6091:6081 \
    "$ROUTER_IMAGE" \
    >/dev/null 2>&1
  
  # Conectar a LAN (será eth1)
  docker network connect "$LAN_NET" router --ip "$ROUTER_IP" 2>/dev/null || true
  
  if [[ $? -eq 0 ]]; then
    log_success "Router iniciado exitosamente"
    sleep 3  # Esperar a que el router configure servicios
  else
    log_error "Error al iniciar router"
    exit 1
  fi
}

# Iniciar contenedores de Cliente
start_clients() {
  log_info "Iniciando contenedores de Cliente..."
  
  # Cliente 1
  log_info "  [Cliente 1]"
  log_info "    - Nombre: client-1"
  log_info "    - Imagen: $CLIENT_IMAGE"
  log_info "    - IP LAN: $CLIENT1_IP"
  log_info "    - Puerto noVNC (local): $CLIENT1_PORT → 6081 (contenedor)"
  
  docker run -d \
    --name client-1 \
    --network "$LAN_NET" \
    --ip "$CLIENT1_IP" \
    --cap-add=NET_ADMIN \
    --dns "$ROUTER_IP" \
    -e ROUTER_IP="$ROUTER_IP" \
    -e BROWSER_URL="https://example.com" \
    -p "$CLIENT1_PORT:6081" \
    "$CLIENT_IMAGE" \
    bash -lc '/entrypoint.sh /usr/local/bin/start-ui.sh' \
    >/dev/null 2>&1
  
  if [[ $? -eq 0 ]]; then
    log_success "Cliente 1 iniciado"
  else
    log_error "Error al iniciar cliente 1"
    exit 1
  fi
  
  sleep 2
  
  # Cliente 2
  log_info "  [Cliente 2]"
  log_info "    - Nombre: client-2"
  log_info "    - Imagen: $CLIENT_IMAGE"
  log_info "    - IP LAN: $CLIENT2_IP"
  log_info "    - Puerto noVNC (local): $CLIENT2_PORT → 6081 (contenedor)"
  
  docker run -d \
    --name client-2 \
    --network "$LAN_NET" \
    --ip "$CLIENT2_IP" \
    --cap-add=NET_ADMIN \
    --dns "$ROUTER_IP" \
    -e ROUTER_IP="$ROUTER_IP" \
    -e BROWSER_URL="https://example.com" \
    -p "$CLIENT2_PORT:6081" \
    "$CLIENT_IMAGE" \
    bash -lc '/entrypoint.sh /usr/local/bin/start-ui.sh' \
    >/dev/null 2>&1
  
  if [[ $? -eq 0 ]]; then
    log_success "Cliente 2 iniciado"
  else
    log_error "Error al iniciar cliente 2"
    exit 1
  fi
}

# Verificar estado de contenedores
verify_deployment() {
  log_info "Verificando estado de los contenedores..."
  
  local all_running=true
  
  for container in router client-1 client-2; do
    if docker ps --filter "name=$container" --format "{{.Names}}" | grep -q "^$container$"; then
      log_success "Contenedor activo: $container"
    else
      log_error "Contenedor NO está activo: $container"
      all_running=false
    fi
  done
  
  if [[ "$all_running" == "false" ]]; then
    exit 1
  fi
}

# Mostrar información de conexión
show_access_info() {
  log_step "DESPLIEGUE COMPLETADO EXITOSAMENTE"
  
  echo -e "${GREEN}Sistema de Portal Cautivo listo para usar${NC}\n"
  
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}INFORMACIÓN DE ACCESO - noVNC (Interfaz Gráfica)${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"
  
  echo -e "${GREEN}Router (Portal Cautivo):${NC}"
  echo -e "  URL: ${BLUE}http://localhost:6091/vnc.html${NC}"
  echo -e "  • Ejecuta el portal cautivo"
  echo -e "  • Configura firewall (iptables, ipset)"
  echo -e "  • Proporciona DNS local\n"
  
  echo -e "${GREEN}Cliente 1:${NC}"
  echo -e "  URL: ${BLUE}http://localhost:$CLIENT1_PORT/vnc.html${NC}"
  echo -e "  IP en LAN: ${CYAN}$CLIENT1_IP${NC}"
  echo -e "  • Primer cliente de prueba"
  echo -e "  • Accede con navegador Chromium\n"
  
  echo -e "${GREEN}Cliente 2:${NC}"
  echo -e "  URL: ${BLUE}http://localhost:$CLIENT2_PORT/vnc.html${NC}"
  echo -e "  IP en LAN: ${CYAN}$CLIENT2_IP${NC}"
  echo -e "  • Segundo cliente de prueba"
  echo -e "  • Simula múltiples usuarios simultáneos\n"
  
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}TOPOLOGÍA DE RED${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"
  
  cat << 'EOF'
┌─────────────────────────────────────────────────────────────┐
│                    MÁQUINA LOCAL                            │
│              (Tu computadora física)                        │
│                                                             │
│  Puerto 6091 (noVNC) ────────┐                             │
│  Puerto 6081 (cliente-1) ────├─► Docker Network Bridge    │
│  Puerto 6082 (cliente-2) ────┘         (portal-lan)       │
│                                    10.200.0.0/24          │
│                             ┌──────────────────────┐       │
│                             │  RED SIMULADA (LAN)  │       │
│                             │                      │       │
│                    ┌────────┼────────────┐         │       │
│                    │        │            │         │       │
│              ┌─────▼──┐ ┌───▼─────┐ ┌───▼─────┐   │       │
│              │ Router │ │ Cliente │ │ Cliente │   │       │
│              │10.200  │ │  1      │ │  2      │   │       │
│              │.0.254  │ │.0.11    │ │.0.12    │   │       │
│              └────────┘ └─────────┘ └─────────┘   │       │
│                             │                      │       │
│                             └──────────────────────┘       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
EOF
  
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}INSTRUCCIONES DE PRUEBA${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"
  
  cat << 'EOF'
1. Abre en tu navegador: http://localhost:6081/vnc.html
   (Interfaz gráfica del Cliente 1 vía noVNC)

2. Dentro del cliente:
   • Se abrirá Chromium automáticamente
   • Intenta acceder a cualquier URL (ej: http://google.com)
   • Serás redirigido al portal cautivo (https://portal.local/login)

3. Autentica con credenciales predeterminadas:
   Usuario: admin
   Contraseña: admin

4. Después de iniciar sesión:
   • Tu IP estará en el conjunto ipset 'authed'
   • Podrás acceder a Internet sin restricciones
   • La sesión expirará después de AUTH_TIMEOUT segundos

5. Para ver estadísticas en tiempo real:
   - Router: http://localhost:6091/vnc.html
   - Cliente 2: http://localhost:6082/vnc.html (prueba con otra IP)

EOF
  
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}COMANDOS ÚTILES${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}\n"
  
  cat << 'EOF'
Ver logs del router:
  docker logs -f router

Ver logs del cliente 1:
  docker logs -f client-1

Ver estado de la red Docker:
  docker network inspect portal-lan

Listar contenedores activos:
  docker ps --filter "label=" --format "table {{.Names}}\t{{.Ports}}"

Detener todo:
  docker stop router client-1 client-2

Eliminar todo:
  docker rm router client-1 client-2

Entrar a shell del router:
  docker exec -it router bash

Entrar a shell del cliente:
  docker exec -it client-1 bash

EOF
  
  echo -e "${GREEN}¡Listo! Puedes comenzar a probar el portal cautivo.${NC}\n"
}

# ============================================================================
# FLUJO PRINCIPAL
# ============================================================================

main() {
  log_step "DESPLIEGUE DEL PORTAL CAUTIVO"
  
  check_docker
  check_images
  cleanup_containers
  create_network
  start_router
  start_clients
  verify_deployment
  show_access_info
}

main
exit 0
