#!/usr/bin/env bash
#
# INSTALACIÓN DEL PORTAL CAUTIVO EN LINUX NATIVO
#
# Prepara un sistema Debian/Ubuntu para ejecutar el portal cautivo sin
# Docker: instala dependencias, copia la aplicación a /opt/captive-portal,
# crea la configuración por defecto y registra el servicio systemd. No
# inicia nada todavía -- las interfaces de red normalmente no están listas
# en este punto. Tras este script:
#
#   sudo ./configure-interfaces.sh   # elegir/asignar WAN y LAN
#   sudo ./start-portal.sh           # aplicar firewall e iniciar servicios
#
# USO:
#   sudo ./install.sh

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
APP_SOURCE="$REPO_ROOT/Docker/router/app"

APP_DIR=/opt/captive-portal
CONFIG_DIR=/etc/captive-portal
LOG_DIR=/var/log/captive-portal

echo "==> Instalando portal cautivo (dnsmasq para DNS+DHCP, systemd para el backend)"
echo ""

echo "====> Actualizando índice de paquetes..."
apt-get update -qq

echo "====> Instalando paquetes necesarios..."
# Solo librería estándar de Python en tiempo de ejecución (ver pyproject.toml):
# nada de python3-pip/python3-requests aquí, son deuda de una versión anterior.
apt-get install -y --no-install-recommends \
  iptables ipset dnsmasq nginx openssl python3 iproute2 curl sudo >/dev/null 2>&1

echo "====> Creando estructura de directorios..."
mkdir -p "$APP_DIR" "$CONFIG_DIR/ssl" "$LOG_DIR"

echo "====> Copiando la aplicación..."
if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Error: no se encontró $APP_SOURCE" >&2
  echo "Este script espera correr desde un checkout completo del repositorio" >&2
  echo "(native/install.sh junto a Docker/router/app/)." >&2
  exit 1
fi
rm -rf "$APP_DIR/app"
cp -r "$APP_SOURCE" "$APP_DIR/app"

echo "====> Creando usuario de sistema sin privilegios..."
if ! id -u captive-portal >/dev/null 2>&1; then
  useradd -r -s /usr/sbin/nologin captive-portal
fi
chown -R captive-portal:captive-portal "$APP_DIR" "$LOG_DIR"
chmod 755 "$APP_DIR" "$LOG_DIR"

echo "====> Autorizando (solo) los comandos ipset que necesita el backend..."
# El backend corre como 'captive-portal', sin privilegios. La única
# operación que de verdad requiere root es manipular el ipset 'authed'
# (login/logout/consultar sesiones) -- ver app/ipset_utils.py. En vez de
# darle root al proceso completo, se autoriza vía sudo exactamente esos
# cuatro subcomandos sobre ese conjunto, nada más.
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<'EOF'
# Generado por native/install.sh -- no editar a mano, se sobrescribe en
# cada instalación.
Defaults:captive-portal !requiretty
Cmnd_Alias CAPTIVEPORTAL_IPSET = /usr/sbin/ipset add authed *, /usr/sbin/ipset del authed *, /usr/sbin/ipset test authed *, /usr/sbin/ipset list authed
captive-portal ALL=(root) NOPASSWD: CAPTIVEPORTAL_IPSET
EOF

if ! visudo -c -f "$SUDOERS_TMP" >/dev/null 2>&1; then
  echo "Error: el sudoers generado no es válido, abortando." >&2
  rm -f "$SUDOERS_TMP"
  exit 1
fi
install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/captive-portal
rm -f "$SUDOERS_TMP"

echo "====> Generando configuración por defecto..."
if [[ ! -f "$CONFIG_DIR/portal.conf" ]]; then
  cp "$SCRIPT_DIR/portal.conf.example" "$CONFIG_DIR/portal.conf"
  echo "      Creada en $CONFIG_DIR/portal.conf -- ajústala con configure-interfaces.sh"
else
  echo "      Ya existe $CONFIG_DIR/portal.conf, no se sobrescribe."
fi

echo "====> Registrando servicio systemd..."
cat > /etc/systemd/system/captive-portal.service <<EOF
[Unit]
Description=Portal Cautivo - Backend de autenticacion
After=network-online.target dnsmasq.service nginx.service
Wants=network-online.target

[Service]
Type=simple
# Sin privilegios: la única operación que requiere root (manipular el
# ipset 'authed') se hace vía el sudoers acotado de /etc/sudoers.d/captive-portal,
# no dándole root al proceso completo.
User=captive-portal
Group=captive-portal
WorkingDirectory=${APP_DIR}
EnvironmentFile=${CONFIG_DIR}/portal.conf
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 -u -m app.main
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable captive-portal >/dev/null 2>&1

echo "====> Verificando instalación..."
for cmd in iptables ipset dnsmasq nginx openssl python3 sudo; do
  command -v "$cmd" >/dev/null || { echo "Error: falta $cmd" >&2; exit 1; }
done
[[ -f "$APP_DIR/app/main.py" ]] || { echo "Error: $APP_DIR/app/main.py no encontrado" >&2; exit 1; }
[[ -f /etc/sudoers.d/captive-portal ]] || { echo "Error: no se generó /etc/sudoers.d/captive-portal" >&2; exit 1; }

echo ""
echo "==> Instalación completada."
echo "==> Próximos pasos:"
echo "      1. sudo ./configure-interfaces.sh   (o edita $CONFIG_DIR/portal.conf a mano)"
echo "      2. sudo ./start-portal.sh"
echo "      3. sudo ./status-portal.sh"
exit 0
