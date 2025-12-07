#!/usr/bin/env bash
# Configuración interactiva de interfaces de red
# Uso: sudo ./configure-interfaces.sh

set -euo pipefail

# Verificar root
[[ $EUID -ne 0 ]] && { echo "Error: ejecutar como root"; exit 1; }

echo "=== CONFIGURACIÓN DE INTERFACES ==="
echo ""

# Detectar interfaces disponibles (excluir lo, docker, veth)
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E '^(lo|docker|veth|br-)' || true)
[[ -z "$INTERFACES" ]] && { echo "Error: no hay interfaces disponibles"; exit 1; }

echo "Interfaces disponibles:"
i=1
declare -A IF_MAP
while IFS= read -r iface; do
  STATUS=$(ip link show "$iface" | grep -o "state [A-Z]*" | cut -d' ' -f2)
  IP=$(ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "sin IP")
  echo "  [$i] $iface ($STATUS, IP: $IP)"
  IF_MAP[$i]=$iface
  ((i++))
done <<< "$INTERFACES"
echo ""

# Seleccionar WAN
echo "PASO 1: Seleccionar interfaz WAN (Internet)"
while true; do
  read -p "Número de interfaz WAN: " wan_choice
  if [[ -n "${IF_MAP[$wan_choice]:-}" ]]; then
    WAN_IF="${IF_MAP[$wan_choice]}"
    echo "WAN: $WAN_IF"
    break
  fi
  echo "Opción inválida"
done
echo ""

# Seleccionar LAN
echo "PASO 2: Seleccionar interfaz LAN (clientes)"
while true; do
  read -p "Número de interfaz LAN: " lan_choice
  if [[ -n "${IF_MAP[$lan_choice]:-}" ]]; then
    LAN_IF="${IF_MAP[$lan_choice]}"
    [[ "$LAN_IF" == "$WAN_IF" ]] && { echo "LAN debe ser diferente a WAN"; continue; }
    echo "LAN: $LAN_IF"
    break
  fi
  echo "Opción inválida"
done
echo ""

# Configurar IP LAN
echo "PASO 3: Configurar IP de la LAN"
read -p "IP del portal [192.168.100.1]: " LAN_IP
LAN_IP="${LAN_IP:-192.168.100.1}"
[[ ! "$LAN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "Error: formato IP inválido"; exit 1; }

read -p "Máscara [24]: " NETMASK
NETMASK="${NETMASK:-24}"
LAN_CIDR="${LAN_IP%.*}.0/$NETMASK"
echo "Subred: $LAN_CIDR"
echo ""

# Aplicar configuración en LAN
echo "PASO 4: Aplicar configuración"
ip link set "$LAN_IF" up
if ! ip addr show "$LAN_IF" | grep -q "$LAN_IP"; then
  read -p "¿Eliminar IPs existentes en $LAN_IF? [s/N]: " remove_ips
  [[ "$remove_ips" =~ ^[sS]$ ]] && ip addr flush dev "$LAN_IF"
  ip addr add "$LAN_IP/$NETMASK" dev "$LAN_IF"
  echo "IP $LAN_IP/$NETMASK añadida a $LAN_IF"
fi
echo ""

# Actualizar portal.conf
echo "PASO 5: Actualizar configuración del portal"
CONFIG_FILE="/etc/captive-portal/portal.conf"
[[ -f "$CONFIG_FILE" ]] || { echo "Error: no existe $CONFIG_FILE"; exit 1; }

cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
sed -i "s/^UPLINK_IF=.*/UPLINK_IF=$WAN_IF/" "$CONFIG_FILE"
sed -i "s/^LAN_IF=.*/LAN_IF=$LAN_IF/" "$CONFIG_FILE"
sed -i "s/^LAN_IP=.*/LAN_IP=$LAN_IP/" "$CONFIG_FILE"
sed -i "s|^LAN_CIDR=.*|LAN_CIDR=$LAN_CIDR|" "$CONFIG_FILE"
echo "Configuración actualizada en $CONFIG_FILE"
echo ""

# Resumen
echo "=== CONFIGURACIÓN COMPLETADA ==="
echo "WAN: $WAN_IF"
echo "LAN: $LAN_IF ($LAN_IP/$NETMASK)"
echo "Subred: $LAN_CIDR"
echo ""
echo "Siguiente: sudo ./start-portal.sh"
exit 0
