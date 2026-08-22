#!/usr/bin/env bash
#
# ACTUALIZACIÓN DEL PORTAL CAUTIVO (LINUX NATIVO)
#
# Reemplaza el código de la aplicación por el del checkout actual, sin
# tocar configuración (portal.conf), certificados TLS ni cuentas de
# usuario. No reinstala paquetes ni aplica firewall -- para eso ya está
# start-portal.sh, seguro de re-correr si hiciera falta después de una
# actualización (por ejemplo si cambiaste variables en portal.conf).
#
# USO (desde un checkout ya actualizado del repositorio, p.ej. tras
# "git pull"):
#   sudo ./update.sh

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP_SOURCE="$REPO_ROOT/Docker/router/app"

APP_DIR=/opt/captive-portal
CONFIG_DIR=/etc/captive-portal

[[ -d "$APP_DIR/app" ]] || {
  echo "Error: no hay una instalación previa en $APP_DIR/app." >&2
  echo "Corre primero: sudo ./install.sh" >&2
  exit 1
}
[[ -d "$APP_SOURCE" ]] || {
  echo "Error: no se encontró $APP_SOURCE" >&2
  echo "Este script espera correr desde un checkout completo del repositorio." >&2
  exit 1
}

NEW_VERSION="$(grep -m1 '^version' "$REPO_ROOT/pyproject.toml" | sed -E 's/version = "(.*)"/\1/')"
OLD_VERSION="$(cat "$CONFIG_DIR/VERSION" 2>/dev/null || echo "desconocida")"

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
  echo "Ya estás en la versión $NEW_VERSION -- nada que actualizar."
  exit 0
fi

echo "==> Actualizando portal cautivo: $OLD_VERSION -> $NEW_VERSION"

# users.json y admin_password_initial.txt viven dentro de app/ (no son
# código, ver config.py): se respaldan y restauran para no perder cuentas
# de usuario al reemplazar el código (mismo patrón que install.sh).
DATA_BACKUP="$(mktemp -d)"
for f in users.json admin_password_initial.txt; do
  [[ -f "$APP_DIR/app/$f" ]] && cp "$APP_DIR/app/$f" "$DATA_BACKUP/$f"
done

rm -rf "$APP_DIR/app"
cp -r "$APP_SOURCE" "$APP_DIR/app"

for f in users.json admin_password_initial.txt; do
  [[ -f "$DATA_BACKUP/$f" ]] && cp "$DATA_BACKUP/$f" "$APP_DIR/app/$f"
done
rm -rf "$DATA_BACKUP"

chown -R captive-portal:captive-portal "$APP_DIR"
echo "$NEW_VERSION" > "$CONFIG_DIR/VERSION"

echo "==> Reiniciando el backend..."
systemctl restart captive-portal

echo ""
echo "==> Portal cautivo actualizado a la versión $NEW_VERSION."
echo "==> Config, firewall y TLS no se tocaron. Si portal.conf.example"
echo "    cambió con nuevas variables, compáralo con tu $CONFIG_DIR/portal.conf"
echo "    y corre 'sudo ./start-portal.sh' si necesitas aplicar algo nuevo."
exit 0
