# Guía de Despliegue - Portal Cautivo

## Descripción General

El proyecto incluye dos scripts auxiliares para facilitar el despliegue del portal cautivo:

1. **`1-prepare.sh`** - Prepara el entorno construyendo las imágenes Docker
2. **`2-deploy.sh`** - Despliega los contenedores (router + 2 clientes)

Estos scripts orquestan todas las operaciones necesarias mediante llamadas a Docker y combinación de scripts existentes.

---

## Requisitos Previos

- **Docker Desktop** instalado y ejecutándose
- **Bash** (Linux, macOS, o WSL en Windows)
- Permiso para ejecutar comandos Docker (o estar en grupo `docker`)

### Verificar Docker

```bash
docker --version
docker ps  # Verificar que Docker está accesible
```

---

## Flujo de Despliegue

### Paso 1: Preparación del Entorno

#### Comando

```bash
cd Docker
chmod +x 1-prepare.sh 2-deploy.sh  # Hacer scripts ejecutables
./1-prepare.sh
```

#### Qué hace

1. **Verifica Dockerfiles** en ambos directorios
2. **Construye imagen del Router** con nombre `portal-router:latest`
   - Incluye: iptables, ipset, dnsmasq, nginx, Python3, noVNC
3. **Construye imagen del Cliente** con nombre `portal-client:latest`
   - Incluye: Chromium, noVNC, utilidades de red

#### Tiempo esperado

- Primera ejecución: 3-8 minutos (descarga de capas base)
- Ejecuciones posteriores: 30-60 segundos (reutiliza capas)

#### Output esperado

```
[INFO] Construyendo imagen 'portal-router:latest'...
[✓] Imagen del router construida exitosamente
[INFO] Construyendo imagen 'portal-client:latest'...
[✓] Imagen del cliente construida exitosamente

Próximo paso:
  Ejecuta el script 2 para iniciar los contenedores:
    ./2-deploy.sh
```

---

### Paso 2: Despliegue del Sistema

#### Comando

```bash
./2-deploy.sh
```

#### Qué hace

1. **Elimina contenedores antiguos** (si existen)
   - Contenedores: `router`, `client-1`, `client-2`
   - Permite redesplegamiento limpio

2. **Crea red Docker** aislada (`portal-lan`)
   - Tipo: bridge
   - Subred: `10.200.0.0/24`
   - Simula la LAN del portal

3. **Inicia Router** (contenedor principal)
   - IP en LAN: `10.200.0.254`
   - Ejecuta: iptables, ipset, dnsmasq, nginx, Python HTTP
   - Puerto noVNC local: **6091**

4. **Inicia Cliente 1**
   - IP en LAN: `10.200.0.11`
   - Puerto noVNC local: **6081**
   - Navegador preconfigurado

5. **Inicia Cliente 2**
   - IP en LAN: `10.200.0.12`
   - Puerto noVNC local: **6082**
   - Para pruebas de múltiples usuarios

6. **Muestra información de acceso**
   - URLs de noVNC para cada componente
   - Topología de red visual
   - Instrucciones de prueba

#### Tiempo esperado

- Inicio completo: 10-20 segundos

#### Output esperado

```
[✓] Docker disponible
[✓] Imagen encontrada: portal-router:latest
[✓] Imagen encontrada: portal-client:latest
[✓] Red Docker creada: portal-lan
[✓] Router iniciado exitosamente
[✓] Cliente 1 iniciado
[✓] Cliente 2 iniciado

═══════════════════════════════════════════════════════════
INFORMACIÓN DE ACCESO - noVNC (Interfaz Gráfica)
═══════════════════════════════════════════════════════════

Router (Portal Cautivo):
  URL: http://localhost:6091/vnc.html
  ...

Cliente 1:
  URL: http://localhost:6081/vnc.html
  ...

Cliente 2:
  URL: http://localhost:6082/vnc.html
  ...
```

---

## Acceso a los Componentes

### Interfaz Gráfica (noVNC)

Abre en tu navegador web cualquiera de estas URLs:

| Componente | URL Local | Descripción |
|------------|-----------|-------------|
| **Router** | http://localhost:6091/vnc.html | Portal cautivo, firewall, DNS |
| **Cliente 1** | http://localhost:6081/vnc.html | Usuario de prueba 1 |
| **Cliente 2** | http://localhost:6082/vnc.html | Usuario de prueba 2 |

### Flujo de Prueba Recomendado

1. **Abre Cliente 1** en http://localhost:6081/vnc.html
2. **Dentro del cliente**, se abrirá Chromium automáticamente
3. **Intenta navegar** a cualquier URL (ej: http://example.com)
4. **Serás redirigido** a https://portal.hastalap/login
5. **Autentica** con:
   - Usuario: `admin`
   - Contraseña: `admin`
6. **Acceso concedido**: Tu IP está en ipset 'authed'
7. **Abre Cliente 2** para probar múltiples usuarios simultáneos

---

## Topología de Red

```
┌─────────────────────────────────────────────────────────────┐
│                    MÁQUINA LOCAL                            │
│              (Tu computadora física)                        │
│                                                             │
│  Puerto 6091 ────────────┐                                 │
│  Puerto 6081 (6082) ─────┼─► Docker Network: portal-lan   │
│  Port Mapping             │        Subred: 10.200.0.0/24   │
│                           │                                 │
│                       [Bridge]                              │
│                           │                                 │
│              ┌────────────┼─────────────┐                  │
│              │            │             │                  │
│         ┌────▼───┐   ┌────▼────┐  ┌────▼────┐             │
│         │ Router │   │ Cliente1 │  │ Cliente2 │             │
│         │10.200  │   │10.200    │  │10.200    │             │
│         │.0.254  │   │.0.11     │  │.0.12     │             │
│         └────────┘   └──────────┘  └──────────┘             │
│         (Gateway)   (Navegador)   (Navegador)               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Comandos Útiles

### Ver Logs

```bash
# Router (portal cautivo)
docker logs -f router

# Cliente 1
docker logs -f client-1

# Cliente 2
docker logs -f client-2

# Ver últimas 50 líneas
docker logs --tail 50 router
```

### Inspeccionar Red

```bash
# Ver detalles de la red portal-lan
docker network inspect portal-lan

# Ver contenedores en la red
docker network inspect portal-lan --format='{{json .Containers}}' | jq .

# Ver interfaces de red del router
docker exec router ip addr show
```

### Acceso de Terminal

```bash
# Terminal del router (como root)
docker exec -it router bash

# Terminal del cliente
docker exec -it client-1 bash

# Verificar ipset en router
docker exec router ipset list authed
```

### Gestión de Contenedores

```bash
# Listar contenedores activos
docker ps --filter "name=^(router|client)"

# Detener todo
docker stop router client-1 client-2

# Reiniciar todo
docker restart router client-1 client-2

# Eliminar todo
docker rm router client-1 client-2

# Ver estadísticas (CPU, memoria)
docker stats router client-1 client-2
```

---

## Configuración Avanzada

### Variables de Entorno (2-deploy.sh)

```bash
# Cambiar duración de sesión (por defecto 3600 segundos)
AUTH_TIMEOUT=1800 ./2-deploy.sh  # 30 minutos

# No limpiar contenedores previos
SKIP_CLEAN=1 ./2-deploy.sh

# Cambiar subred de la LAN
SUBNET=10.100.0.0/24 ./2-deploy.sh

# Cambiar nombre de la red
LAN_NET=miportal ./2-deploy.sh
```

### Usuarios Predefinidos

Por defecto, el portal crea usuario:
- Usuario: `admin`
- Contraseña: `admin`

Para crear más usuarios, accede a http://localhost:6091/vnc.html (router) y usa el panel de administración en:
- URL: https://portal.hastalap/admin/users
- Autenticación HTTP Basic con admin/admin

---

## Solución de Problemas

### Las imágenes no se construyen

```bash
# Verificar que Dockerfiles existen
ls -la Docker/router/Dockerfile
ls -la Docker/client/Dockerfile

# Construir manualmente
docker build -t portal-router:latest Docker/router/
docker build -t portal-client:latest Docker/client/
```

### Los contenedores no inician

```bash
# Ver error específico
docker logs router
docker logs client-1

# Verificar que Docker tiene permisos suficientes
docker run --rm -it debian:slim /bin/bash

# Limpiar completamente y reintentar
docker container prune -f
docker network prune -f
./2-deploy.sh
```

### No puedo acceder a noVNC

```bash
# Verificar que los puertos están correctamente mapeados
docker port router
docker port client-1

# Verificar que el navegador puede alcanzar localhost:6081
curl http://localhost:6081/
# Debería retornar HTML de noVNC
```

### El portal cautivo no intercepta tráfico

```bash
# Verificar reglas iptables en router
docker exec router iptables -L -n -v

# Verificar ipset
docker exec router ipset list authed

# Ver logs detallados del router
docker logs -f router
```

---

## Detención y Limpieza

### Detener Temporalmente

```bash
./2-deploy.sh  # Si SKIP_CLEAN=1 no limpia

# O manualmente
docker stop router client-1 client-2
```

### Limpiar Completamente

```bash
# Eliminar contenedores
docker rm router client-1 client-2

# Eliminar red
docker network rm portal-lan

# Eliminar imágenes
docker rmi portal-router:latest portal-client:latest
```

---

## Referencia de Scripts Existentes

Los scripts 1 y 2 utilizan internamente los scripts legados:

| Script Legado | Ubicación | Función |
|---------------|-----------|---------|
| `create_lan.sh` | `Docker/config/` | Crear red Docker bridge |
| `router_online.sh` | `Docker/config/` | Iniciar contenedor router |
| `client_online.sh` | `Docker/config/` | Iniciar clientes (3 predefinidos) |

Nuestros scripts nuevos **mejoran** estos proporcionando:
- ✅ Nombres de imágenes legibles (`portal-router`, `portal-client`)
- ✅ Flujo unificado de preparación y despliegue
- ✅ Mejor manejo de errores y validaciones
- ✅ Información clara de acceso y topología
- ✅ Colores y formato visual mejorado

---

## Preguntas Frecuentes

### ¿Cuál es la diferencia entre 1-prepare.sh y 2-deploy.sh?

- **1-prepare.sh**: Construye las imágenes Docker (una sola vez)
- **2-deploy.sh**: Inicia contenedores desde las imágenes (se puede repetir para redesplegamiento)

### ¿Puedo ejecutar 2-deploy.sh sin ejecutar 1-prepare.sh primero?

No, 2-deploy.sh buscará las imágenes y fallará si no existen. Siempre ejecuta 1-prepare.sh primero.

### ¿Puedo cambiar de 2 clientes a 3 o más?

Sí, modificando 2-deploy.sh:
1. Añade nuevas variables: `CLIENT3_IP="10.200.0.13"`, `CLIENT3_PORT="6083"`
2. Duplica el bloque `docker run` para Cliente 3
3. Guarda cambios y ejecuta `./2-deploy.sh`

### ¿Cómo persisto usuarios creados en el panel admin?

El archivo `users.json` está dentro del contenedor. Para persistencia:

```bash
docker cp router:/app/app/users.json ./users.json  # Extraer
# ... Editar users.json
docker cp users.json router:/app/app/users.json  # Inyectar
```

### ¿Qué puertos se exponen?

- **Router**: 6091 (noVNC) + puertos internos (80, 443, 53, 8080)
- **Cliente-1**: 6081 (noVNC)
- **Cliente-2**: 6082 (noVNC)
- **Cliente-3** (si la añades): 6083 (noVNC)

---

*Última actualización: Diciembre 2025*
