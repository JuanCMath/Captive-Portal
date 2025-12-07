# 🚀 Guía Completa: Ejecutar Portal Cautivo en Ubuntu Host

**Objetivo**: Ejecutar el Portal Cautivo en una PC Linux con Ubuntu para que otros dispositivos se conecten a ella.

> **⚡ NOTA**: Los scripts ya automatizar casi todo. Esta guía principalmente te indica qué hacer.

---

## 📋 Requisitos Previos

### Hardware
- **PC con Ubuntu Server o Desktop** (18.04+)
- **Mínimo 2 interfaces de red**:
  - **WAN (eth0)**: Conectada a internet
  - **LAN (eth1)**: Para que se conecten los clientes

### Software
- Ubuntu/Debian instalado
- Acceso a `sudo` (usuario administrador)
- Conexión a internet para descargar dependencias

### Red
- La interfaz LAN debe estar conectada a un switch, router, o directamente a clientes
- Los clientes deben poder comunicarse con la interfaz LAN del servidor

---

## 🎯 Pasos Rápidos (TL;DR)

Si solo quieres empezar:

```bash
# 1. Descargar proyecto
cd ~/Proyectos/Captive-Portal

# 2. Instalación automática (instala todas las dependencias)
sudo bash native/install-router.sh

# ✅ Listo. El portal está corriendo

# Ver estado
sudo bash native/status-portal.sh
```

**¡Ese es todo el proceso!** El script `install-router.sh` hace CASI TODO automáticamente. Ver detalles abajo.

---

## 📥 Paso 1: Descargar el Proyecto a Ubuntu

Elige uno de estos métodos:

### Opción A: Clonar desde Git
```bash
cd ~
git clone https://github.com/tu-usuario/Captive-Portal.git
cd Captive-Portal
```

### Opción B: Transferir desde Windows
```bash
# Desde tu PC Windows (PowerShell):
scp -r "C:\Users\Juank\Proyectos\Captive-Portal" usuario@ubuntu-ip:~/Proyectos/

# O usar WinSCP, FileZilla, etc.
```

**Verifica que el proyecto está completo:**
```bash
cd ~/Proyectos/Captive-Portal
ls -la native/
# Debe mostrar: install-router.sh, setup-native.sh, start-portal.sh, etc.
```

---

## 🛠️ Paso 2: Ejecutar Script de Instalación COMPLETO

El script **`install-router.sh`** hace TODO automáticamente:

```bash
cd ~/Proyectos/Captive-Portal
sudo bash native/install-router.sh
```

### ¿Qué hace automáticamente?

✅ **Instalación de dependencias:**
- `iptables`, `ipset` (firewall)
- `dnsmasq` (DNS)
- `nginx` (proxy HTTPS)
- `python3` (backend)
- Y más...

✅ **Configuración automática:**
- Habilita IP forwarding
- Configura NAT
- Crea reglas de firewall
- Genera certificado TLS autofirmado
- Crea estructura de directorios

✅ **Inicia automáticamente:**
- Backend Python
- nginx
- dnsmasq
- iptables rules

### Output esperado:
```
[✓] Verificando conectividad...
[✓] Actualizando repositorios...
[✓] Instalando dependencias...
[✓] Configurando sistema...
[✓] Iniciando servicios...
[✓] ¡Portal cautivo instalado y activo!
```

---

## ⚙️ Paso 3: (Opcional) Configuración Manual de Interfaces

Si quieres personalizar interfaces, usa el script interactivo:

```bash
sudo bash native/configure-interfaces.sh
```

Este script:
1. Detecta interfaces disponibles
2. Te pregunta cuál es WAN y cuál es LAN
3. Configura IP automáticamente
4. Actualiza `/etc/captive-portal/portal.conf`

**O si prefieres hacerlo manualmente:**

```bash
# Ver interfaces disponibles
ip link show

# Asignar IP a LAN (ejemplo)
sudo ip addr add 192.168.100.1/24 dev eth1
sudo ip link set eth1 up

# Verificar
ip addr show eth1
```

---

## 🔐 Paso 4: Editar Usuarios (Opcional)

Por defecto, los usuarios son `admin:admin`. Para cambiar:

```bash
sudo nano /opt/captive-portal/app/users.json
```

**Formato:**
```json
{
  "admin": {
    "password": "tu-password-aqui",
    "role": "admin"
  },
  "user1": {
    "password": "pass123",
    "role": "user"
  }
}
```

---

## 🚀 Paso 5: Verificar Estado

Ver que todo está corriendo:

```bash
sudo bash native/status-portal.sh
```

**Output esperado:**
```
=== ESTADO DEL PORTAL CAUTIVO ===

SERVICIOS:
  Backend Python: activo (PID: 1234)
  nginx: activo
  dnsmasq: activo (PID: 5678)

CONFIGURACIÓN:
  WAN: eth0
  LAN: eth1 (192.168.100.1)
  Portal: https://portal.hastalap
  Timeout: 3600s

IPS AUTENTICADAS:
  Total: 0 IP(s)

REGLAS IPTABLES:
  Cadena CP_REDIRECT: configurada
  IP forwarding: habilitado
```

---

## 🧪 Paso 6: PRUEBA FUNCIONAL

### Desde otra PC (Cliente)

**Requisitos:**
- Conectada a la misma red que eth1 (LAN del servidor)
- Configurada para obtener IP por DHCP o IP manual en rango 192.168.100.X

**Pasos:**

1. **Abre navegador en el cliente** y ve a cualquier sitio HTTP:
   ```
   http://google.com
   http://example.com
   http://example.net
   ```

2. **Serás redirigido automáticamente** a:
   ```
  https://portal.hastalap/login
   ```

3. **Ingresa credenciales por defecto:**
   ```
   Usuario: admin
   Contraseña: admin
   ```

4. **Si son correctas:**
   - Tu IP se añade al `ipset authed`
   - Ahora puedes navegar libremente

5. **Verificar en servidor que tu IP está autenticada:**
   ```bash
   sudo ipset list authed
   ```

### Para Logout

```bash
# En navegador cliente:
https://portal.hastalap/logout

# Tu IP se remueve del ipset y pierdes acceso
```

---

## 🛑 Detener el Portal (Cuando termines)

```bash
sudo bash native/stop-portal.sh
```

Este script limpia automáticamente:
- Detiene backend Python
- Detiene nginx y dnsmasq
- Remueve reglas de iptables
- Destruye el ipset

---

## 📊 Monitorear en Tiempo Real

### Ver IPs Autenticadas (actualización automática cada 2 segundos)

```bash
watch -n 2 'sudo ipset list authed'
```

### Ver Logs del Backend

```bash
# Últimas líneas
tail -f /var/log/captive-portal/backend.log

# Ver logs del sistema
sudo journalctl -u captive-portal -f 2>/dev/null || tail -f /var/log/syslog | grep captive
```

---

## 🐛 Solución de Problemas

### ❌ "Los clientes no son redirigidos al portal"

**Verificar IP forwarding:**
```bash
cat /proc/sys/net/ipv4/ip_forward

# Si es 0:
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

**Verificar reglas iptables:**
```bash
sudo iptables -t nat -L -n -v
sudo iptables -L -n -v
```

**Ver logs:**
```bash
tail -100 /var/log/captive-portal/backend.log
```

### ❌ "El cliente no obtiene IP"

```bash
# Verificar que LAN está UP
ip link show eth1

# Si no:
sudo ip link set eth1 up

# Asignar IP
sudo ip addr add 192.168.100.1/24 dev eth1
```

### ❌ "portal.hastalap no resuelve en cliente"

```bash
# Verificar dnsmasq
sudo systemctl status dnsmasq

# Reiniciar
sudo systemctl restart dnsmasq

# En cliente, probar DNS:
nslookup portal.hastalap 192.168.100.1
```

### ❌ "HTTPS muestra error de certificado"

**Esto es NORMAL**. El certificado es autofirmado. Soluciones:
- En navegador: Click en "Avanzado" → "Continuar de todas formas"
- Con curl: Agregar `-k` para ignorar certificado
  ```bash
  curl -k https://portal.hastalap/login
  ```

### ❌ "Backend Python no inicia"

```bash
# Ver si puerto está en uso
sudo netstat -tlnp | grep 8080

# Matar procesos existentes
sudo pkill -f "python3.*app.main"

# Reiniciar
sudo bash native/start-portal.sh
```

### ❌ "Nginx falla al iniciar"

```bash
# Ver error
sudo systemctl status nginx

# Ver logs detallados
sudo tail -20 /var/log/nginx/error.log

# Verificar sintaxis
sudo nginx -t

# Reiniciar
sudo systemctl restart nginx
```

---

## 📋 Checklist de Verificación Rápida

Antes de considerar que funciona, verifica esto:

```bash
# 1. Servicios corriendo
sudo bash native/status-portal.sh

# 2. IPs autenticadas
sudo ipset list authed

# 3. Reglas de firewall
sudo iptables -t nat -L -n | grep REDIRECT

# 4. IP forwarding habilitado
cat /proc/sys/net/ipv4/ip_forward  # Debe ser: 1

# 5. Archivo de configuración
cat /etc/captive-portal/portal.conf
```

---

## 📚 Archivos y Directorios Importantes

### Scripts de Control (en `~/Proyectos/Captive-Portal/native/`)

| Script | Función |
|--------|---------|
| `install-router.sh` | **INSTALACIÓN COMPLETA** - ejecuta TODO |
| `setup-native.sh` | Instalar dependencias (sin iniciar) |
| `start-portal.sh` | Iniciar portal |
| `stop-portal.sh` | Detener portal |
| `status-portal.sh` | Ver estado |
| `configure-interfaces.sh` | Configurar interfaces interactivamente |

### Configuración del Sistema (instalada en `/etc/`)

| Archivo | Función |
|---------|---------|
| `/etc/captive-portal/portal.conf` | **Configuración principal** - editar aquí si necesitas cambiar interfaces, IPs, puertos |
| `/etc/captive-portal/ssl/portal.key` | Clave privada TLS (autofirmada) |
| `/etc/captive-portal/ssl/portal.crt` | Certificado TLS (autofirmado) |

### Aplicación (instalada en `/opt/`)

| Archivo/Directorio | Función |
|---------|---------|
| `/opt/captive-portal/app/` | Código Python del backend |
| `/opt/captive-portal/app/main.py` | Punto de entrada del servidor Python |
| `/opt/captive-portal/app/users.json` | **Base de datos de usuarios** - editar para cambiar usuarios/contraseñas |
| `/opt/captive-portal/app/portal.py` | Lógica de portal (login, logout, etc.) |
| `/opt/captive-portal/app/auth.py` | Lógica de autenticación |

### Logs (en `/var/log/`)

| Archivo | Contenido |
|---------|---------|
| `/var/log/captive-portal/backend.log` | Logs del backend Python |
| `/var/log/captive-portal/dnsmasq.log` | Logs del DNS |
| `/var/log/nginx/error.log` | Errores de nginx |
| `/var/log/nginx/access.log` | Accesos a nginx |

---

## 📞 Comandos Rápidos de Referencia

```bash
# Ver estado general
sudo bash native/status-portal.sh

# Ver IPs autenticadas en tiempo real
watch -n 2 'sudo ipset list authed'

# Ver logs backend
tail -f /var/log/captive-portal/backend.log

# Reiniciar nginx
sudo systemctl restart nginx

# Reiniciar dnsmasq
sudo systemctl restart dnsmasq

# Parar todo
sudo bash native/stop-portal.sh

# Iniciar nuevamente
sudo bash native/start-portal.sh

# Editar config (WAN, LAN, puertos, etc.)
sudo nano /etc/captive-portal/portal.conf

# Editar usuarios (credenciales)
sudo nano /opt/captive-portal/app/users.json

# Resetear configuración de interfaces (interactivo)
sudo bash native/configure-interfaces.sh

# Ver reglas iptables activas
sudo iptables -L -n -v
sudo iptables -t nat -L -n -v

# Ver procesos de portal
ps aux | grep -E "python3|nginx|dnsmasq" | grep -v grep
```

---

## 🎯 Topología de Red

```
        Internet
            │
       [eth0 - WAN]
            │
    ┌───────┴────────┐
    │  Ubuntu Server │
    │  192.168.100.1 │  ← Tu PC Host (Portal)
    └───────┬────────┘
       [eth1 - LAN]
            │
    ┌───────┴────────┬──────────┐
    │ Switch/Hub     │          │
    │   (si aplica)  │          │
    └───────┬────────┘          │
            │                   │
        ┌───┴───┐          ┌────┴────┐
        │Client1│          │Client2  │
        │(PC)   │          │(Phone)  │
        │ ~.2   │          │ ~.3     │
        └───────┘          └─────────┘
```

---

## ✨ Próximos Pasos (Opcional/Avanzado)

- Configurar DHCP para asignar IPs automáticas a clientes
- Agregar más usuarios a `users.json`
- Personalizar páginas HTML del portal
- Usar certificado SSL válido (Let's Encrypt)
- Integrar base de datos (PostgreSQL, MySQL)
- Crear systemd service para autostart

---

**¡Listo! Tu Portal Cautivo debe estar funcionando en Ubuntu.** 🎉
