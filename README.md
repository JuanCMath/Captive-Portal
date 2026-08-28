# Captive Portal

🇬🇧 English (you are here) · 🇪🇸 [Leer en español](README.es.md)

[![Tests](https://github.com/JuanCMath/Captive-Portal/actions/workflows/tests.yml/badge.svg)](https://github.com/JuanCMath/Captive-Portal/actions/workflows/tests.yml)

## Overview

Implementation of a captive portal that simulates a controlled network with mandatory authentication. The system intercepts HTTP traffic from unauthenticated clients and redirects them to a login page via iptables/ipset rules, allowing or blocking internet access based on the user's authentication state.

This project is a complete network access-control solution that integrates routing, DNS, a reverse proxy (nginx), an authentication backend (Python HTTP server), and a graphical interface accessible via noVNC to make testing and demonstrations easier in academic and research settings.

**The project supports two deployment modes:**

1. **Docker (simulation)**: isolated containers, ideal for development and testing
2. **Native Linux (production)**: direct deployment on a Linux server for real networks

## Quick Start

### Option 1: Docker deployment (recommended for development and testing)

```bash
cd Docker
./1-prepare.sh    # Build images
./2-deploy.sh     # Start containers
# Access: http://localhost:6081/vnc.html (Client 1)
```

### Option 2: Deployment on a Linux VM (with VirtualBox)

For testing in fully isolated VMs:

1. **Set up VirtualBox** (create a Host-Only network)
2. **Create 2 VMs**: Router (Ubuntu Desktop) + Client (Ubuntu Desktop)
3. **Configure networking** on both VMs
4. **Install on the Router VM**:
   ```bash
   cd ~/Captive-Portal/native
   sudo ./install.sh                 # dependencies, app, systemd service
   sudo ./configure-interfaces.sh    # choose WAN/LAN and the portal's IP
   sudo ./start-portal.sh            # firewall + dnsmasq + nginx + backend
   ```

See `docs/SETUP_VM_VIRTUALBOX.md` for detailed step-by-step instructions.

### Option 3: Native Linux deployment (server)

For production environments or real Linux machines, a single command
from the repository root:

```bash
sudo bash install.sh
```

Chains dependency installation, network configuration (interactive
wizard, or non-interactive if you export `WAN_IF`/`LAN_IF`/`LAN_IP`
beforehand), firewall setup, and service startup. For fine-grained
control (reinstalling a single step, changing `TLS_MODE`, updating
without touching the network) use the scripts under `native/`
separately:

```bash
cd native
sudo ./install.sh
sudo ./configure-interfaces.sh
sudo ./start-portal.sh
```

Details on each script, paths, and troubleshooting are in
`native/README.md`.

## System Architecture

> Diagrams of the authentication flow and of the defense against MAC
> spoofing (the project's most important security finding) are in
> [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md).

### Main Components

#### 1. **Router (Captive Portal)**
A container that acts as the network's gateway and control point. It implements:
- **Routing and NAT**: configures `iptables` to perform Source NAT (MASQUERADE) and IPv4 forwarding between the WAN interface (`eth0`) and LAN interface (`eth1`).
- **IP+MAC authentication system**: uses `ipset` with temporary `hash:ip,mac` sets (`authed`) to keep a dynamic record of authorized sessions (IP and MAC, not just IP) with a configurable timeout.
- **Local DNS server**: `dnsmasq` resolves DNS requests from the LAN, with custom resolution of the TLS certificate's name (`portal.hastalap` by default) to the router's IP.
- **Authentication backend**: an HTTP server implemented in Python (standard library) that handles:
  - Login and logout pages
  - Credential validation against `users.json`
  - Manipulating the `ipset` set via system commands
  - An admin panel with HTTP Basic authentication
- **TLS reverse proxy**: nginx configured with a self-signed certificate that:
  - Redirects HTTP traffic (port 80) detected by client operating systems (Android `generate_204`, iOS/macOS `hotspot-detect.html`, Windows `connecttest.txt`)
  - Terminates TLS connections (port 443) and routes HTTPS requests to the Python backend
- **Optional graphical interface**: a noVNC server with a Chromium browser for remote portal viewing

#### 2. **Client**
Containers that simulate end-user devices connected to the portal's network:
- Automatic default-route configuration pointing to the router
- DNS resolution pointing at the router's DNS server
- A noVNC graphical interface with a browser to interact with the portal
- Network capabilities (`NET_ADMIN`) to allow dynamic route configuration

#### 3. **Docker Network**
A custom bridge network (`portal-lan`) that simulates the internal LAN:
- Configurable subnet (`10.200.0.0/24` by default)
- Static IPs assigned to the router and clients
- Traffic isolation via a Docker network namespace

## Script-by-script technical breakdown

### `Docker/router/entrypoint.sh`

The router container's initialization script. Orchestrates the full captive-portal setup in sequence:

**Base system configuration:**
- Enables IPv4 forwarding via `sysctl -w net.ipv4.ip_forward=1`
- Sets NAT rules for address translation: `iptables -t nat -A POSTROUTING -o $UPLINK_IF -j MASQUERADE`
- Allows replies to WAN-established connections: `iptables -A FORWARD -i $UPLINK_IF -o $LAN_IF -m state --state RELATED,ESTABLISHED -j ACCEPT`

**Interface synchronization:**
- Implements active polling until Docker assigns an IP to the LAN interface (up to 20 attempts, 1-second interval)
- Necessary because `docker network connect` can run after the container has already started

**DNS service (dnsmasq):**
- Conditional install if not present in the image
- Configured in `/etc/dnsmasq.d/lan.conf` with:
  - `listen-address`: binds exclusively to the router's LAN IP
  - `bind-interfaces`: avoids listening on every interface
  - `address=/${CERT_CN}/${LAN_IP}`: local resolution of the TLS certificate's name
  - `domain-needed`, `bogus-priv`: DNS security filters
- Opens DNS ports (53/udp and 53/tcp) in iptables' INPUT chain

**Captive-portal mechanism with ipset:**
```bash
ipset create authed hash:ip,mac timeout ${AUTH_TIMEOUT} -exist
```
Creates a kernel-space data structure to store authorized sessions
(IP **and** MAC, not just IP) with automatic expiration.

**Redirect and filter rules:**
1. **HTTP redirect (nat table, PREROUTING):**
   ```bash
   iptables -t nat -A PREROUTING -i $LAN_IF -p tcp --dport 80 \
     -m set ! --match-set authed src,src -j CP_REDIRECT
   ```
   Intercepts HTTP requests from unauthenticated IPs and applies DNAT to the local nginx.

2. **Forwarding control (filter table, FORWARD):**
   - Priority rule: allows all traffic from IPs in the `authed` set toward WAN
   - Selective HTTPS blocking: rejects connections to port 443 from unauthenticated IPs with `tcp-reset`
   - General blocking: rejects any other traffic from unauthenticated IPs

**Python backend:**
- Run in the background with `python3 -u -m app.main ${PORTAL_PORT}`
- The `-u` flag disables stdout/stderr buffering for immediate logs in containers
- PID saved for container lifecycle management

**TLS generation and configuration:**
- Checks whether a certificate/key already exists
- Auto-generates one with OpenSSL if not:
  ```bash
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout $TLS_KEY -out $TLS_CERT -days 365 \
    -subj "/CN=${CERT_CN}"
  ```
- Configures nginx with two `server` blocks:
  - Port 80: 302 redirects for captive-portal detection paths (`/generate_204`, `/connecttest.txt`, `/hotspot-detect.html`, etc.)
  - Port 443: TLS termination and reverse proxy to the Python backend (`proxy_pass http://127.0.0.1:${PORTAL_PORT}`)

**Process management:**
- `wait "$PORTAL_PID"`: keeps the main process (PID 1) alive until the backend terminates, avoiding a premature container exit

### `Docker/router/start-ui.sh` and `Docker/client/start-ui.sh`

Identical scripts that implement a full graphical environment in a GPU-less container:

**Virtual X server (Xvfb):**
```bash
Xvfb :1 -screen 0 ${XVFB_W}x${XVFB_H}x${XVFB_D} &
```
Creates virtual display `:1` with configurable geometry (1366x768x24 by default). Allows graphical applications to run in headless containers.

**Window manager:**
- `fluxbox`: a lightweight window manager providing basic desktop functionality

**Remote web access (noVNC):**
```bash
websockify --web=/usr/share/novnc/ 6081 localhost:5900
```
- `websockify` acts as a WebSocket-to-TCP bridge
- Serves the noVNC web interface on port 6081
- Translates browser WebSocket traffic to native VNC protocol (port 5900)

**VNC server:**
```bash
x11vnc -display :1 -nopw -forever
```
- Exposes the Xvfb display via the VNC protocol
- `-nopw`: no authentication (only appropriate for isolated lab environments)
- `-forever`: accepts multiple consecutive connections

**Automatic browser:**
- Conditional Chromium launch if `BROWSER_URL` is set
- `--no-sandbox`: disables sandboxing (required in containers without full namespaces)
- 2-second delay to allow the X server to fully initialize

**Container persistence:**
```bash
tail -f /tmp/novnc.log /tmp/x11vnc.log /tmp/fluxbox.log /tmp/dnsmasq.log 2>/dev/null || tail -f /tmp/novnc.log
```
Keeps the process in the foreground by following logs. Implements a fallback if some logs don't exist.

### `Docker/client/entrypoint.sh`

A minimal routing-setup script for client containers:

```bash
ip route replace default via "${ROUTER_IP}" || true
```
- Sets the default route to point at the portal router
- `replace`: overwrites the existing route if present
- `|| true`: continues execution even if the command fails (fault tolerance)
- Requires the `NET_ADMIN` capability in the container

## Operation Flow

> To bring up the Docker environment, see "Quick Start" above
> (`1-prepare.sh` + `2-deploy.sh`). What follows describes the
> authentication cycle once the router and clients are already running.

### Authentication Cycle

#### Unauthenticated Client

1. **Automatic portal detection:**
   - The client's operating system makes connectivity checks:
     - Android: `GET /generate_204` (expects code 204, gets 302)
     - iOS/macOS: `GET /hotspot-detect.html` (expects specific HTML, gets a redirect)
     - Windows: `GET /connecttest.txt` or `/ncsi.txt` (expects specific text)

2. **HTTP traffic interception:**
   - Client tries to reach `http://example.com`
   - An iptables PREROUTING rule detects the IP is not present in `ipset authed`
   - DNAT redirects the connection to `${LAN_IP}:80` (local nginx)
   - Nginx responds with a 302 redirect to `https://${CERT_CN}/login`

3. **Controlled DNS resolution:**
   - Client resolves `portal.hastalap` (or the configured CN)
   - `dnsmasq` responds with the router's IP (`10.200.0.254`)
   - Avoids dependence on external DNS and guarantees access to the portal

4. **Portal presentation:**
   - The browser establishes a TLS connection with nginx (port 443)
   - Nginx performs a `proxy_pass` to the Python backend (port 8080)
   - The backend serves the login form via an HTML template

#### Authentication Process

1. **Credential submission:**
   - The user fills out the form and sends a POST to `/login`
   - The backend extracts the client's IP from the `X-Real-IP` header (injected by nginx)

2. **Validation:**
   - `check_credentials()` compares against the stored hash
     (PBKDF2-HMAC-SHA256, 260,000 iterations, per-user salt) using
     `hmac.compare_digest` (constant-time) — see
     [`CAMBIOS_SEGURIDAD.md`](docs/CAMBIOS_SEGURIDAD.md).
   - Before that, rate limiting (5 attempts/min) and a valid CSRF token are required.

3. **Firewall authorization:**
   ```python
   subprocess.run(["ipset", "add", "authed", f"{client_ip},{client_mac}", "timeout", str(AUTH_TIMEOUT), "-exist"])
   ```
   - Adds the client's **IP,MAC** pair to the `ipset authed` set with a
     timeout — not just the IP, so another device that later receives
     that same IP (e.g. after a DHCP lease expires) doesn't inherit the
     session.
   - Kernel-level atomic operation, effective immediately

4. **Access activation:**
   - iptables FORWARD rules allow traffic from IPs in the `authed` set
   - The client can make unrestricted internet connections
   - Configurable timeout (3600 seconds by default) after which the IP is automatically removed

#### Authenticated Client

- All traffic toward WAN passes through this iptables rule:
  ```bash
  iptables -I FORWARD 1 -i $LAN_IF -o $UPLINK_IF -m set --match-set authed src,src -j ACCEPT
  ```
  (`src,src`: matches both the packet's IP **and** MAC against the `hash:ip,mac` set)
- HTTP requests are no longer redirected (the PREROUTING rule no longer matches)
- Normal browsing without interception

### Admin Panel

Access protected with HTTP Basic Authentication:

1. **Accessing the panel:**
   - URL: `https://portal.hastalap/admin`
   - Credentials for the `admin` user defined in `users.json`

2. **Features:**
   - **View authorized IPs:**
     ```bash
     ipset list authed
     ```
     Shows the current set with remaining expiration times

   - **Manual access revocation:**
     ```python
     subprocess.run(["ipset", "del", "authed", f"{ip},{mac}"])
     ```
     Immediately removes that session (IP+MAC) from the authorized set

   - **User management**: create and delete accounts from the panel
     itself (`/admin/users`), with a CSRF token and a minimum password
     length. The `admin` account can't be deleted from there.

## System Requirements

### Software

- **Docker Engine**: ≥ 20.10
- **Docker Compose** (optional): ≥ 2.0 for simplified orchestration
- **Host operating system**:
  - Linux (native): full functionality
  - Windows with WSL2: functional with `--network=host` limitations
  - macOS with Docker Desktop: functional with limitations similar to Windows

### Network Capabilities

The router container requires elevated privileges:
- `CAP_NET_ADMIN`: interface, iptables, ipset configuration
- `CAP_NET_RAW`: raw socket manipulation for iptables
- Alternative: `--privileged` (grants all capabilities, less secure)

### Minimum Resources

- **CPU**: 2 cores (4 recommended for multiple clients with UI)
- **RAM**: 2 GB (4 GB recommended with graphical clients)
- **Disk**: 500 MB for base images + logs

## Configuration

### Environment Variables

#### Router (`Docker/router/entrypoint.sh`)

| Variable | Default | Description |
|----------|-------------------|-------------|
| `UPLINK_IF` | `eth0` | WAN network interface (toward the internet) |
| `LAN_IF` | `eth1` | LAN network interface (toward clients) |
| `LAN_IP` | `10.200.0.254` | Router's IP address on the LAN |
| `LAN_CIDR` | `10.200.0.0/24` | LAN subnet in CIDR notation |
| `PORTAL_PORT` | `8080` | Python backend port |
| `NGINX_HTTP_PORT` | `80` | nginx HTTP port |
| `NGINX_HTTPS_PORT` | `443` | nginx HTTPS port |
| `DNS_CACHE_SIZE` | `1000` | dnsmasq cache size |
| `AUTH_TIMEOUT` | `3600` | Authorization expiration time (seconds) |
| `CERT_CN` | `portal.hastalap` | TLS certificate's Common Name |
| `BROWSER_URL` | *(empty)* | URL for the noVNC browser (optional) |

#### Client (`Docker/client/entrypoint.sh`)

| Variable | Default | Description |
|----------|-------------------|-------------|
| `ROUTER_IP` | `10.200.0.254` | Gateway/router IP |
| `BROWSER_URL` | *(empty)* | Initial browser URL in noVNC |
| `VNC_PW` | *(no password)* | VNC password (requires script changes) |

### Configuration Files

#### `Docker/router/app/users.json`

User credential store (passwords hashed with PBKDF2, not plaintext;
see [`CAMBIOS_SEGURIDAD.md`](docs/CAMBIOS_SEGURIDAD.md)). Not tracked in
git — the app generates an `admin` account with a random password on
first startup if the file doesn't exist:
```json
[
  {
    "u": "admin",
    "p": "pbkdf2_sha256$260000$<salt-hex>$<hash-hex>"
  }
]
```

#### `Docker/router/app/config.py`

Centralized Python backend configuration:
```python
AUTH_TIMEOUT = int(os.getenv("AUTH_TIMEOUT", "3600"))
IPSET_NAME = "authed"
USERS_FILE = Path(__file__).parent / "users.json"
```

## Deployment

See "Quick Start" at the top of this document: `1-prepare.sh` +
`2-deploy.sh` for Docker, or `sudo bash install.sh` for native.

### System Verification

#### Check iptables rules on the router:
```bash
docker exec router iptables -t nat -L -n -v
docker exec router iptables -L FORWARD -n -v
```

#### Inspect the ipset set:
```bash
docker exec router ipset list authed
```

#### Verify connectivity from a client:
```bash
# Access the client shell (client-1 or client-2, see 2-deploy.sh)
docker exec -it client-1 bash

# Test DNS resolution
nslookup portal.hastalap
# Should resolve to 10.200.0.254

# Try HTTP access before authentication
curl -I http://example.com
# Should get a 302 redirect

# Verify the default route
ip route show default
# Should show: default via 10.200.0.254
```

## Security Considerations

### In an Academic/Lab Environment

The project is designed for demos and learning, with permissive
settings acceptable on isolated networks:

- **No-password VNC**: appropriate for a lab network with no external access
- **Self-signed certificate** (default mode): enough to demonstrate TLS working
- **`--no-sandbox` on Chromium**: necessary in containers, low risk in a controlled environment

### For Production Deployment

Critical changes required:

1. **VNC authentication:**
   ```bash
   x11vnc -display :1 -usepw -forever
   ```
   Enable a password with `-usepw` and configure it beforehand.

2. **Valid TLS certificates:** ✅ implemented in the native deployment
   (`native/`) — `TLS_MODE=letsencrypt` in `portal.conf` issues and
   automatically renews a real certificate via `certbot` (HTTP-01
   challenge), with a firewall exception limited to port 80 on WAN. See
   `native/README.md`, "TLS with Let's Encrypt" section. The Docker
   deployment (meant for labs, usually without a public IP) still uses
   self-signed or "bring your own certificate".

3. **Password hashing:** ✅ implemented — `PBKDF2-HMAC-SHA256`
   (260,000 iterations, random per-user salt) in `app/users.py`, with
   constant-time comparison and automatic migration of legacy plaintext
   passwords. See `docs/CAMBIOS_SEGURIDAD.md`.

4. **Restricting Docker capabilities:**
   - Avoid `--privileged`
   - Use only the minimum necessary capabilities (`NET_ADMIN`, `NET_RAW`)
   - Implement AppArmor/SELinux profiles

5. **Logging and auditing:**
   - Log every authentication attempt
   - Monitor changes to the `ipset` set
   - Implement log rotation

6. **iptables hardening:**
   - Rate-limiting rules to prevent brute-force attacks
   - Log rejected packets for forensic analysis
   - Restrictive egress-filtering rules

7. **Network isolation:**
   - Separate physical VLANs for real segmentation
   - Don't expose noVNC ports (`6081`, `6091`) outside the management network
   - Implement segmentation between authenticated users

## Testing

The backend (`Docker/router/app/`) has a unit-test suite in
`Docker/router/tests/`, using the standard library's
`unittest`/`unittest.mock` (no pytest or other dependencies, in line
with the rest of the project). `subprocess.run` is replaced by a test
double (`tests/fakes.py`) that reproduces the real behavior of `ip
neigh`/`ipset` observed in end-to-end tests against Docker — no
`ipset`, `iptables`, or root privileges are needed to run them. They
run automatically on every push/PR via GitHub Actions
(`.github/workflows/tests.yml`, Python 3.11/3.13 matrix), together with
a syntax check of every `.sh` script in the repo.

```bash
cd Docker/router
python -m unittest discover -s tests -t . -v
```

Covers: session binding to IP+MAC (`ipset_utils`, `portal`), CSRF and
rate limiting, password hashing/migration and atomic `users.json`
writes, admin-panel HTTP Basic authentication, and
`X-Real-IP`/path-traversal filtering in `main.py`.

## Troubleshooting

### Router doesn't start correctly

**Symptom:** the container stops immediately or shows permission errors.

**Diagnosis:**
```bash
docker logs router
```

**Common causes:**
1. **Missing network capabilities:**
   ```
   Error: iptables: Permission denied
   ```
   **Fix:** verify `docker run` includes `--cap-add=NET_ADMIN --cap-add=NET_RAW`.

2. **LAN interface not receiving an IP:**
   ```
   [2025-11-17 10:30:45] Waiting for IP on eth1... (attempts exhausted)
   ```
   **Fix:** verify `docker network connect` ran successfully:
   ```bash
   docker inspect router | grep Networks -A 20
   ```

3. **Port 8080 already in use:**
   ```
   OSError: [Errno 98] Address already in use
   ```
   **Fix:** change `PORTAL_PORT` or identify the conflicting process on the host.

### Client can't access the internet after authenticating

**Diagnosis:**
```bash
# On the router, verify the IP is in the ipset
docker exec router ipset list authed

# Verify the FORWARD rules
docker exec router iptables -L FORWARD -n -v --line-numbers

# On the client, test connectivity
docker exec client-1 ping -c 3 8.8.8.8
```

**Common causes:**
1. **IP not added to the `ipset` set:**
   - Check the Python backend logs for errors in `subprocess.run(["ipset", "add", ...])`
   - Add manually for testing: `docker exec router ipset add authed 10.200.0.11`

2. **Incorrect order of FORWARD rules:**
   - The ACCEPT rule for `authed` must come before the REJECT rules
   - Verify with `iptables -L FORWARD --line-numbers`

3. **NAT not working:**
   ```bash
   docker exec router iptables -t nat -L POSTROUTING -n -v
   ```
   There should be a MASQUERADE rule toward the WAN interface.

### Portal doesn't redirect HTTP traffic

**Symptom:** the client reaches websites directly without seeing the login page.

**Diagnosis:**
```bash
# Verify the PREROUTING redirect rule
docker exec router iptables -t nat -L PREROUTING -n -v

# Traffic capture (if tcpdump is available)
docker exec router tcpdump -i eth1 -n port 80
```

**Common causes:**
1. **Client already authenticated:**
   - IP present in `ipset authed`
   - Remove for testing: `docker exec router ipset del authed 10.200.0.11`

2. **DNS not pointing at the router:**
   - Client resolves names with external DNS, bypassing the portal
   - Check: `docker exec client-1 cat /etc/resolv.conf`
   - Should contain `nameserver 10.200.0.254`

3. **Nginx not listening on port 80:**
   ```bash
   docker exec router netstat -tlnp | grep :80
   ```
   Should show nginx listening on `0.0.0.0:80`.

### Browser rejects the TLS certificate

**Symptom:** the browser shows "Your connection is not private" / "NET::ERR_CERT_AUTHORITY_INVALID".

**Explanation:** expected behavior with self-signed certificates.

**Options:**
1. **Accept the exception manually** (fine for a lab):
   - Chrome: click "Advanced" → "Proceed to portal.hastalap (unsafe)"
   - Firefox: "Advanced" → "Accept the Risk and Continue"

2. **Install the root CA on the client** (for extensive testing):
   ```bash
   # Export the router's certificate
   docker cp router:/etc/ssl/certs/portal.crt ./

   # On the host system, add it to the trust store
   # Linux: cp portal.crt /usr/local/share/ca-certificates/ && update-ca-certificates
   # Windows: Import certificate → Trusted Root Certification Authorities
   # macOS: Keychain Access → Add to System → Trust Always
   ```

### noVNC interface doesn't load

**Symptom:** `http://localhost:6081` doesn't respond or shows a connection error.

**Diagnosis:**
```bash
# Verify the container is running
docker ps | grep c1

# Check websockify logs
docker exec client-1 cat /tmp/novnc.log

# Verify the mapped port
docker port c1
```

**Common causes:**
1. **Port not mapped correctly:**
   - Verify `docker run` includes `-p 6081:6081`
   - Possible conflict if the port is already in use on the host

2. **noVNC services not started:**
   ```bash
   docker exec client-1 pgrep websockify
   docker exec client-1 pgrep x11vnc
   ```
   No PIDs means `start-ui.sh` didn't run correctly.

3. **Xvfb failed to start:**
   ```bash
   docker exec client-1 cat /tmp/fluxbox.log
   ```
   May indicate missing permissions or dependencies.

## Future Improvements

### Planned Features

1. **User database:**
   - Migrate `users.json` to SQLite or PostgreSQL
   - Support for thousands of users
   - Session and behavior auditing

2. **RADIUS/LDAP authentication:**
   - Integration with corporate directory services
   - Single Sign-On (SSO)
   - Automatic user sync

3. **Per-user bandwidth limits:**
   - Implementation with `tc` (traffic control)
   - Differentiated QoS by service plan
   - Real-time usage statistics

4. **Multilingual portal:**
   - Browser language detection
   - Jinja2 templates with i18n
   - Region-based configuration

5. **REST management API:**
   - Endpoints for user CRUD
   - Active-session queries
   - Integration with billing systems

6. **Captcha on the login form:**
   - Prevent automated attacks
   - reCAPTCHA or hCaptcha integration
   - Per-IP rate limiting

7. **Web admin dashboard:**
   - Metric visualizations with Chart.js/D3.js
   - Configurable alerts
   - Firewall-policy management

### Optimizations

1. **Smaller image sizes:**
   - Multi-stage builds in the Dockerfile
   - Alpine base images where possible
   - Removal of build-time dependencies

2. **DNS resolution caching:**
   - Increase dnsmasq's `cache-size` for large networks
   - Implement a full local recursive DNS resolver

3. **Session persistence:**
   - Store the `ipset` set on disk
   - Automatically restore it after a container restart
   - Versioned backup of `users.json`

## Deployment Scripts

### Docker

- **`Docker/1-prepare.sh`**: builds the Docker images (router and clients)
- **`Docker/2-deploy.sh`**: deploys the containers with the network setup (portal-lan with 2 clients)

### Native (Linux)

Installation in 4 independent steps (install → configure interfaces →
start → verify), so applying network changes doesn't require
reinstalling anything. Full detail in `native/README.md`.

- **`native/install.sh`**: installs dependencies (iptables, ipset,
  dnsmasq, nginx, python3), copies the app to `/opt/captive-portal`, and
  registers the `captive-portal` systemd service (with automatic
  restart on failure).
  **Usage**: `sudo bash native/install.sh`
- **`native/configure-interfaces.sh`**: interactive wizard to choose
  WAN/LAN and the portal's IP.
- **`native/start-portal.sh`**: applies `iptables`/`ipset` (idempotent)
  and starts dnsmasq, nginx, and the backend.
- **`native/stop-portal.sh`** / **`native/status-portal.sh`**: stop and
  clean up, or check status (services, authenticated sessions, logs).

## Additional Documentation

- **`docs/ARQUITECTURA.md`**: diagrams of the redirect/authentication
  flow and of the defense against MAC spoofing (`hash:ip,mac`).
- **`native/TLS.md`**: self-signed certificate and Let's Encrypt in the
  native deployment — the three TLS modes, how to switch between them,
  and diagnostics.
- **`docs/SETUP_VM_VIRTUALBOX.md`**: complete step-by-step guide to
  setting up 2 Ubuntu virtual machines with VirtualBox (router +
  client), including:
  - Creating a Host-Only network
  - Installing Ubuntu Desktop on both VMs
  - Configuring network interfaces
  - Installing the portal via script
  - Testing and troubleshooting
- **`docs/CAMBIOS_SEGURIDAD.md`**: December 2025 security audit — what
  was fixed and why.
- **`docs/ANALISIS_PROYECTO.md`**: an in-depth technical analysis of the
  project at an earlier stage (historical note at the top of the document).
- **`docs/captiveportal.md`**: the original course assignment that this
  project grew out of.

## License

This project is developed for educational and academic purposes. See
the `LICENSE` file for distribution and usage details.

## Authors and Contributions

Project developed for the Computer Networks course.

To report issues or suggest improvements, use the repository's issue tracker.

## References

- [Netfilter/iptables Documentation](https://www.netfilter.org/documentation/)
- [ipset Man Page](https://ipset.netfilter.org/ipset.man.html)
- [dnsmasq Manual](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
- [RFC 8910: Captive-Portal Identification in DHCP and Router Advertisements](https://datatracker.ietf.org/doc/html/rfc8910)
- [Docker Network Documentation](https://docs.docker.com/network/)
- [nginx Reverse Proxy Guide](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/)
