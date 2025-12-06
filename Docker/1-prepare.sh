#!/usr/bin/env bash

################################################################################
#                                                                              #
#  SCRIPT 1: PREPARACIÓN DEL ENTORNO                                          #
#                                                                              #
#  Objetivo: Construir las imágenes Docker necesarias para el portal cautivo  #
#  Acciones:                                                                  #
#    1. Construir imagen del Router (con nombres legibles)                    #
#    2. Construir imagen del Cliente (con nombres legibles)                   #
#                                                                              #
#  Uso: ./1-prepare.sh                                                        #
#                                                                              #
################################################################################

set -euo pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
  echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}$*${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Obtener ruta del directorio del script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

log_step "PREPARACIÓN DEL ENTORNO - Portal Cautivo"

# ============================================================================
# PASO 1: Construir imagen del Router
# ============================================================================

log_step "Paso 1: Construir imagen Docker del Router"

log_info "Accediendo a directorio del router: $SCRIPT_DIR/router"

if [[ ! -f "$SCRIPT_DIR/router/Dockerfile" ]]; then
  log_error "No se encontró Dockerfile en $SCRIPT_DIR/router"
  exit 1
fi

log_info "Construyendo imagen 'portal-router:latest'..."
log_info "Esta imagen incluye: iptables, ipset, dnsmasq, nginx, Python3, noVNC"

docker build \
  --tag portal-router:latest \
  --file "$SCRIPT_DIR/router/Dockerfile" \
  "$SCRIPT_DIR/router"

if [[ $? -eq 0 ]]; then
  log_success "Imagen del router construida exitosamente"
  log_info "Nombre de la imagen: portal-router:latest"
else
  log_error "Error al construir imagen del router"
  exit 1
fi

# ============================================================================
# PASO 2: Construir imagen del Cliente
# ============================================================================

log_step "Paso 2: Construir imagen Docker del Cliente"

log_info "Accediendo a directorio del cliente: $SCRIPT_DIR/client"

if [[ ! -f "$SCRIPT_DIR/client/Dockerfile" ]]; then
  log_error "No se encontró Dockerfile en $SCRIPT_DIR/client"
  exit 1
fi

log_info "Construyendo imagen 'portal-client:latest'..."
log_info "Esta imagen incluye: navegador Chromium, noVNC, utilidades de red"

docker build \
  --tag portal-client:latest \
  --file "$SCRIPT_DIR/client/Dockerfile" \
  "$SCRIPT_DIR/client"

if [[ $? -eq 0 ]]; then
  log_success "Imagen del cliente construida exitosamente"
  log_info "Nombre de la imagen: portal-client:latest"
else
  log_error "Error al construir imagen del cliente"
  exit 1
fi

# ============================================================================
# PASO 3: Verificación final
# ============================================================================

log_step "Paso 3: Verificación de imágenes construidas"

log_info "Imágenes Docker disponibles:"
echo ""

docker images --filter "reference=portal-*" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

if docker images --quiet portal-router:latest >/dev/null && \
   docker images --quiet portal-client:latest >/dev/null; then
  log_success "Todas las imágenes fueron construidas correctamente"
else
  log_error "Faltan imágenes por construir"
  exit 1
fi

# ============================================================================
# RESUMEN Y PRÓXIMOS PASOS
# ============================================================================

log_step "PREPARACIÓN COMPLETADA"

echo -e "${GREEN}Resumen:${NC}"
echo "  • Imagen del router:  ${BLUE}portal-router:latest${NC}"
echo "  • Imagen del cliente: ${BLUE}portal-client:latest${NC}"
echo ""
echo -e "${GREEN}Próximo paso:${NC}"
echo "  Ejecuta el script 2 para iniciar los contenedores:"
echo ""
echo -e "    ${BLUE}./2-deploy.sh${NC}"
echo ""

exit 0
