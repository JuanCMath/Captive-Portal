# Análisis Técnico del Portal Cautivo
## Proyecto de Redes de Computadoras - Universidad de La Habana, Curso 2025

---

## Tabla de Contenidos

1. [Introducción](#introducción)
2. [Fundamentos Teóricos](#fundamentos-teóricos)
3. [Arquitectura del Sistema](#arquitectura-del-sistema)
4. [Análisis de Requisitos Mínimos](#análisis-de-requisitos-mínimos)
   - 4.1 [Endpoint HTTP de Inicio de Sesión](#41-endpoint-http-de-inicio-de-sesión)
   - 4.2 [Bloqueo de Enrutamiento](#42-bloqueo-de-enrutamiento)
   - 4.3 [Mecanismo de Definición de Cuentas de Usuario](#43-mecanismo-de-definición-de-cuentas-de-usuario)
   - 4.4 [Manejo de Usuarios Concurrentes](#44-manejo-de-usuarios-concurrentes)
5. [Análisis de Requisitos Extra](#análisis-de-requisitos-extra)
   - 5.1 [Detección Automática del Portal Cautivo](#51-detección-automática-del-portal-cautivo)
   - 5.2 [Capa de Seguridad HTTPS](#52-capa-de-seguridad-https)
   - 5.3 [Control de Suplantación de IP](#53-control-de-suplantación-de-ip)
   - 5.4 [Enmascaramiento IP (NAT)](#54-enmascaramiento-ip-nat)
   - 5.5 [Experiencia de Usuario y Diseño](#55-experiencia-de-usuario-y-diseño)
6. [Flujo de Funcionamiento](#flujo-de-funcionamiento)
7. [Estructura de Archivos](#estructura-de-archivos)
8. [Conclusiones](#conclusiones)

---

## Introducción

Un **portal cautivo** (*captive portal*) es una técnica de control de acceso a redes que intercepta el tráfico de dispositivos no autenticados y los redirige hacia una página de autenticación antes de permitirles acceso a recursos externos (típicamente Internet). Esta tecnología es ampliamente utilizada en redes Wi-Fi públicas de aeropuertos, hoteles, universidades y espacios comerciales.

Este documento presenta un análisis académico exhaustivo de la implementación de un portal cautivo desarrollado como proyecto de la asignatura Redes de Computadoras. La solución está construida utilizando exclusivamente la biblioteca estándar de Python y herramientas de línea de comandos del sistema operativo Linux, específicamente `iptables` e `ipset` para el control de firewall.

### Objetivos del Proyecto

El proyecto busca demostrar comprensión práctica de:
- Configuración de reglas de firewall con `iptables`
- Gestión de conjuntos de IPs dinámicos con `ipset`
- Implementación de servidores HTTP desde cero
- Arquitectura de red con NAT y enrutamiento
- Programación concurrente para manejo de múltiples clientes

---

## Fundamentos Teóricos

### ¿Qué es iptables?

`iptables` es el sistema de filtrado de paquetes del kernel Linux. Opera mediante **tablas** que contienen **cadenas** de **reglas**. Las tablas principales son:

| Tabla | Propósito |
|-------|-----------|
| `filter` | Filtrado de paquetes (ACCEPT, DROP, REJECT) |
| `nat` | Traducción de direcciones de red (DNAT, SNAT, MASQUERADE) |
| `mangle` | Modificación de paquetes |

Las cadenas predefinidas determinan cuándo se evalúan las reglas:

- **PREROUTING**: Antes de decidir el enrutamiento (tabla nat)
- **INPUT**: Paquetes destinados al host local (tabla filter)
- **FORWARD**: Paquetes que atraviesan el host (tabla filter)
- **OUTPUT**: Paquetes generados localmente (tabla filter)
- **POSTROUTING**: Después del enrutamiento (tabla nat)

### ¿Qué es ipset?

`ipset` es una extensión del kernel que permite definir conjuntos de direcciones IP, redes o puertos que pueden ser referenciados eficientemente desde reglas de `iptables`. Los principales tipos de conjuntos son:

- `hash:ip` - Conjunto de direcciones IP individuales
- `hash:net` - Conjunto de subredes
- `hash:ip,port` - Combinaciones IP-puerto

La ventaja de `ipset` sobre múltiples reglas de `iptables` es su eficiencia: la búsqueda en un conjunto hash es O(1), mientras que múltiples reglas son O(n).

### NAT (Network Address Translation)

NAT permite que múltiples dispositivos de una red privada compartan una única IP pública. En este proyecto se utiliza **MASQUERADE**, una forma de Source NAT (SNAT) que automáticamente utiliza la IP de la interfaz de salida:

```
Red LAN (10.200.0.0/24) → Router → Internet
   IP privada          MASQUERADE   IP pública
```

---

## Arquitectura del Sistema

La solución se implementa mediante contenedores Docker que simulan una topología de red con:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Internet (WAN)                           │
│                           eth0                                  │
└────────────────────────────┬────────────────────────────────────┘
                             │
                    ┌────────┴────────┐
                    │     ROUTER      │
                    │  (Portal)       │
                    │                 │
                    │  - iptables     │
                    │  - ipset        │
                    │  - dnsmasq      │
                    │  - nginx        │
                    │  - Python HTTP  │
                    └────────┬────────┘
                             │ eth1 (10.200.0.254)
                             │
              ┌──────────────┴──────────────┐
              │        LAN (lan0)           │
              │     10.200.0.0/24           │
              ├──────────────┬──────────────┤
              │              │              │
         ┌────┴────┐    ┌────┴────┐    ┌────┴────┐
         │ Cliente │    │ Cliente │    │ Cliente │
         │   .1    │    │   .2    │    │   .n    │
         └─────────┘    └─────────┘    └─────────┘
```

### Componentes del Sistema

| Componente | Tecnología | Función |
|------------|------------|---------|
| Router | Debian + iptables/ipset | Gateway, firewall, control de acceso |
| DNS | dnsmasq | Resolución de nombres local |
| Proxy TLS | nginx | Terminación HTTPS, redirección |
| Backend | Python HTTP Server | Autenticación, gestión de sesiones |
| Clientes | Debian + Chromium | Simulación de usuarios |

---

## Análisis de Requisitos Mínimos

### 4.1 Endpoint HTTP de Inicio de Sesión

**Requisito**: *"Endpoint HTTP de inicio de sesión en la red"*

#### Implementación

El endpoint de login se implementa en el archivo `Docker/router/app/portal.py` mediante la función `process_login()`:

```python
def process_login(client_ip: str, form_data: Dict[str, List[str]]) -> Tuple[int, Dict[str, str], str]:
    """
    Procesa un POST /login.
    Devuelve (status_code, headers, body_html).
    """
    username = (form_data.get("username") or [""])[0]
    password = (form_data.get("password") or [""])[0]

    _, mapping = load_users()
    stored = mapping.get(username)

    if stored is None or stored != password:
        body = render_login_page(
            client_ip=client_ip,
            auth_timeout=AUTH_TIMEOUT,
            error="Credenciales inválidas. Verifica usuario y contraseña.",
        )
        return 401, {}, body

    ok = add_to_ipset(client_ip)
    # ... manejo de éxito/error
```

#### Flujo del Proceso de Login

1. **Cliente envía POST /login** con `username` y `password` en formato `application/x-www-form-urlencoded`
2. **Servidor extrae credenciales** mediante `_parse_post_form()` en `main.py`:
   ```python
   def _parse_post_form(self) -> dict:
       length = int(self.headers.get("Content-Length", "0") or "0")
       raw = self.rfile.read(length).decode("utf-8", errors="ignore")
       return parse_qs(raw)
   ```
3. **Validación contra base de datos** (archivo JSON o variable de entorno)
4. **Si credenciales válidas**: Se añade la IP al conjunto `ipset authed`
5. **Redirección HTTP 302** a `/status` para confirmar autenticación

#### Rutas HTTP Disponibles

| Método | Ruta | Descripción |
|--------|------|-------------|
| GET | `/` o `/login` | Formulario de inicio de sesión |
| POST | `/login` | Procesar autenticación |
| GET | `/status` | Estado de la sesión (HTML) |
| GET | `/status.json` | Estado de la sesión (JSON para AJAX) |
| GET | `/admin/users` | Panel de administración |
| POST | `/admin/users/create` | Crear usuario |
| POST | `/admin/users/delete` | Eliminar usuario |

#### Fundamento Técnico

El servidor HTTP se construye extendiendo `BaseHTTPRequestHandler` de la biblioteca estándar:

```python
class PortalRequestHandler(BaseHTTPRequestHandler):
    server_version = "CaptivePortal/1.0"

    def do_GET(self) -> None:
        # Manejo de peticiones GET
        
    def do_POST(self) -> None:
        # Manejo de peticiones POST
```

Este enfoque cumple con el requisito de no utilizar bibliotecas externas, implementando el protocolo HTTP/1.1 mediante las clases proporcionadas por Python.

---

### 4.2 Bloqueo de Enrutamiento

**Requisito**: *"Bloqueo de cualquier tipo de enrutamiento hasta no haber iniciado sesión en la red"*

#### Implementación

El bloqueo se implementa mediante una combinación de `ipset` e `iptables` en el script `Docker/router/entrypoint.sh`:

##### Paso 1: Creación del Conjunto ipset

```bash
ipset create authed hash:ip timeout "${AUTH_TIMEOUT}" -exist
```

Este comando crea un conjunto de tipo `hash:ip` llamado `authed` donde:
- `hash:ip`: Almacena direcciones IPv4 individuales
- `timeout ${AUTH_TIMEOUT}`: Cada entrada expira automáticamente después de N segundos (por defecto 3600)
- `-exist`: No falla si el conjunto ya existe

##### Paso 2: Reglas de Redirección (Tabla NAT)

```bash
# Crear cadena personalizada para redirección
iptables -t nat -N CP_REDIRECT 2>/dev/null || true

# Redirigir HTTP de no autenticados al portal
iptables -t nat -A PREROUTING -i "$LAN_IF" -p tcp --dport 80 \
  -m set ! --match-set authed src -j CP_REDIRECT

# CP_REDIRECT → DNAT hacia nginx local
iptables -t nat -A CP_REDIRECT -p tcp -j DNAT --to-destination "${LAN_IP}:${NGINX_HTTP_PORT}"
```

**Explicación de la regla**:
- `-t nat -A PREROUTING`: Aplica antes del enrutamiento en tabla NAT
- `-i "$LAN_IF"`: Solo paquetes entrando por interfaz LAN
- `-p tcp --dport 80`: Solo tráfico TCP destinado al puerto 80
- `-m set ! --match-set authed src`: **Si la IP origen NO está en el conjunto `authed`**
- `-j CP_REDIRECT`: Saltar a cadena personalizada que hace DNAT

##### Paso 3: Reglas de Forwarding (Tabla Filter)

```bash
# AUTENTICADOS → Permitir acceso a Internet
iptables -I FORWARD 1 -i "$LAN_IF" -o "$UPLINK_IF" -m set --match-set authed src -j ACCEPT

# NO autenticados → Bloquear HTTPS
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -p tcp --dport 443 \
  -m set ! --match-set authed src -j REJECT --reject-with tcp-reset

# NO autenticados → Bloquear todo lo demás
iptables -A FORWARD -i "$LAN_IF" -o "$UPLINK_IF" -j REJECT
```

#### Diagrama de Flujo de Paquetes

```
         Paquete desde Cliente LAN
                    │
                    ▼
        ┌───────────────────────┐
        │ ¿IP en conjunto       │
        │     "authed"?         │
        └───────────┬───────────┘
               ┌────┴────┐
               │         │
              SÍ        NO
               │         │
               ▼         ▼
        ┌──────────┐  ┌──────────────┐
        │ ACCEPT   │  │ ¿Puerto 80?  │
        │ Forward  │  └──────┬───────┘
        │ a WAN    │     ┌───┴───┐
        └──────────┘    SÍ      NO
                         │       │
                         ▼       ▼
                  ┌─────────┐ ┌────────┐
                  │ DNAT a  │ │ REJECT │
                  │ Portal  │ │        │
                  └─────────┘ └────────┘
```

##### Autorización de IP tras Login Exitoso

Cuando un usuario se autentica correctamente, la función `add_to_ipset()` en `ipset_utils.py` registra su IP:

```python
def add_to_ipset(ip: str) -> bool:
    """Añade la IP al conjunto 'authed' con timeout."""
    try:
        subprocess.run(
            ["ipset", "add", "authed", ip, "timeout", str(AUTH_TIMEOUT), "-exist"],
            check=True,
        )
        return True
    except Exception as e:
        print(f"Error añadiendo {ip} a ipset: {e}")
        return False
```

**Parámetros del comando**:
- `add authed ip`: Añade la IP al conjunto `authed`
- `timeout N`: Duración de la entrada (sobrescribe default del conjunto)
- `-exist`: No falla si la IP ya existe (renueva el timeout)

---

### 4.3 Mecanismo de Definición de Cuentas de Usuario

**Requisito**: *"Mecanismo de definición de cuentas de usuario"*

#### Implementación

El sistema de usuarios se implementa en `Docker/router/app/users.py` con almacenamiento en JSON:

##### Estructura de Datos

```json
[
  {"u": "admin", "p": "admin"},
  {"u": "estudiante1", "p": "clave123"},
  {"u": "invitado", "p": "wifi2025"}
]
```

##### Fuentes de Configuración (Prioridad)

1. **Variable de entorno `USERS_JSON`**: Permite inyectar usuarios sin modificar archivos
2. **Archivo `users.json`**: Almacenamiento persistente
3. **Fallback**: Usuario `admin/admin` si no hay otras fuentes

```python
def load_users() -> Tuple[List[Dict[str, str]], Dict[str, str]]:
    """
    Carga usuarios desde:
    1) Variable de entorno USERS_JSON (si existe)
    2) Archivo USERS_FILE
    3) Fallback: admin/admin
    """
    data = _load_from_env()
    if not data:
        if USERS_FILE.exists():
            try:
                data = json.loads(USERS_FILE.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                print("users.json mal formado, usando fallback.")
                data = []
        if not data:
            data = [{"u": "admin", "p": "admin"}]
    # ... procesamiento
```

##### Operaciones CRUD

**Crear Usuario**:
```python
def create_user(username: str, password: str) -> Tuple[bool, str]:
    username = username.strip()
    if not username or " " in username:
        return False, "El nombre de usuario no puede estar vacío ni contener espacios."

    users, mapping = load_users()
    if username in mapping:
        return False, f"El usuario '{username}' ya existe."

    users.append({"u": username, "p": password})
    save_users(users)
    return True, f"Usuario '{username}' creado correctamente."
```

**Eliminar Usuario**:
```python
def delete_user(username: str) -> Tuple[bool, str]:
    username = username.strip()
    users, mapping = load_users()

    if username == "admin":
        return False, "No se puede eliminar la cuenta 'admin'."

    if username not in mapping:
        return False, f"El usuario '{username}' no existe."

    new_users = [u for u in users if u.get("u") != username]
    save_users(new_users)
    return True, f"Usuario '{username}' eliminado correctamente."
```

##### Panel de Administración

El panel web (`/admin/users`) permite gestión visual de usuarios con autenticación HTTP Basic:

```python
def _require_admin(self) -> str | None:
    auth_header = self.headers.get("Authorization")
    creds = auth.parse_basic_auth(auth_header)
    if not creds or not auth.is_admin(*creds):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Admin"')
        # ...
```

La autenticación Basic codifica `usuario:contraseña` en Base64:
```python
def parse_basic_auth(header_value: Optional[str]) -> Optional[Tuple[str, str]]:
    # "Basic dXN1YXJpbzpwYXNzd29yZA==" → ("usuario", "password")
    b64_part = header_value.split(" ", 1)[1].strip()
    decoded = base64.b64decode(b64_part).decode("utf-8")
    username, password = decoded.split(":", 1)
    return username, password
```

---

### 4.4 Manejo de Usuarios Concurrentes

**Requisito**: *"Empleo de hilos y/o procesos para el manejo de varios usuarios concurrentes"*

#### Implementación

La concurrencia se logra mediante `ThreadingMixIn` de la biblioteca estándar:

```python
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
```

##### Funcionamiento del ThreadingMixIn

Esta clase utiliza el patrón de diseño **Mixin** para extender `HTTPServer` con capacidades de threading:

1. **Sin ThreadingMixIn** (comportamiento default):
   ```
   Cliente A ──► Servidor procesa A ──► Responde A ──► Servidor libre
   Cliente B ──► [ESPERA] ──► Servidor procesa B ──► Responde B
   ```

2. **Con ThreadingMixIn**:
   ```
   Cliente A ──┬──► Thread 1: procesa A ──► Responde A
               │
   Cliente B ──┴──► Thread 2: procesa B ──► Responde B
               │
   Cliente C ──────► Thread 3: procesa C ──► Responde C
   ```

##### Código del Servidor

```python
def run_server(port: int) -> None:
    addr = ("0.0.0.0", port)
    httpd = ThreadingHTTPServer(addr, PortalRequestHandler)
    log(f"Servidor HTTP escuchando en puerto {port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("Servidor detenido por KeyboardInterrupt")
    finally:
        httpd.server_close()
```

##### Características de `daemon_threads = True`

- Los hilos se marcan como *daemon*, lo que significa que **no bloquean la terminación del programa principal**
- Cuando el proceso padre termina (ej: Ctrl+C), los hilos daemon se terminan automáticamente
- Ideal para servidores donde queremos shutdown limpio sin esperar conexiones pendientes

##### Diagrama de Arquitectura Concurrente

```
                    ┌─────────────────────────────────────┐
                    │         ThreadingHTTPServer         │
                    │                                     │
                    │  ┌─────────┐   accept()             │
     Conexión ────► │  │ Socket  │ ──────────┐            │
                    │  │ Listen  │           │            │
                    │  └─────────┘           ▼            │
                    │              ┌──────────────────┐   │
                    │              │   Thread Pool    │   │
                    │              │  ┌────┬────┬───┐ │   │
                    │              │  │ T1 │ T2 │...│ │   │
                    │              │  └────┴────┴───┘ │   │
                    │              └──────────────────┘   │
                    └─────────────────────────────────────┘
                                        │
                                        ▼
                              ┌──────────────────┐
                              │ PortalRequest    │
                              │    Handler       │
                              │                  │
                              │ - do_GET()       │
                              │ - do_POST()      │
                              │ - do_HEAD()      │
                              └──────────────────┘
```

##### Ventajas de esta Implementación

1. **Simplicidad**: Una sola línea (`ThreadingMixIn`) habilita concurrencia
2. **Sin dependencias**: Usa solo biblioteca estándar
3. **Escalabilidad moderada**: Adecuado para decenas de clientes simultáneos
4. **Thread-safety en ipset**: Los comandos `ipset add/test` son atómicos a nivel kernel

---

## Análisis de Requisitos Extra

### 5.1 Detección Automática del Portal Cautivo

**Requisito Extra**: *"Detección automática del enlace HTTP del portal cautivo en la red" (1 pto)*

#### Implementación

Los sistemas operativos modernos detectan portales cautivos mediante peticiones HTTP a URLs específicas. El proyecto implementa respuestas para las principales plataformas en la configuración de nginx:

```nginx
# Android
location = /generate_204 {
    return 302 https://${CERT_CN}/login;
}

# Windows
location = /connecttest.txt {
    return 302 https://${CERT_CN}/login;
}
location = /ncsi.txt {
    return 302 https://${CERT_CN}/login;
}

# Apple (iOS/macOS)
location = /hotspot-detect.html {
    return 302 https://${CERT_CN}/login;
}
```

#### Mecanismo de Detección por Sistema Operativo

| SO | URL de Prueba | Respuesta Esperada | Comportamiento |
|----|---------------|-------------------|----------------|
| Android | `http://connectivitycheck.gstatic.com/generate_204` | HTTP 204 | Si recibe otra cosa, abre navegador cautivo |
| Windows | `http://www.msftconnecttest.com/connecttest.txt` | `Microsoft Connect Test` | Si falla, muestra notificación de red |
| iOS/macOS | `http://captive.apple.com/hotspot-detect.html` | `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>` | Si difiere, abre CNA (Captive Network Assistant) |

#### Flujo de Detección

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Cliente   │         │   Router    │         │  Internet   │
│  (Android)  │         │   (nginx)   │         │             │
└──────┬──────┘         └──────┬──────┘         └──────┬──────┘
       │                       │                       │
       │  GET /generate_204    │                       │
       │──────────────────────►│                       │
       │                       │                       │
       │  (IP no autenticada)  │                       │
       │  iptables DNAT ───────┤                       │
       │                       │                       │
       │   302 → portal.local  │                       │
       │◄──────────────────────│                       │
       │                       │                       │
       │  [Abre navegador      │                       │
       │   cautivo]            │                       │
       │                       │                       │
```

#### Endpoint Adicional de Detección Manual

```nginx
location = /captive {
    default_type text/html;
    return 200 '<!doctype html>...
      <a href="https://${CERT_CN}/login">Haz clic aquí para iniciar sesión</a>...';
}
```

Este endpoint permite verificación manual navegando a `http://<IP_ROUTER>/captive`.

---

### 5.2 Capa de Seguridad HTTPS

**Requisito Extra**: *"Capa de seguridad HTTPS válida, sobre la URL del portal" (0.5 pts)*

#### Implementación

El sistema genera un certificado TLS autofirmado y configura nginx como proxy inverso HTTPS:

##### Generación de Certificado

```bash
TLS_KEY="/etc/ssl/private/portal.key"
TLS_CERT="/etc/ssl/certs/portal.crt"

if [[ ! -f "$TLS_KEY" || ! -f "$TLS_CERT" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TLS_KEY" \
    -out "$TLS_CERT" \
    -days 365 \
    -subj "/CN=${CERT_CN}"
fi
```

**Parámetros OpenSSL**:
- `-x509`: Genera certificado autofirmado (no CSR)
- `-nodes`: No cifrar clave privada (sin passphrase)
- `-newkey rsa:2048`: Genera nueva clave RSA de 2048 bits
- `-days 365`: Validez de un año
- `-subj "/CN=portal.local"`: Common Name para el certificado

##### Configuración nginx TLS

```nginx
server {
    listen 443 ssl;
    server_name portal.local;

    ssl_certificate     /etc/ssl/certs/portal.crt;
    ssl_certificate_key /etc/ssl/private/portal.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

##### Resolución DNS Local

dnsmasq resuelve `portal.local` a la IP del router:

```bash
# /etc/dnsmasq.d/lan.conf
address=/${CERT_CN}/${LAN_IP}
# Equivale a: address=/portal.local/10.200.0.254
```

#### Flujo HTTPS

```
┌─────────────┐       ┌─────────────┐       ┌─────────────┐
│   Cliente   │       │    nginx    │       │   Python    │
│             │       │  (TLS 443)  │       │   Backend   │
└──────┬──────┘       └──────┬──────┘       └──────┬──────┘
       │                     │                     │
       │ TLS Handshake       │                     │
       │─────────────────────►                     │
       │ (Cert: portal.local)│                     │
       │◄─────────────────────                     │
       │                     │                     │
       │ GET /login (HTTPS)  │                     │
       │─────────────────────►                     │
       │                     │ proxy_pass (HTTP)   │
       │                     │─────────────────────►
       │                     │                     │
       │                     │ HTML Response       │
       │                     │◄─────────────────────
       │ HTML Response       │                     │
       │◄─────────────────────                     │
       │ (cifrado TLS)       │                     │
```

#### Consideraciones de Seguridad

- **Certificado autofirmado**: Los navegadores mostrarán advertencia de seguridad
- **Sin verificación CA**: Apropiado para entornos de prueba/demostración
- **Protocolos TLS 1.2/1.3**: Se descartan versiones obsoletas (TLS 1.0/1.1)

---

### 5.3 Control de Suplantación de IP

**Requisito Extra**: *"Control de la suplantación de IPs de usuarios que hayan iniciado sesión" (0.5 pts)*

#### Implementación

El control de suplantación se implementa mediante la combinación de ipset y reglas iptables que operan a nivel de kernel, más allá del alcance de manipulación por aplicaciones en espacio de usuario.

##### Mecanismo de Protección

1. **Vinculación IP-Autenticación**: La autenticación se asocia exclusivamente a la dirección IP del cliente, no a cookies o tokens de sesión
   
2. **Timeout Automático**: Las IPs autenticadas expiran automáticamente:
   ```bash
   ipset create authed hash:ip timeout 3600
   ```
   
3. **Verificación en Tiempo Real**: Cada paquete se verifica contra el conjunto ipset:
   ```bash
   -m set --match-set authed src
   ```

##### Limitaciones y Mitigaciones

| Amenaza | Protección | Limitación |
|---------|------------|------------|
| IP Spoofing externo | NAT oculta IPs internas | Spoofing interno posible |
| Robo de sesión | No hay cookies/tokens | IP compartida = sesión compartida |
| MAC Spoofing | No implementado | Requeriría arp-scan + ebtables |

##### Verificación de Estado

La función `check_ipset()` permite verificar si una IP está autenticada:

```python
def check_ipset(ip: str) -> bool:
    """Devuelve True si la IP está actualmente en el ipset 'authed'."""
    try:
        res = subprocess.run(
            ["ipset", "test", "authed", ip],
            capture_output=True,
        )
        return res.returncode == 0
    except Exception as e:
        print(f"Error comprobando ipset para {ip}: {e}")
        return False
```

---

### 5.4 Enmascaramiento IP (NAT)

**Requisito Extra**: *"Servicio de enmascaramiento IP sobre la red donde opera el portal cautivo" (0.25 pts)*

#### Implementación

El enmascaramiento se configura en el entrypoint del router:

```bash
# Habilitar forwarding IPv4
sysctl -w net.ipv4.ip_forward=1

# Configurar MASQUERADE (Source NAT dinámico)
iptables -t nat -A POSTROUTING -o "$UPLINK_IF" -j MASQUERADE

# Permitir respuestas de conexiones establecidas
iptables -A FORWARD -i "$UPLINK_IF" -o "$LAN_IF" \
  -m state --state RELATED,ESTABLISHED -j ACCEPT
```

#### Explicación del MASQUERADE

**MASQUERADE** es una variante de SNAT (Source NAT) que automáticamente utiliza la IP de la interfaz de salida. Es ideal cuando la IP externa puede cambiar (DHCP).

```
Antes de MASQUERADE:
┌────────────┐                    ┌────────────┐
│  Cliente   │   src: 10.200.0.1  │  Internet  │
│ 10.200.0.1 │ ──────────────────►│            │
└────────────┘                    └────────────┘
                                       ❌
                          (IP privada no enrutable)

Después de MASQUERADE:
┌────────────┐      ┌────────────┐      ┌────────────┐
│  Cliente   │      │   Router   │      │  Internet  │
│ 10.200.0.1 │ ────►│ MASQUERADE │ ────►│            │
└────────────┘      │            │      └────────────┘
                    │ src: IP_WAN│           ✓
                    └────────────┘
```

#### Tabla de Conexiones (conntrack)

El kernel mantiene una tabla de conexiones para traducir respuestas:

```
tcp   ESTABLISHED src=10.200.0.1 dst=93.184.216.34 sport=54321 dport=80
      src=93.184.216.34 dst=IP_WAN sport=80 dport=54321 [ASSURED]
```

Esto permite que las respuestas de Internet lleguen correctamente al cliente original.

---

### 5.5 Experiencia de Usuario y Diseño

**Requisito Extra**: *"Experiencia de usuario y diseño de la página web del portal" (0.25 pts)*

#### Implementación

El diseño se implementa en `Docker/router/app/static/base.css` con un enfoque moderno:

##### Características Visuales

```css
:root {
    --bg: #0f172a;
    --bg-card: #020617;
    --accent: #38bdf8;
    --accent-soft: rgba(56, 189, 248, 0.15);
    --text: #e5e7eb;
    --muted: #9ca3af;
    --danger: #f97373;
    --border: rgba(148, 163, 184, 0.3);
    --radius: 18px;
}
```

**Paleta de colores**:
- Tema oscuro con fondo degradado (`#0f172a` → `#020617`)
- Acento cyan/azul (`#38bdf8`)
- Texto con contraste adecuado para accesibilidad

##### Elementos de Diseño

1. **Cards con efecto glassmorphism**:
   ```css
   .card {
       background: radial-gradient(circle at top left, var(--accent-soft), #020617 55%);
       border-radius: var(--radius);
       backdrop-filter: blur(18px);
       box-shadow: 0 22px 40px rgba(15, 23, 42, 0.85);
   }
   ```

2. **Botones con gradiente y hover animado**:
   ```css
   button {
       background: linear-gradient(135deg, #38bdf8, #6366f1);
       box-shadow: 0 14px 30px rgba(37, 99, 235, 0.75);
       transition: transform 0.08s ease-out;
   }
   button:hover {
       transform: translateY(-1.5px);
   }
   ```

3. **Indicador de estado visual** (pill):
   ```css
   .status-pill {
       display: inline-flex;
       align-items: center;
       padding: 4px 10px;
       border-radius: 999px;
       background: rgba(15, 23, 42, 0.75);
   }
   .dot.ok {
       background: #22c55e;
       box-shadow: 0 0 8px rgba(34, 197, 94, 0.7);
   }
   ```

##### Páginas Implementadas

1. **Login (`/login`)**: Formulario de autenticación con mensajes de error
2. **Status (`/status`)**: Estado de sesión con actualización AJAX cada 5 segundos
3. **Admin (`/admin/users`)**: Gestión de usuarios con tabla y formulario de creación

##### Actualización Dinámica de Estado

```javascript
async function refreshStatus() {
    const res = await fetch('/status.json', {cache: 'no-store'});
    const data = await res.json();
    
    if (data.authenticated) {
        dot.classList.add('ok');
        text.textContent = "Conectado · acceso a Internet habilitado";
    } else {
        dot.classList.remove('ok');
        text.textContent = "Sesión expirada · vuelve a iniciar sesión";
    }
    expires.textContent = data.expires_in_seconds;
}
setInterval(refreshStatus, 5000);
```

---

## Flujo de Funcionamiento

### Escenario Completo: Usuario No Autenticado

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        FLUJO DE AUTENTICACIÓN                           │
└─────────────────────────────────────────────────────────────────────────┘

1. Cliente se conecta a la red LAN
   └─► Recibe IP 10.200.0.X vía Docker network

2. Cliente intenta acceder a http://google.com
   └─► DNS resuelve google.com correctamente
   └─► iptables intercepta (IP no está en ipset 'authed')
   └─► DNAT redirige al portal (10.200.0.254:80)

3. nginx recibe petición HTTP
   └─► Detecta ruta (/ o /generate_204, etc.)
   └─► Responde 302 → https://portal.local/login

4. Cliente sigue redirección HTTPS
   └─► DNS resuelve portal.local → 10.200.0.254
   └─► TLS handshake con certificado autofirmado
   └─► nginx proxy_pass → Python backend :8080

5. Backend Python sirve formulario de login
   └─► render_login_page() genera HTML
   └─► Cliente ve página de autenticación

6. Usuario envía credenciales (POST /login)
   └─► Backend valida contra users.json
   └─► Si válido: ipset add authed 10.200.0.X timeout 3600
   └─► Responde 302 → /status

7. Cliente ahora está autenticado
   └─► iptables permite FORWARD (IP en ipset 'authed')
   └─► Cliente puede acceder a Internet
   └─► Después de 3600s, IP expira automáticamente
```

---

## Estructura de Archivos

```
Captive-Portal/
├── captiveportal.md          # Descripción del proyecto (requisitos)
├── README.md                 # Documentación técnica
├── ANALISIS_PROYECTO.md      # Este documento
│
├── Docker/
│   ├── config/
│   │   ├── create_lan.sh     # Crea red Docker bridge
│   │   ├── router_online.sh  # Inicia contenedor router
│   │   └── client_online.sh  # Inicia contenedor cliente
│   │
│   ├── router/
│   │   ├── Dockerfile        # Imagen del router/portal
│   │   ├── entrypoint.sh     # Script de inicialización
│   │   ├── start-ui.sh       # UI noVNC opcional
│   │   └── app/
│   │       ├── __init__.py
│   │       ├── main.py       # Servidor HTTP + routing
│   │       ├── portal.py     # Lógica de login/status
│   │       ├── auth.py       # Autenticación HTTP Basic
│   │       ├── admin.py      # Panel de administración
│   │       ├── users.py      # Gestión de usuarios
│   │       ├── ipset_utils.py # Wrapper para ipset CLI
│   │       ├── config.py     # Variables de configuración
│   │       ├── users.json    # Base de datos de usuarios
│   │       └── static/
│   │           └── base.css  # Estilos del portal
│   │
│   └── client/
│       ├── Dockerfile        # Imagen del cliente
│       ├── entrypoint.sh     # Configuración de red
│       └── start-ui.sh       # UI noVNC con Chromium
│
├── notes/                    # Notas de desarrollo
└── scripts/                  # Scripts auxiliares
```

---

## Conclusiones

### Cumplimiento de Requisitos

| Requisito | Estado | Implementación |
|-----------|--------|----------------|
| **Endpoint HTTP de login** | ✅ | `POST /login` en `portal.py` |
| **Bloqueo de enrutamiento** | ✅ | iptables + ipset en `entrypoint.sh` |
| **Definición de usuarios** | ✅ | JSON + API en `users.py` |
| **Concurrencia** | ✅ | `ThreadingMixIn` en `main.py` |
| **Detección automática** | ✅ | Endpoints nginx para Android/iOS/Windows |
| **HTTPS** | ✅ | Certificado TLS + nginx reverse proxy |
| **Control de suplantación** | ✅ | Autenticación por IP + timeout |
| **NAT/MASQUERADE** | ✅ | iptables MASQUERADE |
| **UX/Diseño** | ✅ | CSS moderno con glassmorphism |

### Tecnologías Empleadas

- **Lenguaje**: Python 3 (biblioteca estándar únicamente)
- **Firewall**: iptables, ipset
- **DNS**: dnsmasq
- **Proxy/TLS**: nginx, OpenSSL
- **Contenedores**: Docker
- **Interfaz**: HTML5, CSS3, JavaScript (vanilla)

### Aspectos Destacables

1. **Sin dependencias externas**: Cumple estrictamente con el requisito de usar solo biblioteca estándar de Python
2. **Arquitectura modular**: Separación clara entre componentes (auth, portal, admin, users)
3. **Containerización**: Facilita despliegue y pruebas reproducibles
4. **Documentación**: Código comentado y README detallado

### Posibles Mejoras Futuras

- Implementar verificación MAC para mayor seguridad
- Añadir logging persistente con rotación
- Implementar rate limiting para protección contra brute force
- Dashboard de estadísticas de uso de red
- Integración con LDAP/RADIUS para autenticación empresarial

---

*Documento elaborado como análisis académico del proyecto de Portal Cautivo para la asignatura Redes de Computadoras, Universidad de La Habana, 2025.*
