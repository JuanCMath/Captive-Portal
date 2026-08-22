# TLS del Portal Cautivo (despliegue nativo)

Guía práctica para configurar el certificado HTTPS del portal. Aplica solo
al despliegue nativo (`native/`); el despliegue Docker se documenta aparte
en `Docker/DESPLIEGUE.md` y solo soporta autofirmado / traer tu propio
certificado.

Todo se controla con tres variables en `/etc/captive-portal/portal.conf`:

| Variable | Para qué |
|---|---|
| `TLS_MODE` | `self-signed` (default) o `letsencrypt` |
| `TLS_CERT_PATH` / `TLS_KEY_PATH` | Dónde vive el certificado/llave (autofirmado o propio) |
| `LETSENCRYPT_EMAIL` | Correo de contacto para Let's Encrypt (obligatorio solo en modo `letsencrypt`) |

## Resumen de los tres modos

| Modo | Qué ve el usuario | Qué tienes que hacer |
|---|---|---|
| **Autofirmado** (default) | Advertencia de seguridad del navegador | Nada — se genera solo |
| **Certificado propio** | Sin advertencia (si el cert es de confianza) | Colocar tus archivos antes de arrancar |
| **Let's Encrypt** | Sin advertencia, candado válido | Tener un dominio público + `LETSENCRYPT_EMAIL` |

---

## Modo 1: Autofirmado (default)

No requiere configuración. Al correr `sudo ./start-portal.sh` por primera
vez, si no hay nada en `TLS_CERT_PATH`/`TLS_KEY_PATH`
(`/etc/captive-portal/ssl/portal.{crt,key}` por defecto), se genera un
certificado autofirmado válido por 365 días con `CN=$CERT_CN`.

Cada usuario verá una advertencia de seguridad al conectarse (normal en
portales cautivos sin CA propia) — tiene que aceptar la excepción para
continuar. Es el comportamiento esperado para laboratorio, demos, o
cualquier instalación donde no haya un dominio público real.

## Modo 2: Traer tu propio certificado

Si ya tienes un certificado válido (de tu CA interna, o emitido por
cualquier otro medio), colócalo **antes** de arrancar el portal:

```bash
sudo cp mi-certificado.crt /etc/captive-portal/ssl/portal.crt
sudo cp mi-llave.key       /etc/captive-portal/ssl/portal.key
sudo ./start-portal.sh
```

`start-portal.sh` detecta que los archivos ya existen y no genera nada
encima — los usa tal cual. Si prefieres otra ruta, cámbiala en
`portal.conf`:

```bash
TLS_CERT_PATH=/ruta/a/tu/certificado.crt
TLS_KEY_PATH=/ruta/a/tu/llave.key
```

## Modo 3: Let's Encrypt (certificado real, automatizado)

### Requisito indispensable

`CERT_CN` tiene que ser un **dominio público de verdad** (no
`portal.hastalap`) cuyo registro DNS apunte a una IP donde el **puerto 80**
de este equipo sea alcanzable desde Internet — directo si `UPLINK_IF` tiene
IP pública, o vía port-forwarding si está detrás de otro router. Let's
Encrypt necesita poder "tocar la puerta" por ahí para comprobar que el
dominio es tuyo (reto ACME, método HTTP-01).

Esto **no** choca con que `dnsmasq` resuelva ese mismo nombre a la IP de la
LAN para los clientes internos — es DNS de horizonte dividido, un patrón
estándar: Let's Encrypt consulta el DNS público real, nunca el de tu LAN.

### Configuración

En `/etc/captive-portal/portal.conf`:

```bash
TLS_MODE=letsencrypt
CERT_CN=portal.tuempresa.com
LETSENCRYPT_EMAIL=admin@tuempresa.com
```

```bash
sudo ./start-portal.sh
```

### Qué pasa internamente

1. **Arranque de respaldo**: nginx levanta primero con un certificado
   autofirmado (necesita *algún* certificado para su bloque HTTPS antes de
   que exista uno real — el portal nunca se queda sin HTTPS mientras
   espera a Let's Encrypt).
2. **Excepción de firewall puntual**: se abre **solo el puerto 80** en la
   interfaz WAN. El puerto 443, el backend Python, DNS y DHCP siguen
   bloqueados en WAN siempre, en cualquier modo — esta es la única
   excepción y solo existe en `TLS_MODE=letsencrypt`.
3. **Emisión**: `certbot` pide el certificado a Let's Encrypt vía el
   webroot `/var/www/certbot` (nginx ya lo está sirviendo desde el paso 1).
   - Si tiene éxito: nginx se recarga con el certificado real, sin caída
     de servicio.
   - Si falla (DNS aún no propagado, puerto 80 no alcanzable, límite de
     solicitudes de Let's Encrypt, etc.): el error queda registrado en
     `/var/log/captive-portal/certbot-issue.log` y **el portal sigue
     funcionando con el autofirmado** — el arranque nunca se aborta por
     esto. Corrige lo que falló y vuelve a correr `start-portal.sh`.
4. **Renovación automática**: se activa `certbot.timer` (viene con el
   paquete `certbot` de Debian), que revisa dos veces al día si el
   certificado necesita renovarse y recarga nginx automáticamente después
   de cada renovación exitosa. No requiere ninguna acción tuya una vez
   emitido el primer certificado.

### Diagnóstico

```bash
sudo ./status-portal.sh                              # modo TLS y fecha de expiración
sudo cat /var/log/captive-portal/certbot-issue.log    # detalle si la emisión falló
sudo certbot certificates                             # certificados que gestiona certbot
sudo certbot renew --dry-run                          # probar la renovación sin gastar cuota
sudo iptables -C INPUT -i <UPLINK_IF> -p tcp --dport 80 -j ACCEPT   # confirma la excepción de firewall
```

> `stop-portal.sh` vuelve a cerrar el puerto 80 en WAN al detener el
> portal. `certbot.timer` queda activo a nivel de sistema (inofensivo con
> el portal detenido) y todo vuelve a converger bien en el siguiente
> `start-portal.sh`.

---

## Cambiar de modo

`start-portal.sh` es idempotente: puedes editar `TLS_MODE` en
`portal.conf` y volver a correrlo las veces que quieras. La regla de
firewall del puerto 80 en WAN se limpia y reaplica en cada corrida, así que
nunca quedan reglas duplicadas o contradictorias entre una corrida y otra.

## Desinstalar / revocar

```bash
sudo certbot delete --cert-name portal.tuempresa.com
sudo systemctl disable --now certbot.timer
```

Solo hace falta si el dominio deja de apuntar a este equipo. Si solo
quieres dejar de renovar, basta con deshabilitar el timer.
