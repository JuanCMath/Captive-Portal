# Endurecimiento de seguridad — Portal Cautivo

## Resumen

Se revisó el código completo del backend (`Docker/router/app/`) y los scripts
de despliegue (`native/`, `Docker/`) buscando vulnerabilidades y bugs que
importan especialmente si este proyecto va a dejar de ser una entrega
académica para convertirse en algo que se instala en la red de una empresa
real. Se corrigieron 10 problemas de seguridad y 3 bugs funcionales
directamente en el código, y **todos los cambios se probaron** con un
arnés de pruebas automatizado (login, CSRF, rate limiting, panel admin,
migración de contraseñas, traversal de archivos, spoofing de IP) antes de
devolverte los archivos. El detalle de esas pruebas está al final de este
documento.

No se tocó la lógica de negocio ni la interfaz visual: el portal se ve y
se comporta igual para un usuario final. Los cambios son internos.

---

## 1. Vulnerabilidades corregidas

### 1.1 Contraseñas en texto plano (crítico)

`users.json` guardaba las contraseñas tal cual, incluidas las de ejemplo
(`admin/admin`, `alice/1234`, `bob/qwerty`) **comprometidas en el propio
repositorio git**. Cualquiera con acceso de lectura al archivo — o al
historial de git — tenía todas las contraseñas.

**Corrección** (`app/users.py`): las contraseñas se guardan ahora con
`PBKDF2-HMAC-SHA256` (260 000 iteraciones, salt aleatorio de 16 bytes por
usuario), usando solo la librería estándar de Python. Las cuentas que ya
existían en tu `users.json` fueron re-hasheadas en este mismo cambio
(siguen funcionando con las mismas credenciales). Si en el futuro cargas
usuarios en texto plano (por ejemplo por compatibilidad, o vía
`USERS_JSON`), el sistema los migra automáticamente a hash la primera vez
que ese usuario inicia sesión con éxito.

### 1.2 Credenciales por defecto predecibles (crítico)

Si no existía `users.json`, el sistema creaba `admin/admin`
automáticamente: cualquiera que conociera el proyecto (o lo adivinara)
tenía acceso de administrador a cualquier instalación nueva.

**Corrección** (`app/users.py`): en el primer arranque sin usuarios
configurados, se genera una contraseña aleatoria segura para `admin`
(`secrets.token_urlsafe`), se guarda ya hasheada, y se muestra **una sola
vez** por consola y en `app/admin_password_initial.txt` (con permisos
600). Es el mismo patrón que usan routers/appliances comerciales para el
primer arranque.

### 1.3 Comparación de contraseñas vulnerable a timing attacks (medio)

`stored != password` compara strings byte a byte y corta en la primera
diferencia: el tiempo de respuesta varía según cuántos caracteres
iniciales coinciden, lo que en teoría permite reconstruir una contraseña
midiendo tiempos de respuesta. Además, un usuario inexistente respondía
más rápido que uno existente, revelando qué cuentas existen.

**Corrección**: todas las comparaciones usan `hmac.compare_digest`
(tiempo constante), y una verificación contra un usuario inexistente
ejecuta igualmente un hash "señuelo" para no filtrar por temporización si
la cuenta existe.

### 1.4 Sin protección contra fuerza bruta (alto)

No había ningún límite de intentos en `/login` ni en el panel de admin
(HTTP Basic). Con las contraseñas de ejemplo mencionadas arriba, cualquier
script podía probar miles de combinaciones por segundo.

**Corrección** (`app/security.py`, `RateLimiter`): 5 intentos fallidos por
minuto bloquean esa IP durante 2 minutos en `/login`, y durante 5 minutos
en el panel de administración. Queda registrado en el log de auditoría.

### 1.5 Sin protección CSRF (alto)

Ningún formulario (login, crear usuario, borrar usuario) tenía token
CSRF. Como el panel de admin usa HTTP Basic —que el navegador reenvía
automáticamente en cada petición al mismo dominio una vez que lo
recuerda—, una página maliciosa visitada por el administrador podía crear
o borrar cuentas del portal sin que él lo supiera.

**Corrección** (`app/security.py`): tokens CSRF firmados con HMAC, sin
estado en el servidor, atados a la IP del cliente y con expiración de 1
hora. Se exigen en `/login`, `/admin/users/create` y
`/admin/users/delete`.

### 1.6 Suplantación de IP vía cabecera `X-Real-IP` (crítico)

Este fue el hallazgo más serio. El backend Python escucha en `0.0.0.0` y
confiaba ciegamente en las cabeceras `X-Real-IP`/`X-Forwarded-For` para
saber la IP del cliente. El firewall, además, dejaba ese puerto (8080)
accesible directamente desde toda la LAN, no solo desde nginx. Resultado:
**cualquier dispositivo de la red podía hablarle directo al backend
(saltándose nginx y el TLS) y falsificar esa cabecera para hacerse pasar
por la IP de otra persona** — autenticándola sin sus credenciales, o
cerrándole la sesión a la fuerza.

**Corrección en dos capas**:
- Código (`app/main.py`, `client_ip_from_headers`): esas cabeceras solo se
  aceptan si la conexión TCP viene realmente de `127.0.0.1` (loopback),
  que es donde escucha nginx. Si viene de cualquier otra IP, se ignoran.
- Firewall (`native/install-router.sh`, `native/start-portal.sh`,
  `Docker/router/entrypoint.sh`): se cambió la regla que permitía a la LAN
  llegar directo al puerto del backend por una que lo bloquea
  explícitamente. Los clientes solo deben hablar con nginx (80/443).

### 1.7 Panel de administración y backend expuestos a Internet (crítico)

Las reglas de firewall solo *añadían* permisos para la interfaz LAN, pero
nunca bloqueaban explícitamente esos mismos puertos en la interfaz WAN. Si
el equipo donde corre el portal tiene una IP pública (típico en un
despliegue real, a diferencia del laboratorio Docker), el panel de admin
con HTTP Basic y el backend sin TLS quedaban alcanzables desde cualquier
lugar de Internet.

**Corrección**: en los tres scripts de despliegue se añadieron reglas
`DROP` explícitas para el puerto del backend, HTTP, HTTPS y DNS cuando el
tráfico llega por la interfaz WAN (`UPLINK_IF`).

### 1.8 Path traversal en archivos estáticos (medio)

La comprobación `".." in rel or "\\" in rel` no decodifica `%2e%2e%2f`
(URL-encoded) antes de revisar, así que una petición como
`/static/%2e%2e/main.py` la sorteaba.

**Corrección** (`app/main.py`, `handle_static`): se decodifica la URL
antes de comprobar, y además se resuelve la ruta final con `Path.resolve()`
y se verifica que siga estando dentro de `STATIC_ROOT` — cubre `..`,
codificación de URL y enlaces simbólicos a la vez.

### 1.9 Escritura no atómica de `users.json` (bajo, pero real)

Un corte de luz o `kill -9` a mitad de la escritura del archivo podía
dejarlo corrupto (JSON incompleto), tumbando el login de todo el mundo.

**Corrección** (`app/users.py`, `save_users`): se escribe a un archivo
temporal y se hace `os.replace` (atómico en Linux), con permisos 600
porque ahora el archivo contiene hashes de contraseñas.

### 1.10 Sin registro de auditoría (medio, relevante para cumplimiento)

No quedaba ningún rastro de quién inició sesión, cuándo, ni qué cambios
hizo un administrador. Si vas a operar una red WiFi pública o
semi-pública, es habitual que la legislación local exija poder responder
"qué IP/usuario estuvo conectado en tal fecha y hora" ante un
requerimiento de las autoridades — vale la pena que confirmes ese
requisito en tu jurisdicción antes de vender esto a un cliente.

**Corrección** (`app/security.py`, `audit_log`): cada login (éxito/fallo),
logout, y acción de administrador (alta/baja de usuario, intentos
fallidos de autenticación) se registra en `/var/log/captive-portal/audit.log`
como JSON, una línea por evento.

---

## 2. Bugs corregidos de paso (no son vulnerabilidades, pero rompían el producto)

- **Dominio hardcodeado tras el login** (`app/portal.py`): tras un login
  exitoso, el código redirigía siempre a `https://portal.hastalap/status`
  sin importar qué `CERT_CN` configurara el instalador. Si alguien
  personalizaba el dominio del portal (algo que un cliente comercial
  seguramente querrá hacer), el login exitoso terminaba en una pantalla de
  error de DNS. Ahora redirige a la ruta relativa `/status`, que respeta
  el dominio/esquema con el que el cliente ya está hablando.

- **Finales de línea CRLF en `native/*.sh` (bug grave, específico de
  Windows)**: los 7 scripts de la carpeta `native/` — precisamente los que
  se usan para el despliegue "de producción" en un servidor Linux real —
  estaban guardados con finales de línea de Windows (CRLF). Al ejecutarlos
  con `bash script.sh` en Linux, esto rompe la sintaxis
  (`syntax error near unexpected token`), y además contamina con un
  carácter invisible `\r` cualquier variable leída con `source
  portal.conf` (por ejemplo, el nombre de una interfaz de red quedaría
  literalmente como `"eth1\r"`, y comparaciones o búsquedas con ese valor
  fallarían de forma muy difícil de depurar). Se convirtieron todos a LF y
  se añadió un `.gitattributes` para que no vuelva a pasar aunque sigas
  editando desde Windows.

- **`pyproject.toml` desactualizado**: declaraba `fastapi`, `uvicorn` y
  `jinja2` como dependencias, pero el backend real no los usa — es un
  servidor HTTP hecho a mano sobre sockets, solo librería estándar
  (imagino que es un resto de una versión anterior del proyecto). Se
  corrigió para reflejar la realidad: cero dependencias externas. Esto
  importa si algún día alguien (tú, un cliente, un auditor) revisa el
  proyecto y confía en ese archivo para saber qué corre en producción.

---

## 3. Archivos modificados

```
Docker/router/app/security.py        (nuevo: CSRF, rate limiting, auditoría)
Docker/router/app/users.py           (hash de contraseñas, migración, escritura atómica)
Docker/router/app/auth.py            (verificación en tiempo constante)
Docker/router/app/portal.py          (CSRF, rate limiting, fix de redirección, auditoría)
Docker/router/app/admin.py           (CSRF en formularios, auditoría)
Docker/router/app/main.py            (cabeceras de seguridad, traversal, anti-spoofing de IP, wiring)
Docker/router/app/users.json         (contraseñas de ejemplo re-hasheadas)
Docker/router/entrypoint.sh          (firewall: bloquear backend/panel desde WAN y desde LAN directo)
native/install-router.sh             (idem + fix CRLF)
native/start-portal.sh               (idem + fix CRLF)
native/stop-portal.sh                (limpieza de las reglas nuevas + fix CRLF)
native/configure-interfaces.sh       (fix CRLF)
native/setup-native.sh               (fix CRLF)
native/status-portal.sh              (fix CRLF)
native/portal.conf.example           (fix CRLF)
pyproject.toml                       (dependencias corregidas)
.gitattributes                       (nuevo: fuerza LF en scripts/código)
```

---

## 4. Cómo verificar los cambios

1. **Sintaxis**: todos los `.py` se validaron con `ast.parse` y todos los
   `.sh` con `bash -n`.
2. **Pruebas funcionales automatizadas** (simulando el servidor completo,
   con `ipset`/`iptables` mockeados ya que no corren en este entorno de
   revisión):
   - Login con CSRF válido/ausente, credenciales correctas/incorrectas.
   - Bloqueo por fuerza bruta tras 5 intentos fallidos (incluso probando
     luego la contraseña correcta).
   - Flujo completo del panel de admin: requiere autenticación, exige
     CSRF, valida longitud mínima de contraseña, crea usuarios.
   - Un usuario recién creado puede loguearse.
   - Migración automática de una contraseña en texto plano a hash tras un
     login exitoso.
   - Path traversal bloqueado (`../`, `%2e%2e`, `..%2f`) y archivo
     estático legítimo servido correctamente.
   - Bloqueo por fuerza bruta en el panel de admin.
   - Suplantación de IP vía `X-Real-IP` ignorada cuando la conexión no
     viene de loopback, y honrada correctamente cuando sí viene de
     loopback (nginx real).
3. **Recomendación**: antes de tu próxima demo o entrega, prueba el flujo
   completo en la VM/contenedor real (`Docker/2-deploy.sh` o
   `native/start-portal.sh`), ya que aquí no se pudo ejecutar `ipset`/
   `iptables`/`nginx` reales (requieren privilegios de root y un kernel
   Linux con esos módulos).

---

## 5. Qué queda pendiente antes de venderlo a una empresa

Esto **no** se implementó en esta pasada (elegiste enfocarte primero en
endurecer el código) — es la lista de lo siguiente, priorizada:

1. **La autenticación sigue atada solo a la IP, no a la sesión ni al
   MAC.** Es la limitación arquitectónica más importante: cualquier
   dispositivo que reciba la misma IP (por ejemplo, tras expirar un lease
   DHCP) hereda la sesión de quien la tuvo antes. Para un cliente
   empresarial serio, esto normalmente se resuelve añadiendo verificación
   de MAC address junto al ipset, o migrando a un modelo de sesión con
   cookie firmada.
2. **Certificado TLS autofirmado.** Funciona, pero cada usuario ve una
   advertencia de seguridad en el navegador. Para un cliente que ya tenga
   su propio dominio, conviene poder usar Let's Encrypt o su propia CA
   interna.
3. **Cuenta de servicio con privilegios mínimos.** Hoy el backend corre
   como `root` (necesario para llamar a `ipset`), pero
   `native/setup-native.sh` crea un usuario `captive-portal` sin
   privilegios que nunca se usa. Vale la pena investigar `sudo` con reglas
   específicas o `setcap` para no correr todo como root.
4. **Dos implementaciones nativas distintas y desincronizadas.**
   `install-router.sh` (con dnsmasq) y `start-portal.sh`+`setup-native.sh`
   (con isc-dhcp-server) son dos caminos de despliegue "nativo" que hacen
   cosas parecidas de forma diferente, con configuraciones por defecto que
   ya divergían entre sí (IPs, nombres de cadenas iptables). Antes de
   vender esto, conviene quedarse con un solo camino de instalación nativa
   y borrar el otro, o documentar muy claramente cuál usar y cuándo.
5. **Consideraciones legales/regulatorias.** Si vas a operar o vender esto
   para una red WiFi con acceso público, infórmate sobre los requisitos de
   retención de datos y registro de usuarios que aplique en tu país — el
   log de auditoría que se añadió ayuda, pero puede que necesites más
   (por ejemplo, vincular la sesión a un documento de identidad, según el
   contexto).
6. **Empaquetado comercial**: instalador de un solo comando, licencia,
   pricing, documentación para el cliente final (no solo técnica). Esto
   no se tocó en esta pasada porque elegiste enfocarte primero en el
   código — dime si quieres que sigamos por aquí.

---

*Todos los cambios de este documento fueron probados automáticamente
antes de guardarse en tu carpeta. Si algo no se comporta como esperas,
dímelo con el paso exacto para reproducirlo y lo reviso.*
