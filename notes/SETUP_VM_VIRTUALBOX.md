# Configuración del Portal Cautivo en VirtualBox

## Tabla de contenidos
1. [Requisitos](#requisitos)
2. [Arquitectura](#arquitectura)
3. [Paso 1: Preparar VirtualBox](#paso-1-preparar-virtualbox)
4. [Paso 2: Crear VM Router](#paso-2-crear-vm-router)
5. [Paso 3: Crear VM Cliente](#paso-3-crear-vm-cliente)
6. [Paso 4: Configurar red en VMs](#paso-4-configurar-red-en-vms)
7. [Paso 5: Instalar el Portal](#paso-5-instalar-el-portal)
8. [Paso 6: Pruebas](#paso-6-pruebas)
9. [Solución de problemas](#solución-de-problemas)

---

## Requisitos

### Hardware mínimo:
- **CPU**: 4 núcleos
- **RAM**: 8 GB (6 GB router + 4 GB cliente con overlapping)
- **Almacenamiento**: 60 GB disponibles (25 GB router + 20 GB cliente)
- **Conexión a Internet**: Para descargar ISOs y paquetes

### Software a descargar:
1. **VirtualBox 7.0+**
   - Descarga: https://www.virtualbox.org/wiki/Downloads
   - Instala la versión para Windows

2. **Ubuntu Desktop 22.04 LTS** (2 copias)
   - Descarga: https://ubuntu.com/download/desktop
   - Archivo ISO: `ubuntu-22.04.x-desktop-amd64.iso`
   - Tamaño: ~3.5 GB

---

## Arquitectura

### ¿Cómo funciona el Portal Cautivo?

```
┌─────────────────────────────────────────────────────────────────┐
│  CLIENTE SE CONECTA A LA RED                                    │
│                                                                 │
│  1. Cliente obtiene IP via DHCP del router                      │
│     → IP: 10.200.0.1xx                                         │
│     → Gateway: 10.200.0.254 (router)                           │
│     → DNS: 10.200.0.254 (router)                               │
│                                                                 │
│  2. Cliente abre navegador → http://google.com                  │
│     → DNS query: "google.com" → router                         │
│     → Router responde: "google.com = IP real"                  │
│     → HTTP request → router intercepta (iptables)              │
│     → Redirige a https://portal.hastalap/login                 │
│                                                                 │
│  3. Cliente intenta HTTPS → https://google.com                  │
│     → iptables detecta: IP no autenticada                      │
│     → REJECT con tcp-reset                                     │
│     → Navegador muestra "Sin conexión"                         │
│                                                                 │
│  4. Cliente hace login en portal                                │
│     → IP añadida a ipset "authed"                              │
│     → iptables permite tráfico                                 │
│     → Acceso completo a Internet ✓                             │
└─────────────────────────────────────────────────────────────────┘
```

### Diagrama de Red

```
┌─────────────────────────────────────────────────────────┐
│                    TU PC (Windows)                      │
│                                                         │
│  ┌─────────────────────────────┐                       │
│  │   VM1: Portal-Router        │                       │
│  │   (Ubuntu Desktop 22.04)    │                       │
│  │                             │                       │
│  │   Interfaces:               │                       │
│  │   • eth0: NAT (Internet)    │                       │
│  │   • eth1: Host-Only (LAN)   │                       │
│  │           10.200.0.254      │                       │
│  │                             │                       │
│  │   Servicios:                │                       │
│  │   • iptables / ipset        │                       │
│  │   • dnsmasq (DNS + DHCP)    │                       │
│  │   • nginx (HTTPS)           │                       │
│  │   • Python backend (8080)   │                       │
│  └──────────┬──────────────────┘                       │
│             │                                          │
│             │ Red Host-Only (10.200.0.0/24)            │
│             │ DHCP: 10.200.0.100 - 10.200.0.200        │
│             │                                          │
│  ┌──────────▼──────────────────┐                       │
│  │   VM2: Cliente-Test         │                       │
│  │   (Ubuntu Desktop 22.04)    │                       │
│  │                             │                       │
│  │   Interfaz:                 │                       │
│  │   • eth0: Host-Only (LAN)   │                       │
│  │           10.200.0.1xx      │                       │
│  │           (DHCP automático) │                       │
│  │                             │                       │
│  │   Sin configuración manual  │                       │
│  │   necesaria ✓               │                       │
│  └─────────────────────────────┘                       │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

---

## Paso 1: Preparar VirtualBox

### 1.1 Instalar VirtualBox

1. Descarga VirtualBox desde: https://www.virtualbox.org/wiki/Downloads
2. Ejecuta el instalador
3. Acepta todas las opciones por defecto
4. Reinicia tu PC si es necesario

### 1.2 Crear red Host-Only

1. **Abre VirtualBox**
2. **Menú superior**: `File` → `Preferences`
3. **Panel izquierdo**: `Network`
4. **Pestaña**: `Host-only Networks`
5. **Botón**: Haz clic en el ícono `+` (agregar nueva red)

**Configuración de la red**:
- **Name**: `vboxnet0` (dejar por defecto)
- **IPv4 Address**: `10.200.0.1`
- **IPv4 Netmask**: `255.255.255.0`
- **IPv6 Address**: (dejar en blanco)
- **Enable DHCP Server**: **DESACTIVADO** ← Importante

6. **Click OK** para guardar

---

## Paso 2: Crear VM Router

### 2.1 Nueva máquina virtual

1. **VirtualBox**: Menú `Machine` → `New` (o Ctrl+N)

2. **Configuración básica**:
   - **Name**: `Portal-Router`
   - **Machine Folder**: (dejar por defecto)
   - **ISO Image**: Selecciona `ubuntu-22.04.x-desktop-amd64.iso`
   - **Type**: Linux
   - **Version**: Ubuntu (64-bit)

3. **Hardware**:
   - **Memory**: `4096 MB` (4 GB)
   - **Processors**: `2` (o más si disponible)
   - **Enable EFI**: Desactivado

4. **Hard Disk**:
   - **Create a Virtual Hard Disk Now**: Seleccionado
   - **File Size**: `25 GB`
   - **Hard Disk File Type**: `VDI` (por defecto)
   - **Storage on Physical Hard Disk**: `Dynamically allocated`

5. **Click Finish**

### 2.2 Configurar interfaces de red

1. **Selecciona la VM** `Portal-Router` en la lista
2. **Click derecho** → `Settings` (o botón Settings)
3. **Sección**: `Network`

**Adapter 1**:
- **Attached to**: `NAT`
- (Resto de opciones por defecto)

**Adapter 2**:
- **Attached to**: `Host-only Adapter`
- **Name**: `vboxnet0`

4. **Click OK**

### 2.3 Instalar Ubuntu

1. **Inicia la VM** (doble clic en `Portal-Router`)
2. **BIOS/UEFI**: Se abre automáticamente desde el ISO
3. **Pantalla de instalación**: Selecciona tu idioma (Inglés recomendado para evitar caracteres especiales)
4. **Keyboard layout**: Inglés (US) o tu preferencia

5. **Instalación interactiva**:
   - **Updates and other software**: Selecciona `Normal installation`
   - **Installation type**: `Erase disk and install Ubuntu`
   - **Timezone**: Tu zona horaria
   - **Computer name**: `portal-router`
   - **Username**: `admin`
   - **Password**: `admin123`
   - **Checkbox**: Desactiva "Log in automatically"

6. **Espera a que termine la instalación** (~10-15 minutos)
7. **Reinicia cuando pida**

---

## Paso 3: Crear VM Cliente

### 3.1 Nueva máquina virtual

1. **VirtualBox**: Menú `Machine` → `New`

2. **Configuración básica**:
   - **Name**: `Cliente-Test`
   - **ISO Image**: `ubuntu-22.04.x-desktop-amd64.iso`
   - **Type**: Linux
   - **Version**: Ubuntu (64-bit)

3. **Hardware**:
   - **Memory**: `4096 MB` (4 GB)
   - **Processors**: `2`

4. **Hard Disk**:
   - **File Size**: `20 GB`
   - **Storage**: `Dynamically allocated`

5. **Click Finish**

### 3.2 Configurar interfaz de red

1. **Selecciona** `Cliente-Test`
2. **Click derecho** → `Settings`
3. **Sección**: `Network`

**Adapter 1**:
- **Attached to**: `Host-only Adapter`
- **Name**: `vboxnet0`

**Adapter 2-4**: Desactivadas (deja como están)

4. **Click OK**

### 3.3 Instalar Ubuntu

1. **Inicia la VM** (igual que el router)
2. **Instalación**: Mismas opciones que el router, pero:
   - **Computer name**: `cliente-test`
   - **Username**: `usuario`
   - **Password**: `usuario123`

---

## Paso 4: Configurar red en VMs

### 4.1 Configurar VM Router

**En la VM Router (terminal)**:

```bash
# Abre una terminal (Ctrl+Alt+T)
sudo nano /etc/netplan/00-installer-config.yaml
```

**Reemplaza el contenido con**:

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: no
      addresses:
        - 10.200.0.254/24
```

> **Nota sobre interfaces**: 
> - `enp0s3` y `enp0s8` son nombres modernos de Ubuntu (en lugar de eth0/eth1)
> - El router NO necesita gateway en enp0s8, él ES el gateway de esa red

**Guarda** (Ctrl+O, Enter, Ctrl+X)

**Aplica los cambios**:

```bash
sudo netplan apply
```

**Verifica**:

```bash
ip addr show
```

Deberías ver:
- `enp0s3` con una IP 10.0.2.x (NAT para acceso a Internet)
- `enp0s8` con 10.200.0.254/24 (LAN del portal)

### 4.2 VM Cliente: Configuración DHCP (Automática)

**¿Necesita configuración manual?**

Depende de cómo instalaste Ubuntu:

#### Opción A: Si DHCP ya está habilitado (recomendado) ✅

Durante la instalación de Ubuntu, si seleccionaste "Automatic (DHCP)" para la red:
- ✅ **No necesitas hacer nada**
- La interfaz eth0 ya está configurada con `dhcp4: yes`
- Simplemente arranca la VM y listo
- El router DHCP entrega automáticamente:
  - **IP**: 10.200.0.100-200
  - **Gateway**: 10.200.0.254
  - **DNS**: 10.200.0.254

#### Opción B: Si la instalación no configuró DHCP ⚙️

Si después de instalar Ubuntu no tienes red automática:

```bash
# Abre una terminal (Ctrl+Alt+T)
sudo nano /etc/netplan/00-installer-config.yaml
```

**Reemplaza el contenido con**:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: yes
```

**Guarda y aplica**:

```bash
sudo netplan apply
```

### ¿Por qué es necesario netplan si hay DHCP?

Buena pregunta. Linux no "reconoce automáticamente" una interfaz sin decirle explícitamente que:
1. La interfaz existe (eth0)
2. Debe obtener IP via DHCP (`dhcp4: yes`)

**Sin el archivo netplan**: 
- La interfaz estaría presente pero **sin activar**
- No solicitaría IP al servidor DHCP

**Con `dhcp4: yes`**: 
- Linux activa la interfaz
- Solicita automáticamente IP al servidor DHCP del router
- Todo funciona sin más intervención

### Verificación de Conectividad

Una vez que Ubuntu arranca (con DHCP activado):

```bash
# Ver la IP asignada automáticamente
ip addr show eth0
# Debería mostrar: inet 10.200.0.1xx/24

# Ver gateway
ip route | grep default
# Debería mostrar: default via 10.200.0.254

# Ver DNS
cat /etc/resolv.conf
# Debería mostrar: nameserver 10.200.0.254

# Confirmar conectividad
ping 10.200.0.254  # Debería responder
```

> **Si instalaste sin DHCP**: simplemente edita netplan como en la Opción B y ya funciona automáticamente.

---

## Paso 5: Instalar el Portal

### 5.1 En VM Router

**Clonar el repositorio**:

```bash
sudo apt-get update
sudo apt-get install -y git
cd ~
git clone https://github.com/JuanCMath/Captive-Portal.git
cd Captive-Portal
```

**Ejecutar el script de instalación**:

```bash
# El script está en la carpeta 'native'
sudo bash native/install-router.sh
```

Este script:
- Instala todas las dependencias (iptables, dnsmasq, nginx, python3, etc.)
- Configura iptables e ipset
- Arranca los servicios necesarios
- Crea un servicio systemd para que inicie automáticamente

**Verificar que todo funciona**:

```bash
# Ver estado del servicio
sudo systemctl status portal-cautivo

# Ver logs en tiempo real
sudo journalctl -u portal-cautivo -f

# Verificar puertos abiertos
sudo ss -tlnp | grep -E "80|443|8080|53"
```

**Esperado**:
```
LISTEN ... 0.0.0.0:80   ... nginx
LISTEN ... 0.0.0.0:443  ... nginx
LISTEN ... 0.0.0.0:8080 ... python3
LISTEN ... 0.0.0.0:53   ... dnsmasq
```

---

## Paso 6: Pruebas

### 6.1 Test básico desde VM Cliente

**En la VM Cliente, abre una terminal**:

```bash
# Verificar conectividad
ping 10.200.0.254

# Resolver DNS
nslookup example.com  # Debería resolver a 10.200.0.254

# Acceder al portal
curl -k https://portal.hastalap
```

### 6.2 Test en navegador

**En VM Cliente, abre Firefox**:

1. **Barra de direcciones**: `http://example.com`
2. **Resultado esperado**: Se redirige a `https://portal.hastalap/login`
3. **Iniciar sesión**:
   - Usuario: `admin`
   - Contraseña: `admin`
4. **Después del login**: Acceso a Internet disponible

### 6.3 Test de HTTPS bloqueado (antes de autenticar)

**En terminal de VM Cliente**:

```bash
# Sin autenticar, HTTPS debe estar bloqueado
curl -k --connect-timeout 5 https://example.com

# Esperado: "Failed to connect" o timeout
```

**Después de autenticar**:

```bash
# Con autenticación, HTTPS debe funcionar
curl -k https://example.com

# Esperado: Contenido HTML de example.com
```

---

## Solución de problemas

### Problema: Cliente no obtiene IP

**Síntomas**: `ip addr show` solo muestra `lo`

**Solución**:

```bash
# En VM Cliente
sudo netplan apply
sudo dhclient eth0
ip addr show
```

### Problema: No hay conectividad al router

**Síntomas**: `ping 10.200.0.254` no responde

**Solución**:

```bash
# En VM Router, verificar firewall
sudo ufw disable  # O permitir tráfico específico

# Verificar interfaz
ip link show enp0s8  # Debe estar "UP"
```

### Problema: Portal no carga

**Síntomas**: Conexión rechazada en navegador

**Solución**:

```bash
# En VM Router, ver logs
sudo journalctl -u portal-cautivo -n 50

# Verificar puertos
sudo ss -tlnp | grep 8080

# Reiniciar servicio
sudo systemctl restart portal-cautivo
```

### Problema: DNS no resuelve

**Síntomas**: `nslookup` tarda mucho o no resuelve

**Solución**:

```bash
# En VM Router, verificar dnsmasq
sudo systemctl status dnsmasq
sudo systemctl restart dnsmasq

# Ver logs de dnsmasq
tail -f /var/log/syslog | grep dnsmasq
```

### Problema: iptables no bloquea HTTPS

**Síntomas**: HTTPS funciona sin autenticar

**Solución**:

```bash
# En VM Router, verificar reglas
sudo iptables -L FORWARD -v -n
sudo ipset list authed

# Ver si hay tráfico siendo filtrado
sudo iptables -L FORWARD -v | grep REJECT
```

---

## Monitoreo en tiempo real

### Desde VM Router

**Terminal 1 - Logs del portal**:

```bash
sudo journalctl -u portal-cautivo -f
```

**Terminal 2 - Tráfico de red**:

```bash
sudo iftop  # (instalar si no existe: sudo apt-get install -y iftop)
```

**Terminal 3 - IPs autenticadas**:

```bash
watch 'sudo ipset list authed'
```

### Desde tu PC (si necesitas acceso SSH)

```bash
# Conectar a VM Router
ssh admin@<IP-NAT-de-VM-Router>

# Obtener IP NAT de la VM
# En VirtualBox, selecciona la VM y mira los detalles de red
```

---

## Resumen de IPs

| Componente | Interfaz | IP | Asignación |
|------------|----------|-----|------------|
| **Router (eth0)** | NAT | 10.0.2.x | DHCP (VirtualBox) |
| **Router (eth1)** | Host-Only | 10.200.0.254 | Estática |
| **Cliente (eth0)** | Host-Only | 10.200.0.100-200 | **DHCP (Router)** |
| **Red Host-Only** | Gateway | 10.200.0.1 | VirtualBox |

### Servicios del Router

| Puerto | Servicio | Función |
|--------|----------|---------|
| 53/udp | dnsmasq | DNS + DHCP |
| 80/tcp | nginx | HTTP → Redirige al login |
| 443/tcp | nginx | HTTPS Portal |
| 8080/tcp | Python | Backend del portal |

---

## Próximos pasos

Una vez que todo funcione:

1. **Pruebas de carga**: Agregar más VMs cliente
2. **Pruebas de seguridad**: Intentar bypassear el portal
3. **Optimización**: Ajustar timeouts, DNS, reglas de firewall
4. **Documentación**: Screenshots para reporte

---

**¡Listo! Ahora ejecuta el script `native/install-router.sh` en la VM Router y comienza las pruebas.**
