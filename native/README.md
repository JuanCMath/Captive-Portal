# Portal Cautivo - Despliegue Linux Nativo

Scripts para ejecutar el portal cautivo directamente en un sistema Linux,
sin contenedores Docker. DNS y DHCP los sirve `dnsmasq` (el mismo demonio
que usa el despliegue Docker); el backend Python corre como servicio
`systemd` (`captive-portal.service`), con reinicio automático si falla.

## Requisitos

- Sistema Debian/Ubuntu (o similar con `apt`)
- Permisos de root (`sudo`)
- Dos interfaces de red: una a Internet (WAN) y otra a la LAN de clientes

## Instalación

```bash
# 1. Instalar dependencias, copiar la app y registrar el servicio systemd
sudo ./install.sh

# 2. Elegir interfaces WAN/LAN y asignar la IP del portal (interactivo)
sudo ./configure-interfaces.sh

# 3. Aplicar firewall e iniciar dnsmasq, nginx y el backend
sudo ./start-portal.sh

# 4. Verificar que todo quedó activo
sudo ./status-portal.sh
```

`start-portal.sh` es seguro de volver a ejecutar (por ejemplo tras editar
`portal.conf`): no duplica reglas de `iptables`.

## Scripts

| Script | Descripción |
|--------|-------------|
| `install.sh` | Instalación inicial: paquetes, `/opt/captive-portal`, `portal.conf`, servicio systemd. Se ejecuta una vez. |
| `configure-interfaces.sh` | Asistente interactivo para elegir WAN/LAN y escribirlas en `portal.conf`. |
| `start-portal.sh` | Aplica firewall/DNS/DHCP e inicia dnsmasq, nginx y el backend. |
| `stop-portal.sh` | Detiene los servicios y limpia `iptables`/`ipset`. |
| `status-portal.sh` | Estado de servicios, sesiones autenticadas y últimas líneas de log. |

## Rutas

| Qué | Dónde |
|-----|-------|
| Aplicación | `/opt/captive-portal/app/` |
| Configuración | `/etc/captive-portal/portal.conf` |
| Certificado TLS | Ver `TLS.md` — depende de `TLS_MODE` |
| Usuarios | `/opt/captive-portal/app/users.json` |
| Logs del backend / auditoría | `/var/log/captive-portal/` |
| Logs del backend (systemd) | `sudo journalctl -u captive-portal -f` |

## Gestión de usuarios

No hay credenciales por defecto predecibles. En el primer arranque se
genera una contraseña aleatoria para `admin`, que se muestra **una sola
vez** por consola y se guarda en
`/opt/captive-portal/app/admin_password_initial.txt` (permisos 600).
Cámbiala o crea más cuentas desde `https://<CERT_CN>/admin/users`
(autenticación HTTP Basic; por defecto `CERT_CN=portal.hastalap`).

## Topología de red típica

```
     Internet
         │
    [WAN: enp0s3] ← IP pública/DHCP del proveedor
         │
    ┌────┴─────┐
    │  LINUX   │ ← Portal Cautivo (este servidor)
    │  SERVER  │
    └────┬─────┘
    [LAN: enp0s8] ← IP 192.168.100.1 (o la que definas)
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

## Comandos útiles

```bash
# Ver sesiones autenticadas (IP,MAC)
sudo ipset list authed

# Ver reglas de firewall
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v

# Reiniciar un servicio específico
sudo systemctl restart captive-portal
sudo systemctl restart nginx
sudo systemctl restart dnsmasq

# Logs del backend en vivo
sudo journalctl -u captive-portal -f

# Cerrar una sesión a mano (necesitas la MAC exacta; ver 'ipset list authed')
sudo ipset del authed 192.168.100.50,aa:bb:cc:dd:ee:ff

# TLS_MODE=letsencrypt: certificados gestionados y renovación
sudo certbot certificates
sudo certbot renew --dry-run
```

## Solución de problemas

### Los clientes no son redirigidos al portal

```bash
cat /proc/sys/net/ipv4/ip_forward        # debe ser 1
sudo iptables -t nat -L CP_REDIRECT -n -v
sudo journalctl -u captive-portal -n 50
```

### El DNS no resuelve el dominio del portal

```bash
sudo systemctl status dnsmasq
cat /etc/dnsmasq.d/captive-portal.conf
nslookup portal.hastalap 192.168.100.1   # ajusta a tu LAN_IP
```

### El certificado TLS no es confiable

Con `TLS_MODE=self-signed` (default) es **normal**: el navegador mostrará
una advertencia que el usuario debe aceptar. Para certificado propio o
Let's Encrypt (sin advertencia), ver **`TLS.md`** — guía completa de los
tres modos, cómo cambiar entre ellos, y diagnóstico.

## Diferencias con el despliegue Docker

| Aspecto | Docker | Linux Nativo |
|---------|--------|--------------|
| Interfaces | `eth0`, `eth1` | `enp0s3`, `enp0s8` (configurables) |
| Ruta app | `/app/app/` | `/opt/captive-portal/app/` |
| Configuración | Variables de entorno del contenedor | `/etc/captive-portal/portal.conf` |
| Gestión del backend | `docker start/stop` | `systemctl` (`captive-portal.service`) |
| Aislamiento | Completo (contenedor) | Compartido con el sistema host |

Ambos comparten el mismo código de aplicación
(`Docker/router/app/`, sin dependencias externas) y la misma lógica de
firewall (`ipset hash:ip,mac` + `iptables`).

## Desinstalación

```bash
sudo ./stop-portal.sh

sudo rm -rf /opt/captive-portal /etc/captive-portal /var/log/captive-portal
sudo rm -f /etc/nginx/sites-enabled/captive-portal /etc/nginx/sites-available/captive-portal
sudo rm -f /etc/dnsmasq.d/captive-portal.conf
sudo rm -f /etc/systemd/system/captive-portal.service
sudo rm -f /etc/sudoers.d/captive-portal
sudo systemctl daemon-reload
sudo userdel captive-portal 2>/dev/null || true

# Si usaste TLS_MODE=letsencrypt: revocar/borrar el certificado y detener
# la renovación automática (opcional -- revoke solo si el dominio deja de
# apuntar a este equipo, si no basta con no renovar)
sudo certbot delete --cert-name <CERT_CN> 2>/dev/null || true
sudo systemctl disable --now certbot.timer 2>/dev/null || true

# Opcional: desinstalar paquetes
sudo apt-get remove --purge iptables ipset dnsmasq nginx openssl certbot
```

## Más información

- **`TLS.md`** - Certificado propio y Let's Encrypt: guía completa
- `ANALISIS_PROYECTO.md` - Análisis técnico completo
- `CAMBIOS_SEGURIDAD.md` - Auditoría de seguridad y pendientes
- `Docker/DESPLIEGUE.md` - Documentación de despliegue Docker
- Código fuente: `Docker/router/app/` (compartido entre ambos entornos)
