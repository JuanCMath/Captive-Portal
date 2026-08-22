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
| Certificado TLS (self-signed / propio) | `TLS_CERT_PATH`/`TLS_KEY_PATH` en `portal.conf` (default `/etc/captive-portal/ssl/portal.{crt,key}`) |
| Certificado TLS (Let's Encrypt) | `/etc/letsencrypt/live/<CERT_CN>/{fullchain,privkey}.pem` (gestionado por `certbot`) |
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

Depende de `TLS_MODE` en `portal.conf`:

- **`self-signed`** (default): es **normal**, el navegador mostrará una
  advertencia que el usuario debe aceptar. No hay CA propia detrás.
- **Traer tu propio certificado**: coloca tu `.crt`/`.key` ya emitidos
  (por tu CA interna, o por cualquier otro medio) en las rutas
  `TLS_CERT_PATH`/`TLS_KEY_PATH` de `portal.conf` **antes** de correr
  `start-portal.sh` — al encontrar los archivos ya presentes, el script no
  genera uno autofirmado y los usa tal cual.
- **`TLS_MODE=letsencrypt`**: `start-portal.sh` emite y renueva
  automáticamente un certificado real con `certbot` (ver sección siguiente).

## TLS con Let's Encrypt (certificado real, renovación automática)

Requiere que `CERT_CN` sea un **dominio público de verdad** (no
`portal.hastalap`) cuyo registro DNS apunte a una IP donde el puerto 80 de
este equipo sea alcanzable desde Internet — directo si `UPLINK_IF` tiene IP
pública, o vía port-forwarding si está detrás de otro router. Esto no
choca con que `dnsmasq` resuelva ese mismo nombre a la IP de la LAN para
los clientes internos (DNS de horizonte dividido, patrón estándar): Let's
Encrypt consulta el DNS público real, no el de la LAN.

```bash
# En portal.conf:
TLS_MODE=letsencrypt
CERT_CN=portal.tuempresa.com
LETSENCRYPT_EMAIL=admin@tuempresa.com
```

```bash
sudo ./start-portal.sh
```

Qué hace `start-portal.sh` en este modo:

1. Arranca nginx con un certificado autofirmado de respaldo (nginx
   necesita *algún* certificado para levantar su bloque HTTPS antes de que
   exista uno real).
2. Abre una excepción puntual en el firewall: **solo el puerto 80** en la
   interfaz WAN (`UPLINK_IF`) queda accesible desde Internet — necesario
   para que Let's Encrypt valide el dominio (reto ACME, HTTP-01). El resto
   (443, el backend, DNS, DHCP) sigue bloqueado en WAN igual que siempre.
3. Pide el certificado a Let's Encrypt vía `certbot`. Si lo consigue,
   recarga nginx con el certificado real; si falla (DNS aún no propagado,
   puerto 80 no alcanzable, etc.), registra el error en
   `/var/log/captive-portal/certbot-issue.log` y **sigue operando con el
   autofirmado** — no aborta el arranque del portal.
4. Activa `certbot.timer` (del paquete Debian), que reintenta la
   renovación automáticamente dos veces al día y recarga nginx tras cada
   renovación exitosa.

Diagnóstico:

```bash
sudo ./status-portal.sh                         # modo TLS y expiración del cert
sudo cat /var/log/captive-portal/certbot-issue.log   # si la emisión falló
sudo certbot certificates                        # certificados que gestiona certbot
sudo certbot renew --dry-run                      # probar la renovación sin gastar cuota
```

> `stop-portal.sh` cierra de nuevo el puerto 80 en WAN al detener el
> portal; `certbot.timer` sigue activo a nivel de sistema (inofensivo con
> el portal detenido, vuelve a renovar bien en el siguiente arranque).

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

- `ANALISIS_PROYECTO.md` - Análisis técnico completo
- `CAMBIOS_SEGURIDAD.md` - Auditoría de seguridad y pendientes
- `Docker/DESPLIEGUE.md` - Documentación de despliegue Docker
- Código fuente: `Docker/router/app/` (compartido entre ambos entornos)
