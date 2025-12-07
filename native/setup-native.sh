#!/usr/bin/env bash
#
# INSTALACIÓN INICIAL DEL PORTAL CAUTIVO EN LINUX NATIVO
#
# Este script prepara un sistema Debian/Ubuntu para ejecutar el portal cautivo
# sin Docker. Instala dependencias y configura la estructura de archivos.
#
# REQUISITOS:
#   - Sistema Debian/Ubuntu (o similar con apt)
#   - Permisos de root (sudo)
#   - Dos interfaces de red (física o virtual)
#
# USO:
#   sudo ./setup-native.sh

set -euo pipefail

# Verificar root
[[ $EUID -ne 0 ]] && { echo "Error: Ejecutar como root"; exit 1; }

# Directorios
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP_SOURCE="$REPO_ROOT/Docker/router/app"
CERT_CN="portal.hastalap"

echo "==> Instalando portal cautivo..."
echo ""

# Instalar dependencias
echo "====> Actualizando dependencias existentes..."
apt-get update -qq
echo "====> Instalando paquetes necesarios..."
apt-get install -y iptables ipset dnsmasq nginx openssl python3 python3-requests iproute2 curl >/dev/null 2>&1

# Crear estructura de directorios
echo "====> Creando estructura de directorios..."
mkdir -p /opt/captive-portal
mkdir -p /etc/captive-portal/ssl
mkdir -p /var/log/captive-portal

# Copiar aplicación Python
if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Error: no se encontró $APP_SOURCE"
  exit 1
fi
cp -r "$APP_SOURCE" /opt/captive-portal/

# Crear configuración por defecto si no existe
echo "====> Buscando archivo de configuración por defecto..."
if [[ ! -f /etc/captive-portal/portal.conf ]]; then {
  echo "======> Creando  en /etc/captive-portal/portal.conf...";
  cat > /etc/captive-portal/portal.conf << EOF
# Configuración del Portal Cautivo - Linux Nativo
# Edita este archivo según tu topología de red

# Interfaz WAN (conexión a Internet)
# Ejemplos: enp0s3, eth0, wlan0
UPLINK_IF=enp0s3

# Interfaz LAN (red interna/clientes)
# Ejemplos: enp0s8, eth1, wlan1
LAN_IF=enp0s8

# IP del portal en la LAN
LAN_IP=192.168.100.1

# Subred de la LAN (notación CIDR)
LAN_CIDR=192.168.100.0/24

# Puerto del backend Python (interno)
PORTAL_PORT=8080

# Puertos nginx (HTTP y HTTPS)
NGINX_HTTP_PORT=80
NGINX_HTTPS_PORT=443

# Tamaño de caché DNS
DNS_CACHE_SIZE=1000

# Tiempo de sesión autenticada (segundos)
# 3600 = 1 hora, 1800 = 30 minutos
AUTH_TIMEOUT=3600

# Nombre común del certificado TLS
# Los clientes accederán a https://CERT_CN/
CERT_CN=/${CERT_CN}

# Ruta de la aplicación Python
APP_DIR=/opt/captive-portal

# Archivo de usuarios (se crea automáticamente si no existe)
USERS_FILE=/opt/captive-portal/app/users.json
EOF
}
fi

# Crear usuario del sistema y permisos
echo "====> Configurando permisos..."
if ! id -u captive-portal >/dev/null 2>&1; then
  useradd -r -s /bin/false captive-portal
fi
chown -R captive-portal:captive-portal /opt/captive-portal /var/log/captive-portal
chmod 755 /opt/captive-portal /var/log/captive-portal

# Verificar instalación
echo "====> Verificando instalación..."
for cmd in iptables ipset dnsmasq nginx openssl python3; do
  command -v "$cmd" >/dev/null || { echo "Error: falta $cmd"; exit 1; }
done
[[ -f /opt/captive-portal/app/main.py ]] || { echo "Error: app/main.py no encontrado"; exit 1; }

# ============================================================================
# RESUMEN Y PRÓXIMOS PASOS
# ============================================================================

echo "==> Instalación completada"
echo "==> Edita /etc/captive-portal/portal.conf (puedes usar configure-interfaces.sh) y ejecuta start-portal.sh"
exit 0
