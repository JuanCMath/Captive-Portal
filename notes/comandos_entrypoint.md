
# Referencia de Comandos Usados en el EntryPoint del Portal Cautivo

Este documento describe **de forma genérica** los comandos utilizados en un entorno de red y portal cautivo, sin hacer referencia a configuraciones específicas del proyecto. Ideal para recordar rápidamente qué hace cada comando.

---

## 🧩 1. sysctl

### Modificar parámetros del kernel
```bash
sysctl -w <clave>=<valor>
```
Ejemplo:
```bash
sysctl -w net.ipv4.ip_forward=1
```
Activa o desactiva funciones del kernel dinámicamente.

---

## 🔥 2. iptables

`iptables` gestiona las reglas del firewall del kernel.

### Sintaxis genérica
```bash
iptables -t <tabla> -A <cadena> <condiciones> -j <acción>
```

### Tablas comunes
- **filter** → filtrado de paquetes
- **nat** → NAT (SNAT, DNAT, MASQUERADE)
- **mangle** → modificar cabeceras
- **raw** → reglas sin seguimiento de conexiones

### Cadenas comunes
- **INPUT** → paquetes hacia el host
- **OUTPUT** → paquetes que salen del host
- **FORWARD** → tráfico que pasa a través del host
- **PREROUTING** → antes de decidir ruta
- **POSTROUTING** → después de decidir ruta

### Ejemplos genéricos

#### Permitir tráfico a un puerto
```bash
iptables -A INPUT -i <interfaz> -p tcp --dport <puerto> -j ACCEPT
```

#### Bloquear tráfico
```bash
iptables -A FORWARD -i <in> -o <out> -j REJECT
```

#### NAT (masquerade)
```bash
iptables -t nat -A POSTROUTING -o <interfaz_salida> -j MASQUERADE
```

#### Redirección (DNAT)
```bash
iptables -t nat -A PREROUTING -p tcp --dport <puerto>     -j DNAT --to-destination <IP:PUERTO>
```

#### Crear cadena
```bash
iptables -t nat -N <nombre_cadena>
```

#### Usar ipset en regla
```bash
iptables -A FORWARD -m set --match-set <conjunto> src -j ACCEPT
```

---

## 🧩 3. ipset

Herramienta para crear conjuntos de IPs que iptables puede usar.

### Crear conjunto
```bash
ipset create <nombre> hash:ip timeout <segundos>
```

### Agregar IP
```bash
ipset add <nombre> <IP> timeout <seg>
```

### Probar si una IP está en el conjunto
```bash
ipset test <nombre> <IP>
```

### Mostrar contenido
```bash
ipset list <nombre>
```

---

## 📡 4. dnsmasq

Servidor DNS/DHCP ligero.

### Ejecutarlo
```bash
dnsmasq --keep-in-foreground --conf-dir=/ruta/config
```

### Parámetros comunes en archivos `.conf`
```
listen-address=<IP>
interface=<interfaz>
bind-interfaces
resolv-file=/ruta/resolv.conf
cache-size=<num>
address=/<dominio>/<IP>
```

---

## 🔐 5. openssl

Generación de certificados.

### Certificado autofirmado
```bash
openssl req -x509 -nodes -newkey rsa:<bits>     -keyout <archivo.key>     -out <archivo.crt>     -days <dias>     -subj "/CN=<common_name>"
```

---

## 🌐 6. nginx

Servidor web/proxy.

### Iniciar nginx
```bash
nginx -g "daemon off;"
```

### Configuración simple
```nginx
server {
    listen <puerto>;
    server_name <dominio>;

    location / {
        proxy_pass http://<IP_backend>:<puerto>;
    }
}
```

---

## 🐍 7. Python

### Ejecutar módulo
```bash
python3 -m <paquete> <argumentos>
```

Ejemplo genérico:
```bash
python3 -m app.main 8080
```

---

## 🛠 8. Shell genérico

### Crear archivo usando heredoc
```bash
cat > archivo.conf <<EOF
(contenido)
EOF
```

### Buscar comando
```bash
command -v <comando>
```

### Esperar un proceso
```bash
wait <PID>
```

### Buscar procesos por nombre o patrón
```bash
pgrep -x <nombre>
pgrep -f <patrón>
```

---

## 🖥️ 9. noVNC y componentes gráficos

### Servidor gráfico virtual
```bash
Xvfb :1 -screen 0 1366x768x24
```

### VNC server
```bash
x11vnc -display :1 -nopw -forever
```

### websockify
```bash
websockify --web=/ruta/novnc <puerto_web> <puerto_vnc>
```

---

# 📘 Fin del documento
