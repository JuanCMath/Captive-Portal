#!/usr/bin/env bash
#
# INSTALADOR DE UN SOLO COMANDO -- PORTAL CAUTIVO (LINUX NATIVO)
#
# Encadena los pasos manuales de native/ en uno solo: dependencias/app/
# servicio systemd -> elegir interfaces de red -> firewall + servicios ->
# resumen de estado. Para control fino (reinstalar un paso puntual, cambiar
# TLS_MODE, actualizar sin tocar red, etc.) usa los scripts de native/
# directamente -- ver native/README.md. Este script no los reemplaza, solo
# los encadena.
#
# USO:
#   sudo bash install.sh
#
# Para saltar el asistente interactivo de red (despliegues automatizados),
# exporta WAN_IF, LAN_IF y LAN_IP antes de correr este script -- ver
# native/configure-interfaces.sh.

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Error: ejecuta como root (sudo bash install.sh)"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$SCRIPT_DIR/native"

[[ -d "$NATIVE_DIR" ]] || {
  echo "Error: no se encontró native/ junto a este script." >&2
  echo "Corre esto desde la raíz de un checkout completo del repositorio." >&2
  exit 1
}

echo "======================================================================"
echo " Portal Cautivo -- instalación"
echo "======================================================================"
echo ""

bash "$NATIVE_DIR/install.sh"

echo ""
echo "======================================================================"
echo " Configuración de red"
echo "======================================================================"
echo ""
bash "$NATIVE_DIR/configure-interfaces.sh"

echo ""
echo "======================================================================"
echo " Aplicando firewall e iniciando servicios"
echo "======================================================================"
echo ""
bash "$NATIVE_DIR/start-portal.sh"

echo ""
bash "$NATIVE_DIR/status-portal.sh"

echo ""
echo "======================================================================"
echo " Listo."
echo ""
echo " Contraseña inicial de admin (solo se muestra una vez):"
echo "   /opt/captive-portal/app/admin_password_initial.txt"
echo ""
echo " Para actualizar el código más adelante: sudo native/update.sh"
echo " Para TLS con dominio propio / Let's Encrypt: ver native/TLS.md"
echo "======================================================================"
exit 0
