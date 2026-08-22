# Arquitectura: flujo de autenticación y defensa contra suplantación

Este documento muestra dos mecanismos que son más fáciles de ver que de
leer: cómo el router intercepta y autentica a un cliente, y por qué la
sesión queda atada a la MAC del dispositivo y no solo a su IP.

## 1. Flujo de redirección y autenticación

El router usa dos puntos de control distintos del firewall: `PREROUTING`
(tabla `nat`) para capturar la primera petición HTTP de un cliente sin
autenticar y redirigirlo al portal, y `FORWARD` (tabla `filter`) para
decidir, en cada paquete, si esa IP+MAC tiene permiso de salir a Internet.

```mermaid
sequenceDiagram
    participant C as Cliente (10.0.0.5)
    participant FW as iptables + ipset (kernel)
    participant N as nginx
    participant B as Backend Python

    Note over C,FW: Sin autenticar
    C->>FW: TCP 80 → cualquier sitio
    FW->>FW: ipset test authed 10.0.0.5 → no existe
    FW-->>N: DNAT a 10.0.0.254:80 (PREROUTING)
    N-->>C: 302 → https://portal/login

    C->>N: POST /login (usuario + contraseña)
    N->>B: proxy_pass 127.0.0.1:8080
    B->>B: check_credentials() — PBKDF2, tiempo constante
    B->>B: get_mac_for_ip() vía "ip neigh"
    B->>FW: ipset add authed 10.0.0.5,AA:BB:CC:DD:EE:FF timeout 3600
    B-->>C: 302 → /status

    Note over C,FW: Ya autenticado
    C->>FW: TCP 443 → cualquier sitio
    FW->>FW: ipset test authed 10.0.0.5,AA:BB:CC:DD:EE:FF → coincide
    FW-->>C: ACCEPT (FORWARD) → llega a Internet
```

Dos detalles que no se ven leyendo el código de un vistazo:

- **La IP del cliente nunca la dice el cliente.** El backend solo confía en
  la cabecera `X-Real-IP` cuando la conexión TCP viene de `127.0.0.1`
  (nginx) — si alguien pudiera hablarle directo al backend, podría
  falsificarla y suplantar a otro usuario. Por eso el firewall bloquea el
  puerto del backend desde la LAN, no solo nginx confía en la cabecera.
- **La MAC no la manda nadie**: el backend la resuelve por su cuenta con
  `ip neigh show <ip>`, la tabla de vecinos que el propio kernel ya
  completó al recibir el `POST /login` (para responder por TCP, el kernel
  tuvo que resolver esa MAC vía ARP). No hay forma de que el cliente
  reporte una MAC distinta a la real.

## 2. Por qué la sesión no es solo "esa IP tiene acceso"

Este es el hallazgo de seguridad más importante del proyecto. Antes, el
`ipset` guardaba solo la IP autenticada (`hash:ip`). El problema: las IPs
se reasignan — un lease DHCP expira, un dispositivo se desconecta — y la
siguiente IP que las herede heredaba también la sesión de quien la tuvo
antes, sin poner ninguna credencial.

El fix no es lógica de aplicación, es una propiedad del propio `ipset`:
cambiar el tipo de conjunto a `hash:ip,mac` hace que el kernel compare
**ambos** campos, no uno solo.

```mermaid
flowchart TD
    A["Dispositivo A se autentica<br/>IP 10.0.0.5 · MAC AA:BB:CC:DD:EE:FF"] --> B["ipset: authed += 10.0.0.5,AA:BB:CC:DD:EE:FF"]
    B --> C["Dispositivo A se desconecta<br/>(lease DHCP expira)"]
    C --> D["Dispositivo B recibe la misma IP<br/>10.0.0.5 · su MAC real: 11:22:33:44:55:66"]
    D --> E{"¿Qué compara el ipset<br/>al reenviar tráfico de B?"}
    E -->|"hash:ip (antes)"| F["Solo mira 10.0.0.5 → coincide"]
    F --> G["B hereda la sesión de A<br/>sin credenciales — PERMITIDO"]
    E -->|"hash:ip,mac (ahora)"| H["Mira 10.0.0.5 Y 11:22:33:44:55:66<br/>contra lo guardado (...,AA:BB:CC:DD:EE:FF)"]
    H --> I["La MAC no coincide → BLOQUEADO<br/>B tiene que loguearse de nuevo"]

    style G fill:#c0392b,color:#fff
    style I fill:#1e8449,color:#fff
```

Verificado de punta a punta contra un `ipset` real (no mockeado): un
dispositivo que hereda la IP de otro con MAC distinta queda
`authenticated: false` en `/status.json` y sin salida a Internet real —
mismo resultado que un cliente que nunca se autenticó. Detalle completo en
[`CAMBIOS_SEGURIDAD.md`](CAMBIOS_SEGURIDAD.md).
