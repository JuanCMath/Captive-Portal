# app/portal.py
"""
Lógica del portal cautivo (login, estado) usando solo librerías estándar.
"""

from typing import Dict, List, Tuple, Optional
import html

from .config import AUTH_TIMEOUT
from .users import check_credentials
from .ipset_utils import (
    add_to_ipset,
    check_ipset,
    remove_from_ipset,
    remove_from_ipset_by_ip,
    get_remaining_timeout,
)
from .mac_utils import get_mac_for_ip
from . import security

# Ícono de marca inline (SVG): nada de imágenes/fuentes externas a
# propósito -- esta página se sirve a clientes SIN autenticar, que no
# tienen salida a Internet todavía, así que un recurso externo aquí
# simplemente no cargaría.
SHIELD_ICON = """<svg width="30" height="30" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Portal cautivo">
  <defs>
    <linearGradient id="brandGrad" x1="0" y1="0" x2="24" y2="24" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#38bdf8"/>
      <stop offset="1" stop-color="#6366f1"/>
    </linearGradient>
  </defs>
  <path d="M12 2 L20 5.5 V11 C20 16 16.5 20 12 22 C7.5 20 4 16 4 11 V5.5 Z" fill="url(#brandGrad)"/>
  <path d="M8.5 12.2 L11 14.7 L16 9.5" stroke="white" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>"""


def render_login_page(
    client_ip: str,
    auth_timeout: int,
    error: Optional[str] = None,
    csrf_token: Optional[str] = None,
) -> str:
    """Devuelve el HTML del formulario de login."""
    error_block = ""
    if error:
        error_block = f"""
        <div class="error">
          {html.escape(error)}
        </div>
        """

    csrf_field = f'<input type="hidden" name="csrf_token" value="{html.escape(csrf_token or "")}" />'

    return f"""<!doctype html>
<html lang="es">
<head>
    <meta charset="utf-8" />
    <title>Portal de acceso · Portal cautivo</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link href="/static/base.css" rel="stylesheet" />
    <link rel="icon" href="/static/favicon.svg" type="image/svg+xml" />
</head>
<body>
  <canvas id="net-bg" aria-hidden="true"></canvas>
  <div class="shell">
    <div class="brand">
      {SHIELD_ICON}
      <span class="brand-name">Portal cautivo<small>Acceso a la red</small></span>
    </div>
    <div class="card">
      <div class="card-inner">
        <h1>Iniciar sesión</h1>

        <!-- Pill de estado -->
        <div class="status-pill">
          <span class="dot"></span>
          <span>
            Sin autenticar · IP {html.escape(client_ip)}
          </span>
        </div>

        <!-- Mensaje de ayuda / instrucciones -->
        <div class="helper">
          Introduce tu usuario y contraseña para obtener acceso a Internet.
          Tu sesión tendrá una duración aproximada de
          <strong>{auth_timeout}</strong> segundos.
        </div>

        {error_block}

        <!-- Formulario de login -->
        <form method="post" action="/login" style="margin-top: 18px;" id="login-form">
          {csrf_field}
          <div>
            <label for="username">Usuario</label>
            <input id="username"
                   name="username"
                   placeholder="p.ej. estudiante1"
                   autocomplete="username"
                   required />
          </div>

          <div>
            <label for="password">Contraseña</label>
            <input id="password"
                   name="password"
                   type="password"
                   placeholder="••••••••"
                   autocomplete="current-password"
                   required />
          </div>

          <div>
            <button type="submit" id="login-btn">
              <span class="spinner" aria-hidden="true"></span>
              <span class="btn-label">Iniciar sesión</span>
            </button>
          </div>
        </form>

        <!-- Enlaces útiles -->
        <div class="meta">
          <span><a href="/status">Ver estado de la sesión</a></span>
        </div>
      </div>
    </div>
    <div class="admin-link"><a href="/admin/users">Panel de administración</a></div>
  </div>

  <script>
    // Feedback inmediato al enviar: las redes de un portal cautivo suelen
    // ser lentas justo en este paso, y sin esto el clic parece no hacer nada.
    document.getElementById('login-form').addEventListener('submit', function () {{
      var btn = document.getElementById('login-btn');
      btn.classList.add('is-loading');
      btn.disabled = true;
    }});
  </script>
  <script src="/static/network-bg.js"></script>
</body>
</html>
"""


def process_login(
    client_ip: str,
    form_data: Dict[str, List[str]],
    csrf_token: Optional[str] = None,
) -> Tuple[int, Dict[str, str], str]:
    """
    Procesa un POST /login.

    Devuelve (status_code, headers, body_html).
    Para éxito, devuelve 302 + Location=/status (relativo: nginx ya
    terminó TLS, así que no dependemos de un dominio fijo).
    """
    if not security.verify_csrf_token(client_ip, csrf_token or ""):
        body = render_login_page(
            client_ip=client_ip,
            auth_timeout=AUTH_TIMEOUT,
            error="El formulario expiró o no es válido. Recarga la página e inténtalo de nuevo.",
            csrf_token=security.issue_csrf_token(client_ip),
        )
        return 400, {}, body

    blocked, retry_after = security.login_limiter.is_blocked(client_ip)
    if blocked:
        security.audit_log("login_rate_limited", ip=client_ip)
        body = render_login_page(
            client_ip=client_ip,
            auth_timeout=AUTH_TIMEOUT,
            error=f"Demasiados intentos fallidos. Espera {retry_after}s antes de volver a intentarlo.",
            csrf_token=security.issue_csrf_token(client_ip),
        )
        return 429, {}, body

    username = (form_data.get("username") or [""])[0]
    password = (form_data.get("password") or [""])[0]

    ok = check_credentials(username, password)

    if not ok:
        security.login_limiter.record_failure(client_ip)
        security.audit_log("login_failed", ip=client_ip, user=username)
        body = render_login_page(
            client_ip=client_ip,
            auth_timeout=AUTH_TIMEOUT,
            error="Credenciales inválidas. Verifica usuario y contraseña.",
            csrf_token=security.issue_csrf_token(client_ip),
        )
        return 401, {}, body

    security.login_limiter.record_success(client_ip)

    mac = get_mac_for_ip(client_ip)
    if not mac:
        # Sin la MAC no podemos vincular la sesión al dispositivo (solo a la
        # IP), que es justo lo que se quiere evitar: otro dispositivo que
        # más adelante reciba esta misma IP heredaría la sesión. Es un
        # estado transitorio normal (la entrada ARP puede tardar unos
        # instantes) así que pedimos reintentar en vez de fallar duro.
        security.audit_log("login_mac_lookup_error", ip=client_ip, user=username)
        body = render_login_page(
            client_ip=client_ip,
            auth_timeout=AUTH_TIMEOUT,
            error="No se pudo verificar tu dispositivo en la red. Espera unos segundos y vuelve a intentarlo.",
            csrf_token=security.issue_csrf_token(client_ip),
        )
        return 503, {}, body

    added = add_to_ipset(client_ip, mac)
    if not added:
        security.audit_log("login_ipset_error", ip=client_ip, user=username)
        body = """<html><body>
        <h1>Error en el portal</h1>
        <p>Estás autenticado, pero no se pudo registrar tu IP en el sistema.
        Contacta con el administrador.</p>
        </body></html>"""
        return 500, {}, body

    security.audit_log("login_success", ip=client_ip, user=username)

    # Redirección relativa: conserva el esquema/host con el que el cliente
    # ya está hablando (nginx), en vez de asumir un dominio fijo que puede
    # no coincidir con CERT_CN si el despliegue lo personaliza.
    headers = {"Location": "/status"}
    return 302, headers, ""


def render_status_page() -> str:
    """
    HTML de /status.
    No usa plantillas: el estado se obtiene vía JS desde /status.json.
    """
    html_out = """<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Estado del Portal</title>
    <link rel="stylesheet" href="/static/base.css">
    <link rel="icon" href="/static/favicon.svg" type="image/svg+xml">
    <style>
        .btn-logout {
            background: var(--danger);
            box-shadow: none;
            margin-top: 4px;
        }
        .btn-logout:hover {
            filter: brightness(1.08);
        }
        .time-display {
            font-size: 1.35rem;
            font-weight: 650;
            font-variant-numeric: tabular-nums;
            color: var(--accent);
        }
        .time-warning {
            color: var(--danger) !important;
        }
        #logout-section {
            display: none;
            margin-top: 18px;
        }
        #logout-section.show {
            display: block;
        }
    </style>
</head>
<body>
<canvas id="net-bg" aria-hidden="true"></canvas>

<div class="shell">
  <div class="brand">
    __SHIELD_ICON__
    <span class="brand-name">Portal cautivo<small>Acceso a la red</small></span>
  </div>
  <div class="card">
      <div class="card-inner">
        <h1>Estado de la sesión</h1>

        <!-- Indicador visual -->
        <div class="status-pill" id="pill">
            <span class="dot" id="dot"></span>
            <span id="text">Cargando estado...</span>
        </div>

        <!-- Información fija -->
        <div class="helper" id="info-ip">
            Tu dirección IP: <strong id="client_ip">detectando...</strong>
        </div>

        <div class="helper" id="info-exp">
            Tiempo restante: <span class="time-display" id="time-display">--:--</span>
        </div>

        <!-- Botón de logout (solo visible si autenticado) -->
        <div id="logout-section">
            <form id="logout-form" method="post" action="/logout">
                <button type="submit" class="btn-logout">Cerrar sesión</button>
            </form>
        </div>

        <div class="meta">
          <span><a href="/login">Volver al portal</a></span>
        </div>
      </div>
  </div>
</div>

<script>
let remainingSeconds = 0;
let countdownInterval = null;

function formatTime(seconds) {
    if (seconds <= 0) return "00:00";
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h > 0) {
        return h + ":" + String(m).padStart(2, '0') + ":" + String(s).padStart(2, '0');
    }
    return String(m).padStart(2, '0') + ":" + String(s).padStart(2, '0');
}

function updateTimeDisplay() {
    const display = document.getElementById('time-display');
    display.textContent = formatTime(remainingSeconds);

    // Advertencia visual si queda poco tiempo (menos de 5 minutos)
    if (remainingSeconds > 0 && remainingSeconds < 300) {
        display.classList.add('time-warning');
    } else {
        display.classList.remove('time-warning');
    }
}

function startCountdown() {
    if (countdownInterval) clearInterval(countdownInterval);
    countdownInterval = setInterval(() => {
        if (remainingSeconds > 0) {
            remainingSeconds--;
            updateTimeDisplay();
        } else {
            clearInterval(countdownInterval);
            refreshStatus(); // Refrescar estado cuando llegue a 0
        }
    }, 1000);
}

async function refreshStatus() {
    try {
        const res = await fetch('/status.json', {cache: 'no-store'});
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const data = await res.json();

        const dot = document.getElementById('dot');
        const text = document.getElementById('text');
        const clientIp = document.getElementById('client_ip');
        const logoutSection = document.getElementById('logout-section');

        clientIp.textContent = data.client_ip || 'desconocida';

        if (data.authenticated) {
            dot.classList.add('ok');
            text.textContent = "Conectado · acceso a Internet habilitado";
            logoutSection.classList.add('show');

            // Actualizar tiempo restante real desde el servidor
            remainingSeconds = data.expires_in_seconds || 0;
            updateTimeDisplay();
            startCountdown();
        } else {
            dot.classList.remove('ok');
            text.textContent = "Sesión expirada · vuelve a iniciar sesión";
            logoutSection.classList.remove('show');
            remainingSeconds = 0;
            updateTimeDisplay();
            if (countdownInterval) clearInterval(countdownInterval);
        }

    } catch (e) {
        console.error("Error refrescando estado:", e);
        document.getElementById('text').textContent = "Error obteniendo estado del portal";
    }
}

// Manejar logout con confirmación
document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('logout-form');
    form.addEventListener('submit', (e) => {
        if (!confirm('¿Seguro que deseas cerrar la sesión? Perderás el acceso a Internet.')) {
            e.preventDefault();
        }
    });
    refreshStatus();
});

// Refrescar estado cada 30 segundos (el countdown local mantiene la precisión)
setInterval(refreshStatus, 30000);
</script>
<script src="/static/network-bg.js"></script>

</body>
</html>
"""
    return html_out.replace("__SHIELD_ICON__", SHIELD_ICON)


def get_status_json(client_ip: str) -> Dict[str, object]:
    """Devuelve el JSON con el estado de autenticación."""
    mac = get_mac_for_ip(client_ip)
    if not mac:
        return {
            "client_ip": client_ip,
            "authenticated": False,
            "expires_in_seconds": 0,
        }
    authed = check_ipset(client_ip, mac)
    remaining = get_remaining_timeout(client_ip, mac) if authed else 0
    return {
        "client_ip": client_ip,
        "authenticated": authed,
        "expires_in_seconds": remaining,
    }


def process_logout(client_ip: str) -> Tuple[int, Dict[str, str], str]:
    """
    Procesa un POST /logout.
    Elimina la sesión (IP+MAC) del ipset y redirige al login.
    """
    mac = get_mac_for_ip(client_ip)
    ok = remove_from_ipset(client_ip, mac) if mac else remove_from_ipset_by_ip(client_ip)
    if ok:
        security.audit_log("logout", ip=client_ip)
        headers = {"Location": "/login"}
        return 302, headers, ""
    else:
        security.audit_log("logout_error", ip=client_ip)
        body = """<html><body>
        <h1>Error al cerrar sesión</h1>
        <p>No se pudo eliminar tu IP del sistema. Es posible que ya no estuvieras autenticado.</p>
        <p><a href="/login">Volver al portal</a></p>
        </body></html>"""
        return 500, {}, body
