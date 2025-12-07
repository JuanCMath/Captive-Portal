# Captive Portal

## Descripción General

Implementación de un portal cautivo (captive portal) que simula una red controlada con autenticación obligatoria. El sistema intercepta el tráfico HTTP de clientes no autenticados y los redirige a una página de inicio de sesión mediante reglas de iptables/ipset, permitiendo o bloqueando el acceso a Internet según el estado de autenticación del usuario.

Este proyecto constituye una solución completa de control de acceso a red que integra servicios de enrutamiento, DNS, proxy inverso (nginx), backend de autenticación (Python HTTP server), y una interfaz gráfica accesible vía noVNC para facilitar pruebas y demostraciones en entornos académicos y de investigación.

**El proyecto soporta dos modos de despliegue:**

1. **Docker (simulación)**: Contenedores aislados ideal para desarrollo y pruebas
2. **Linux Nativo (producción)**: Despliegue directo en servidor Linux para redes reales

## Inicio Rápido

### Opción 1: Despliegue con Docker (Recomendado para desarrollo y pruebas)

```bash
cd Docker
./1-prepare.sh    # Construir imágenes
./2-deploy.sh     # Iniciar contenedores
# Acceder a: http://localhost:6081/vnc.html (Cliente 1)
```

### Opción 2: Despliegue en Máquina Virtual Linux (Con VirtualBox)

Para pruebas en VMs con aislamiento completo:

1. **Preparar VirtualBox** (crear red Host-Only)
2. **Crear 2 VMs**: Router (Ubuntu Desktop) + Cliente (Ubuntu Desktop)
3. **Configurar red** en ambas VMs
4. **Instalar en VM Router**:
   ```bash
   cd ~/Captive-Portal
   sudo bash native/install-router.sh
   ```

Consulta `notes/SETUP_VM_VIRTUALBOX.md` para instrucciones detalladas paso a paso.

### Opción 3: Despliegue en Linux Nativo (Servidor)

Para entornos de producción o máquinas Linux reales:

```bash
sudo bash native/install-router.sh
```

Este script instala todas las dependencias e inicia el portal automáticamente.

## Arquitectura del Sistema

### Componentes Principales

#### 1. **Router (Portal Cautivo)**
Contenedor que actúa como gateway y punto de control de la red. Implementa:
- **Enrutamiento y NAT**: Configura `iptables` para realizar Source NAT (MASQUERADE) y forwarding IPv4 entre la interfaz WAN (`eth0`) y LAN (`eth1`).
- **Sistema de autenticación por IP**: Utiliza `ipset` con conjuntos hash:ip temporales (`authed`) para mantener un registro dinámico de direcciones IP autorizadas con timeout configurable.
 - **Servidor DNS local**: `dnsmasq` resuelve peticiones DNS desde la LAN, con resolución personalizada del nombre del certificado TLS (`portal.hastalap` por defecto) hacia la IP del router.
- **Backend de autenticación**: Servidor HTTP implementado en Python (librería estándar) que gestiona:
  - Páginas de login y logout
  - Validación de credenciales contra `users.json`
  - Manipulación del conjunto `ipset` mediante comandos del sistema
  - Panel de administración con autenticación HTTP Basic
- **Proxy inverso TLS**: Nginx configurado con certificado autofirmado que:
  - Redirige tráfico HTTP (puerto 80) detectado por sistemas operativos cliente (Android `generate_204`, iOS/macOS `hotspot-detect.html`, Windows `connecttest.txt`)
  - Termina conexiones TLS (puerto 443) y enruta peticiones HTTPS al backend Python
- **Interfaz gráfica opcional**: Servidor noVNC con navegador Chromium para visualización remota del portal

#### 2. **Cliente**
Contenedores que simulan dispositivos de usuario final conectados a la red del portal:
- Configuración automática de ruta por defecto hacia el router
- Resolución DNS apuntando al servidor DNS del router
- Interfaz gráfica noVNC con navegador para interactuar con el portal
- Capacidades de red (`NET_ADMIN`) para permitir configuración dinámica de rutas

#### 3. **Red Docker**
Red bridge personalizada (`lan0`) que simula la LAN interna:
- Subred configurable (por defecto `10.200.0.0/24`)
- IPs estáticas asignadas a router y clientes
- Aislamiento de tráfico mediante namespace de red Docker

## Análisis Técnico de Scripts

### `Docker/router/entrypoint.sh`

Script de inicialización del contenedor router. Orquesta la configuración completa del portal cautivo en secuencia:

**Configuración del sistema base:**
- Habilita forwarding IPv4 mediante `sysctl -w net.ipv4.ip_forward=1`
- Establece reglas NAT para traducción de direcciones: `iptables -t nat -A POSTROUTING -o $UPLINK_IF -j MASQUERADE`
- Permite respuestas de conexiones establecidas desde WAN: `iptables -A FORWARD -i $UPLINK_IF -o $LAN_IF -m state --state RELATED,ESTABLISHED -j ACCEPT`

**Sincronización de interfaces:**
- Implementa espera activa (polling) hasta que Docker asigna la IP a la interfaz LAN (máximo 20 intentos con intervalo de 1 segundo)
- Necesario porque `docker network connect` puede ejecutarse después del inicio del contenedor

**Servicio DNS (dnsmasq):**
- Instalación condicional si no está presente en la imagen
- Configuración en `/etc/dnsmasq.d/lan.conf` con parámetros:
  - `listen-address`: Vinculación exclusiva a la IP del router en LAN
  - `bind-interfaces`: Evita escuchar en todas las interfaces
  - `address=/${CERT_CN}/${LAN_IP}`: Resolución local del nombre del certificado TLS
  - `domain-needed`, `bogus-priv`: Filtros de seguridad DNS
- Apertura de puertos DNS (53/udp y 53/tcp) en cadena INPUT de iptables

**Mecanismo de portal cautivo con ipset:**
```bash
ipset create authed hash:ip timeout ${AUTH_TIMEOUT} -exist
```
Crea estructura de datos kernel-space para almacenar IPs autorizadas con expiración automática.

**Reglas de redirección y filtrado:**
1. **Redirección HTTP (tabla nat, PREROUTING):**
   ```bash
   iptables -t nat -A PREROUTING -i $LAN_IF -p tcp --dport 80 \
     -m set ! --match-set authed src -j CP_REDIRECT
   ```
   Intercepta peticiones HTTP de IPs no autenticadas y aplica DNAT hacia nginx local.

2. **Control de forwarding (tabla filter, FORWARD):**
   - Regla prioritaria: Permite todo el tráfico de IPs en conjunto `authed` hacia WAN
   - Bloqueo selectivo HTTPS: Rechaza conexiones al puerto 443 de IPs no autenticadas con `tcp-reset`
   - Bloqueo general: Rechaza cualquier otro tráfico de IPs no autenticadas

**Backend Python:**
- Ejecutado en background con `python3 -u -m app.main ${PORTAL_PORT}`
- Flag `-u` deshabilita buffering de stdout/stderr para logs inmediatos en contenedores
- PID guardado para gestión del ciclo de vida del contenedor

**Generación y configuración TLS:**
- Verificación de existencia de certificado/clave
- Generación automática con OpenSSL si no existen:
  ```bash
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout $TLS_KEY -out $TLS_CERT -days 365 \
    -subj "/CN=${CERT_CN}"
  ```
- Configuración de nginx con dos bloques `server`:
  - Puerto 80: Redirecciones 302 para rutas de detección de portal cautivo (`/generate_204`, `/connecttest.txt`, `/hotspot-detect.html`, etc.)
  - Puerto 443: Terminación TLS y proxy inverso hacia backend Python (`proxy_pass http://127.0.0.1:${PORTAL_PORT}`)

**Gestión de procesos:**
- `wait "$PORTAL_PID"`: Mantiene el proceso principal (PID 1) vivo hasta la terminación del backend, evitando salida prematura del contenedor

### `Docker/router/start-ui.sh` y `Docker/client/start-ui.sh`

Scripts idénticos que implementan un entorno gráfico completo en contenedor sin GPU:

**Servidor X virtual (Xvfb):**
```bash
Xvfb :1 -screen 0 ${XVFB_W}x${XVFB_H}x${XVFB_D} &
```
Crea display virtual `:1` con geometría configurable (1366x768x24 por defecto). Permite ejecución de aplicaciones gráficas en contenedores headless.

**Window Manager:**
- `fluxbox`: Gestor de ventanas ligero que proporciona funcionalidad básica de escritorio

**Acceso remoto web (noVNC):**
```bash
websockify --web=/usr/share/novnc/ 6081 localhost:5900
```
- `websockify` actúa como bridge WebSocket-to-TCP
- Sirve interfaz web noVNC en puerto 6081
- Traduce tráfico WebSocket del navegador a protocolo VNC nativo (puerto 5900)

**Servidor VNC:**
```bash
x11vnc -display :1 -nopw -forever
```
- Expone display Xvfb vía protocolo VNC
- `-nopw`: Sin autenticación (apropiado solo para entornos de laboratorio aislados)
- `-forever`: Acepta múltiples conexiones consecutivas

**Navegador automático:**
- Lanzamiento condicional de Chromium si `BROWSER_URL` está definido
- `--no-sandbox`: Deshabilita sandboxing (requerido en contenedores sin namespaces completos)
- Delay de 2 segundos para permitir inicialización completa del servidor X

**Persistencia del contenedor:**
```bash
tail -f /tmp/novnc.log /tmp/x11vnc.log /tmp/fluxbox.log /tmp/dnsmasq.log 2>/dev/null || tail -f /tmp/novnc.log
```
Mantiene proceso en foreground siguiendo logs. Implementa fallback si algunos logs no existen.

### `Docker/client/entrypoint.sh`

Script minimalista de configuración de enrutamiento para contenedores cliente:

```bash
ip route replace default via "${ROUTER_IP}" || true
```
- Establece ruta por defecto hacia el router del portal
- `replace`: Sobrescribe ruta existente si presente
- `|| true`: Continúa ejecución incluso si el comando falla (tolerancia a fallos)
- Requiere capability `NET_ADMIN` en el contenedor

### `Docker/config/create_lan.sh`

Script idempotente para creación de red Docker bridge:

```bash
if docker network inspect "${LAN_NET}" >/dev/null 2>&1; then
  echo "La red ${LAN_NET} ya existe."
else
  docker network create --driver bridge \
    --subnet "${SUBNET}" --gateway "${GATEWAY}" "${LAN_NET}"
fi
```
- Verificación de existencia previa para evitar errores
- Configuración de subred y gateway personalizados
- Driver `bridge`: Red virtual con switch software integrado

### `Docker/config/router_online.sh`

Script de despliegue del contenedor router con configuración completa de red:

**Capacidades de red requeridas:**
```bash
--cap-add=NET_ADMIN --cap-add=NET_RAW --sysctl net.ipv4.ip_forward=1
```
- `NET_ADMIN`: Permite configuración de interfaces, rutas, iptables, ipset
- `NET_RAW`: Necesario para operaciones de bajo nivel con sockets raw
- `net.ipv4.ip_forward=1`: Habilita forwarding IP a nivel de contenedor

**Configuración de interfaces:**
- `UPLINK_IF=eth0`: Primera interfaz (red Docker por defecto) actúa como WAN
- `LAN_IF=eth1`: Segunda interfaz añadida posteriormente con `docker network connect`

**Conexión a red LAN:**
```bash
docker network connect --ip "${LAN_IP}" "${LAN_NET}" router
```
Ejecutado después de `docker run` para añadir interfaz adicional al contenedor en ejecución con IP estática específica.

### `Docker/config/client_online.sh`

Script de aprovisionamiento masivo de clientes para pruebas:

**Función de creación de cliente:**
```bash
run_client () {
  local NAME="$1"; local IP="$2"; local PORT="$3"; local PW="$4"
  docker rm -f "${NAME}" 2>/dev/null || true
  docker run -d --name "${NAME}" \
    --network "${LAN_NET}" --ip "${IP}" \
    --cap-add=NET_ADMIN \
    --dns "${ROUTER_IP}" \
    -e ROUTER_IP="${ROUTER_IP}" \
    -e VNC_PW="${PW}" \
    -e BROWSER_URL="${BROWSER_URL:-https://example.com}" \
    -p "${PORT}:6081" \
    "${IMAGE}" bash -lc '/entrypoint.sh /usr/local/bin/start-ui.sh'
}
```

**Parámetros clave:**
- `--network "${LAN_NET}" --ip "${IP}"`: Asignación de IP estática en red LAN
- `--dns "${ROUTER_IP}"`: Fuerza uso del DNS del router (crítico para resolución de `portal.hastalap`)
- `-p "${PORT}:6081"`: Mapeo de puerto noVNC único por cliente para acceso simultáneo desde host
- `bash -lc`: Shell login que ejecuta entrypoint y start-ui en secuencia

**Instanciación de clientes:**
Crea tres clientes (c1, c2, c3) con IPs consecutivas (`10.200.0.11`, `.12`, `.13`) y puertos noVNC mapeados a 6081, 6082, 6083 del host.

## Flujo de Operación

### Fase de Inicialización

1. **Creación de infraestructura de red:**
   ```bash
   cd Docker/config
   ./create_lan.sh
   ```
   Establece red bridge `lan0` con subred `10.200.0.0/24`.

2. **Construcción de imágenes:**
   ```bash
   docker build -t router:latest ./Docker/router
   docker build -t client:latest ./Docker/client
   ```

3. **Despliegue de router:**
   ```bash
   ./router_online.sh router:latest
   ```
   - Inicia contenedor con capacidades de red elevadas
   - Conecta interfaz adicional a red LAN con IP `10.200.0.254`
   - El entrypoint configura iptables, ipset, dnsmasq, nginx y backend Python

4. **Despliegue de clientes:**
   ```bash
   ./client_online.sh
   ```
   Levanta clientes c1, c2, c3 con acceso noVNC en `http://localhost:6081`, `6082`, `6083`.

### Ciclo de Autenticación

#### Cliente No Autenticado

1. **Detección automática del portal:**
   - El sistema operativo del cliente realiza peticiones de conectividad:
     - Android: `GET /generate_204` (espera código 204, recibe 302)
     - iOS/macOS: `GET /hotspot-detect.html` (espera HTML específico, recibe redirección)
     - Windows: `GET /connecttest.txt` o `/ncsi.txt` (espera texto específico)
   
2. **Interceptación de tráfico HTTP:**
   - Cliente intenta acceder a `http://example.com`
   - Regla iptables en PREROUTING detecta IP no presente en `ipset authed`
   - DNAT redirige conexión a `${LAN_IP}:80` (nginx local)
   - Nginx responde con redirección 302 a `https://${CERT_CN}/login`

3. **Resolución DNS controlada:**
   - Cliente resuelve `portal.hastalap` (o CN configurado)
   - `dnsmasq` responde con IP del router (`10.200.0.254`)
   - Evita dependencia de DNS externo y garantiza acceso al portal

4. **Presentación del portal:**
   - Navegador establece conexión TLS con nginx (puerto 443)
   - Nginx realiza proxy_pass al backend Python (puerto 8080)
   - Backend sirve formulario de login mediante plantilla HTML

#### Proceso de Autenticación

1. **Envío de credenciales:**
   - Usuario completa formulario y envía POST a `/login`
   - Backend extrae IP del cliente desde header `X-Real-IP` (inyectado por nginx)

2. **Validación:**
   ```python
   users_dict = load_users()
   if username in users_dict and users_dict[username] == password:
       # Autenticación exitosa
   ```
   - Comparación con credenciales en `users.json`
   - Hash/cifrado de contraseñas opcional (actualmente texto plano para simplicidad académica)

3. **Autorización en firewall:**
   ```python
   subprocess.run(["ipset", "add", "authed", client_ip, "timeout", str(AUTH_TIMEOUT)])
   ```
   - Añade IP del cliente al conjunto `ipset authed` con timeout
   - Operación atómica a nivel de kernel, inmediatamente efectiva

4. **Activación de acceso:**
   - Reglas iptables en FORWARD permiten tráfico de IPs en conjunto `authed`
   - Cliente puede realizar conexiones a Internet sin restricciones
   - Timeout configurable (por defecto 3600 segundos) tras el cual la IP se elimina automáticamente

#### Cliente Autenticado

- Todo el tráfico hacia WAN atraviesa regla iptables:
  ```bash
  iptables -I FORWARD 1 -i $LAN_IF -o $UPLINK_IF -m set --match-set authed src -j ACCEPT
  ```
- Peticiones HTTP ya no son redirigidas (regla PREROUTING no coincide)
- Navegación normal sin interceptación

### Panel de Administración

Acceso protegido con HTTP Basic Authentication:

1. **Acceso al panel:**
   - URL: `https://portal.hastalap/admin`
   - Credenciales del usuario `admin` definidas en `users.json`

2. **Funcionalidades:**
   - **Visualización de IPs autorizadas:**
     ```bash
     ipset list authed
     ```
     Muestra conjunto actual con tiempos de expiración restantes
   
   - **Revocación manual de acceso:**
     ```python
     subprocess.run(["ipset", "del", "authed", ip_address])
     ```
     Elimina IP específica inmediatamente del conjunto autorizado

   - **Gestión de usuarios (futuro):**
     - Agregar/eliminar usuarios
     - Modificar credenciales
     - Configurar permisos por usuario

## Requisitos del Sistema

### Software

- **Docker Engine**: ≥ 20.10
- **Docker Compose** (opcional): ≥ 2.0 para orquestación simplificada
- **Sistema operativo host**:
  - Linux (nativo): Funcionalidad completa
  - Windows con WSL2: Funcional con limitaciones en `--network=host`
  - macOS con Docker Desktop: Funcional con limitaciones similares a Windows

### Capacidades de Red

El contenedor router requiere privilegios elevados:
- `CAP_NET_ADMIN`: Configuración de interfaces, iptables, ipset
- `CAP_NET_RAW`: Manipulación de sockets raw para iptables
- Alternativa: `--privileged` (otorga todas las capacidades, menos seguro)

### Recursos Mínimos

- **CPU**: 2 núcleos (recomendado 4 para múltiples clientes con UI)
- **RAM**: 2 GB (4 GB recomendado con clientes gráficos)
- **Disco**: 500 MB para imágenes base + logs

## Configuración

### Variables de Entorno

#### Router (`Docker/router/entrypoint.sh`)

| Variable | Valor por Defecto | Descripción |
|----------|-------------------|-------------|
| `UPLINK_IF` | `eth0` | Interfaz de red WAN (hacia Internet) |
| `LAN_IF` | `eth1` | Interfaz de red LAN (hacia clientes) |
| `LAN_IP` | `10.200.0.254` | Dirección IP del router en la LAN |
| `LAN_CIDR` | `10.200.0.0/24` | Subred de la LAN en notación CIDR |
| `PORTAL_PORT` | `8080` | Puerto del backend Python |
| `NGINX_HTTP_PORT` | `80` | Puerto HTTP de nginx |
| `NGINX_HTTPS_PORT` | `443` | Puerto HTTPS de nginx |
| `DNS_CACHE_SIZE` | `1000` | Tamaño de caché de dnsmasq |
| `AUTH_TIMEOUT` | `3600` | Tiempo de expiración de autorizaciones (segundos) |
| `CERT_CN` | `portal.hastalap` | Common Name del certificado TLS |
| `BROWSER_URL` | *(vacío)* | URL para navegador en noVNC (opcional) |

#### Cliente (`Docker/client/entrypoint.sh`)

| Variable | Valor por Defecto | Descripción |
|----------|-------------------|-------------|
| `ROUTER_IP` | `10.200.0.254` | IP del gateway/router |
| `BROWSER_URL` | *(vacío)* | URL inicial del navegador en noVNC |
| `VNC_PW` | *(sin contraseña)* | Contraseña VNC (requiere modificación de scripts) |

### Archivos de Configuración

#### `Docker/router/app/users.json`

Almacén de credenciales de usuarios:
```json
{
  "admin": "admin123",
  "user1": "password1",
  "user2": "password2"
}
```
**Nota de seguridad**: En producción, implementar hash de contraseñas (bcrypt, argon2) y almacenamiento seguro.

#### `Docker/router/app/config.py`

Configuración centralizada del backend Python:
```python
AUTH_TIMEOUT = int(os.getenv("AUTH_TIMEOUT", "3600"))
IPSET_NAME = "authed"
USERS_FILE = Path(__file__).parent / "users.json"
```

## Despliegue

### Secuencia Completa

```bash
# 1. Posicionarse en el directorio del proyecto
cd /ruta/al/Captive-Portal

# 2. Crear red LAN
cd Docker/config
bash create_lan.sh

# 3. Construir imágenes
cd ..
docker build -t router:latest ./router
docker build -t client:latest ./client

# 4. Levantar router
cd config
bash router_online.sh router:latest

# 5. Verificar inicialización del router
docker logs -f router
# Esperar mensaje: "Router listo. Portal en https://portal.hastalap"
# Ctrl+C para salir del seguimiento de logs

# 6. Levantar clientes
bash client_online.sh

# 7. Acceder a interfaces noVNC
# - Router: http://localhost:6091
# - Cliente 1: http://localhost:6081
# - Cliente 2: http://localhost:6082
# - Cliente 3: http://localhost:6083
```

### Verificación del Sistema

#### Comprobar reglas iptables en el router:
```bash
docker exec router iptables -t nat -L -n -v
docker exec router iptables -L FORWARD -n -v
```

#### Inspeccionar conjunto ipset:
```bash
docker exec router ipset list authed
```

#### Verificar conectividad desde cliente:
```bash
# Acceder a shell de cliente
docker exec -it c1 bash

# Probar resolución DNS
nslookup portal.hastalap
# Debe resolver a 10.200.0.254

# Intentar acceso HTTP antes de autenticación
curl -I http://example.com
# Debe recibir redirección 302

# Verificar ruta por defecto
ip route show default
# Debe mostrar: default via 10.200.0.254
```

## Consideraciones de Seguridad

### En Entorno Académico/Laboratorio

El proyecto está diseñado para demostraciones y aprendizaje, con configuraciones permisivas aceptables en redes aisladas:

- **VNC sin contraseña**: Apropiado en red de laboratorio sin acceso externo
- **Certificado autofirmado**: Suficiente para demostrar funcionamiento de TLS
- **Credenciales en texto plano**: Simplifica comprensión del flujo de autenticación
- **`--no-sandbox` en Chromium**: Necesario en contenedores, bajo riesgo en entorno controlado

### Para Despliegue en Producción

Modificaciones críticas requeridas:

1. **Autenticación VNC:**
   ```bash
   x11vnc -display :1 -usepw -forever
   ```
   Habilitar contraseña con `-usepw` y configurarla previamente.

2. **Certificados TLS válidos:**
   - Utilizar Let's Encrypt para certificados firmados por CA de confianza
   - Actualizar configuración de nginx para usar certificados reales
   - Configurar renovación automática de certificados

3. **Hash de contraseñas:**
   ```python
   import bcrypt
   hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
   ```
   Almacenar solo hashes en `users.json`.

4. **Restricción de capacidades Docker:**
   - Evitar `--privileged`
   - Usar solo las capacidades mínimas necesarias (`NET_ADMIN`, `NET_RAW`)
   - Implementar perfiles AppArmor/SELinux

5. **Logging y auditoría:**
   - Registrar todos los intentos de autenticación
   - Monitorizar cambios en conjunto `ipset`
   - Implementar rotación de logs

6. **Hardening de iptables:**
   - Reglas de rate limiting para prevenir ataques de fuerza bruta
   - Logging de paquetes rechazados para análisis forense
   - Reglas de salida restrictivas (egress filtering)

7. **Aislamiento de red:**
   - VLANs físicas separadas para segmentación real
   - No exponer puertos noVNC (`6081`, `6091`) fuera de red de gestión
   - Implementar segmentación entre usuarios autenticados

## Troubleshooting

### Router no inicia correctamente

**Síntoma:** Contenedor se detiene inmediatamente o muestra errores de permisos.

**Diagnóstico:**
```bash
docker logs router
```

**Causas comunes:**
1. **Falta de capacidades de red:**
   ```
   Error: iptables: Permission denied
   ```
   **Solución:** Verificar que `docker run` incluye `--cap-add=NET_ADMIN --cap-add=NET_RAW`.

2. **Interfaz LAN no recibe IP:**
   ```
   [2025-11-17 10:30:45] Esperando IP en eth1... (intentos agotados)
   ```
   **Solución:** Verificar que `docker network connect` se ejecutó correctamente:
   ```bash
   docker inspect router | grep Networks -A 20
   ```

3. **Puerto 8080 ya en uso:**
   ```
   OSError: [Errno 98] Address already in use
   ```
   **Solución:** Cambiar `PORTAL_PORT` o identificar proceso conflictivo en host.

### Cliente no puede acceder a Internet después de autenticación

**Diagnóstico:**
```bash
# En router, verificar que IP está en ipset
docker exec router ipset list authed

# Verificar reglas FORWARD
docker exec router iptables -L FORWARD -n -v --line-numbers

# En cliente, probar conectividad
docker exec c1 ping -c 3 8.8.8.8
```

**Causas comunes:**
1. **IP no añadida al conjunto `ipset`:**
   - Revisar logs del backend Python para errores en `subprocess.run(["ipset", "add", ...])`
   - Añadir manualmente para test: `docker exec router ipset add authed 10.200.0.11`

2. **Orden incorrecto de reglas FORWARD:**
   - La regla de ACCEPT para `authed` debe estar antes que las de REJECT
   - Verificar con `iptables -L FORWARD --line-numbers`

3. **NAT no funcional:**
   ```bash
   docker exec router iptables -t nat -L POSTROUTING -n -v
   ```
   Debe haber regla MASQUERADE hacia interfaz WAN.

### Portal no redirige tráfico HTTP

**Síntoma:** Cliente accede directamente a sitios web sin ver página de login.

**Diagnóstico:**
```bash
# Verificar regla de redirección PREROUTING
docker exec router iptables -t nat -L PREROUTING -n -v

# Captura de tráfico (si tcpdump está disponible)
docker exec router tcpdump -i eth1 -n port 80
```

**Causas comunes:**
1. **Cliente ya autenticado:**
   - IP presente en `ipset authed`
   - Eliminar para test: `docker exec router ipset del authed 10.200.0.11`

2. **DNS no apunta al router:**
   - Cliente resuelve nombres con DNS externo, bypass del portal
   - Verificar: `docker exec c1 cat /etc/resolv.conf`
   - Debe contener `nameserver 10.200.0.254`

3. **Nginx no escucha en puerto 80:**
   ```bash
   docker exec router netstat -tlnp | grep :80
   ```
   Debe mostrar nginx escuchando en `0.0.0.0:80`.

### Certificado TLS rechazado por navegador

**Síntoma:** Navegador muestra error "Your connection is not private" / "NET::ERR_CERT_AUTHORITY_INVALID".

**Explicación:** Comportamiento esperado con certificados autofirmados.

**Opciones:**
1. **Aceptar excepción manualmente** (apropiado para laboratorio):
   - Chrome: Click en "Advanced" → "Proceed to portal.hastalap (unsafe)"
   - Firefox: "Advanced" → "Accept the Risk and Continue"

2. **Instalar CA raíz en cliente** (para pruebas extensivas):
   ```bash
   # Exportar certificado del router
   docker cp router:/etc/ssl/certs/portal.crt ./

   # En sistema host, añadir a almacén de confianza
   # Linux: cp portal.crt /usr/local/share/ca-certificates/ && update-ca-certificates
   # Windows: Import certificate → Trusted Root Certification Authorities
   # macOS: Keychain Access → Add to System → Trust Always
   ```

### Interfaz noVNC no carga

**Síntoma:** `http://localhost:6081` no responde o muestra error de conexión.

**Diagnóstico:**
```bash
# Verificar que contenedor está en ejecución
docker ps | grep c1

# Verificar logs de websockify
docker exec c1 cat /tmp/novnc.log

# Verificar puerto mapeado
docker port c1
```

**Causas comunes:**
1. **Puerto no mapeado correctamente:**
   - Verificar que `docker run` incluye `-p 6081:6081`
   - Posible conflicto si puerto ya está en uso en host

2. **Servicios noVNC no iniciados:**
   ```bash
   docker exec c1 pgrep websockify
   docker exec c1 pgrep x11vnc
   ```
   Si no hay PIDs, `start-ui.sh` no se ejecutó correctamente.

3. **Xvfb falló al iniciar:**
   ```bash
   docker exec c1 cat /tmp/fluxbox.log
   ```
   Puede indicar falta de permisos o dependencias.

## Mejoras Futuras

### Funcionalidades Planificadas

1. **Base de datos para usuarios:**
   - Migración de `users.json` a SQLite o PostgreSQL
   - Soporte para miles de usuarios
   - Auditoría de sesiones y comportamiento

2. **Autenticación RADIUS/LDAP:**
   - Integración con servicios de directorio corporativos
   - Single Sign-On (SSO)
   - Sincronización automática de usuarios

3. **Límites de ancho de banda por usuario:**
   - Implementación con `tc` (traffic control)
   - QoS diferenciado por planes de servicio
   - Estadísticas de consumo en tiempo real

4. **Portal multilingüe:**
   - Detección de idioma del navegador
   - Templates Jinja2 con i18n
   - Configuración regional por ubicación

5. **API REST para gestión:**
   - Endpoints para CRUD de usuarios
   - Consulta de sesiones activas
   - Integración con sistemas de billing

6. **Captcha en formulario de login:**
   - Prevención de ataques automatizados
   - Integración con reCAPTCHA o hCaptcha
   - Rate limiting por IP

7. **Dashboard administrativo web:**
   - Visualizaciones de métricas con Chart.js/D3.js
   - Alertas configurables
   - Gestión de políticas de firewall

### Optimizaciones

1. **Reducción de tamaño de imágenes:**
   - Multi-stage builds en Dockerfile
   - Uso de imágenes alpine cuando sea posible
   - Eliminación de dependencias de compilación

2. **Cache de resoluciones DNS:**
   - Incrementar `cache-size` de dnsmasq para redes grandes
   - Implementar DNS recursivo local completo

3. **Persistencia de sesiones:**
   - Almacenamiento de conjunto `ipset` en disco
   - Restauración automática tras reinicio del contenedor
   - Respaldo de `users.json` con versionado

## Scripts de Despliegue

### Docker

- **`Docker/1-prepare.sh`**: Construye las imágenes Docker (router y clientes)
- **`Docker/2-deploy.sh`**: Despliega los contenedores con configuración de red (porta-lan con 2 clientes)

### Native (Linux)

- **`native/install-router.sh`**: Script de instalación completo que:
  - Instala dependencias (iptables, dnsmasq, nginx, python3, etc.)
  - Configura el sistema (IP forwarding, NAT, firewall)
  - Crea el servicio systemd `portal-cautivo`
  - Inicia automáticamente todos los servicios
  - **Uso**: `sudo bash native/install-router.sh`

## Documentación Adicional

- **`notes/SETUP_VM_VIRTUALBOX.md`**: Guía completa paso a paso para configurar 2 máquinas virtuales Ubuntu con VirtualBox (router + cliente) incluyendo:
  - Creación de red Host-Only
  - Instalación de Ubuntu Desktop en ambas VMs
  - Configuración de interfaces de red
  - Instalación del portal mediante script
  - Pruebas y troubleshooting

## Licencia

Este proyecto se desarrolla con fines educativos y académicos. Consultar archivo `LICENSE` para detalles de distribución y uso.

## Autores y Contribuciones

Proyecto desarrollado para el curso de Redes de Computadoras.

Para reportar problemas o sugerir mejoras, utilizar el sistema de issues del repositorio.

## Referencias

- [Netfilter/iptables Documentation](https://www.netfilter.org/documentation/)
- [ipset Man Page](https://ipset.netfilter.org/ipset.man.html)
- [dnsmasq Manual](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
- [RFC 8910: Captive-Portal Identification in DHCP and Router Advertisements](https://datatracker.ietf.org/doc/html/rfc8910)
- [Docker Network Documentation](https://docs.docker.com/network/)
- [nginx Reverse Proxy Guide](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/)
