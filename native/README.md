# Portal Cautivo - Despliegue Linux Nativo

Esta carpeta contiene scripts para ejecutar el portal cautivo directamente en un sistema Linux sin contenedores Docker.

## Requisitos

- Sistema Debian/Ubuntu (o similar con `apt`)
- Permisos de root (`sudo`)
- Dos interfaces de red:
  - Una conectada a Internet (WAN)
  - Una conectada a la red interna/clientes (LAN)

## Instalación Rápida

```bash
# 1. Instalar dependencias y configurar sistema
sudo ./setup-native.sh

# 2. Editar configuración de red
sudo nano /etc/captive-portal/portal.conf
# Ajusta UPLINK_IF y LAN_IF según tus interfaces

# 3. Configurar IP en interfaz LAN
sudo ip addr add 192.168.100.1/24 dev <tu_interfaz_LAN>
sudo ip link set <tu_interfaz_LAN> up

# 4. Iniciar portal
sudo ./start-portal.sh

# 5. Verificar estado
sudo ./status-portal.sh
```

## Scripts Disponibles

| Script | Descripción |
|--------|-------------|
| `setup-native.sh` | Instalación inicial (ejecutar una vez) |
| `start-portal.sh` | Iniciar portal cautivo |
| `stop-portal.sh` | Detener portal y limpiar reglas |
| `status-portal.sh` | Ver estado y IPs autenticadas |

## Archivos de Configuración

- **`/etc/captive-portal/portal.conf`** - Configuración principal
- **`/opt/captive-portal/app/users.json`** - Base de datos de usuarios

## Gestión de Usuarios

### Usuario por defecto
```
Usuario: admin
Contraseña: admin
```

### Panel de administración
Accede a `https://portal.hastalap/admin/users` (autenticación HTTP Basic con admin/admin)

## Topología de Red Típica

```
     Internet
         │
    [WAN: enp0s3] ← Interfaz con IP pública/DHCP
         │
    ┌────┴─────┐
    │  LINUX   │ ← Portal Cautivo (este servidor)
    │  SERVER  │
    └────┬─────┘
    [LAN: enp0s8] ← Interfaz con IP 192.168.100.1
         │
    ┌────┴─────┐
    │ Switch/  │
    │   AP     │
    └────┬─────┘
         │
    ┌────┴─────┬─────┬─────┐
    │          │     │     │
  [PC1]     [PC2] [Phone] [Laptop]
```

## Verificar Interfaces de Red

```bash
# Listar todas las interfaces
ip link show

# Ver IPs asignadas
ip addr show

# Ver rutas
ip route show
```

## Logs

```bash
# Backend Python
tail -f /var/log/captive-portal/backend.log

# DNS
tail -f /var/log/captive-portal/dnsmasq.log

# nginx
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/access.log
```

## Comandos Útiles

```bash
# Ver IPs autenticadas
sudo ipset list authed

# Ver reglas de firewall
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v

# Reiniciar un servicio específico
sudo systemctl restart nginx
sudo pkill -HUP dnsmasq

# Limpiar una IP específica del ipset
sudo ipset del authed 192.168.100.50
```

## Solución de Problemas

### Los clientes no son redirigidos al portal

1. Verificar que IP forwarding está habilitado:
   ```bash
   cat /proc/sys/net/ipv4/ip_forward  # Debe ser 1
   ```

2. Verificar reglas de iptables:
   ```bash
   sudo iptables -t nat -L CP_REDIRECT -n -v
   ```

3. Ver logs del backend:
   ```bash
   tail -50 /var/log/captive-portal/backend.log
   ```

### El DNS no resuelve portal.hastalap

1. Verificar que dnsmasq está activo:
   ```bash
   sudo systemctl status dnsmasq
   ```

2. Verificar configuración:
   ```bash
   cat /etc/dnsmasq.d/captive-portal.conf
   ```

3. Probar resolución desde el servidor:
   ```bash
   nslookup portal.hastalap 192.168.100.1
   ```

### El certificado TLS no es confiable

Esto es **normal** en portales cautivos con certificados autofirmados. Los navegadores mostrarán una advertencia que los usuarios deben aceptar.

Para producción, considera usar Let's Encrypt con certbot.

## Diferencias con Despliegue Docker

| Aspecto | Docker | Linux Nativo |
|---------|--------|--------------|
| Interfaces | eth0, eth1 | enp0s3, enp0s8 (configurables) |
| Ruta app | `/app/app/` | `/opt/captive-portal/app/` |
| Configuración | Variables en docker-compose | `/etc/captive-portal/portal.conf` |
| Gestión | docker start/stop | systemctl o scripts .sh |
| Aislamiento | Completo (contenedor) | Compartido con sistema host |

## Desinstalación

```bash
# 1. Detener portal
sudo ./stop-portal.sh

# 2. Eliminar archivos
sudo rm -rf /opt/captive-portal
sudo rm -rf /etc/captive-portal
sudo rm -rf /var/log/captive-portal

# 3. Eliminar configuraciones de servicios
sudo rm -f /etc/nginx/sites-enabled/captive-portal
sudo rm -f /etc/nginx/sites-available/captive-portal
sudo rm -f /etc/dnsmasq.d/captive-portal.conf

# 4. (Opcional) Desinstalar paquetes
sudo apt-get remove --purge iptables ipset dnsmasq nginx openssl
```

## Soporte

Para más información, consulta:
- `ANALISIS_PROYECTO.md` - Análisis técnico completo
- `Docker/DESPLIEGUE.md` - Documentación de despliegue Docker
- Código fuente: `Docker/router/app/` (compartido entre ambos entornos)
