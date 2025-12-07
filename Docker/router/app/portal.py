# app/portal.py
"""
Lógica del portal cautivo (login, estado) usando solo librerías estándar.
"""

from typing import Dict, List, Tuple, Optional
import html

from .config import AUTH_TIMEOUT
from .users import load_users
from .ipset_utils import add_to_ipset, check_ipset, remove_from_ipset, get_remaining_timeout


def render_login_page(client_ip: str, auth_timeout: int, error: Optional[str] = None) -> str:
    """Devuelve el HTML del formulario de login."""
    error_block = ""
    if error:
        error_block = f"""
        <div class="helper" style="color: var(--danger); margin-top: 10px;">
          {html.escape(error)}
        </div>
        """

    return f"""<!doctype html>
<html lang="es">
<head>
    <meta charset="utf-8" />
    <title>Portal de acceso · Portal cautivo</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link href="/static/base.css" rel="stylesheet" />
</head>
<body>
  <div class="shell">
    <div class="card">
      <div class="card-inner">
        <h1>
          <span class="logo">CP</span>
          Portal de acceso
        </h1>

        <!-- Pill de estado -->
        <div class="status-pill">
          <span class="dot"></span>
          <span>
            Portal cautivo activo · IP {html.escape(client_ip)}
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
        <form method="post" action="/login" style="margin-top: 18px;">
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
            <button type="submit">Iniciar sesión</button>
          </div>
        </form>

        <!-- Enlaces útiles -->
        <div class="meta">
          <span><a href="/status">Ver estado de la sesión</a></span>
          <span><a href="/admin/users">Panel de administración</a></span>
        </div>
      </div>
    </div>
  </div>
</body>
</html>
"""


def process_login(client_ip: str, form_data: Dict[str, List[str]]) -> Tuple[int, Dict[str, str], str]:
    """
    Procesa un POST /login.

    Devuelve (status_code, headers, body_html).
    Para éxito, devuelve 302 + Location=/status.
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
    if not ok:
        body = """<html><body>
        <h1>Error en el portal</h1>
        <p>Estás autenticado, pero no se pudo registrar tu IP en el sistema.
        Contacta con el administrador.</p>
        </body></html>"""
        return 500, {}, body

    # OK → redirige a /status
    headers = {"Location": "https://portal.hastalap/status"}
    return 302, headers, ""


def render_status_page() -> str:
    """
    HTML de /status.
    No usa plantillas: el estado se obtiene vía JS desde /status.json.
    """
    return """<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Estado del Portal</title>
    <link rel="stylesheet" href="/static/base.css">
    <style>
        .btn-logout {
            background: var(--danger, #dc3545);
            margin-top: 16px;
        }
        .btn-logout:hover {
            background: #c82333;
        }
        .time-display {
            font-size: 1.4em;
            font-weight: bold;
            color: var(--accent, #0077cc);
        }
        .time-warning {
            color: var(--danger, #dc3545) !important;
        }
        #logout-section {
            display: none;
            margin-top: 20px;
        }
        #logout-section.show {
            display: block;
        }
    </style>
</head>
<body>

<div class="shell">
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

        <!-- Enlace al portal -->
        <div class="admin-link">
            <a href="/login">Volver al portal</a>
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

</body>
</html>
"""


def get_status_json(client_ip: str) -> Dict[str, object]:
    """Devuelve el JSON con el estado de autenticación."""
    authed = check_ipset(client_ip)
    remaining = get_remaining_timeout(client_ip) if authed else 0
    return {
        "client_ip": client_ip,
        "authenticated": authed,
        "expires_in_seconds": remaining,
    }


def process_logout(client_ip: str) -> Tuple[int, Dict[str, str], str]:
    """
    Procesa un POST /logout.
    Elimina la IP del ipset y redirige al login.
    """
    ok = remove_from_ipset(client_ip)
    if ok:
        headers = {"Location": "/login"}
        return 302, headers, ""
    else:
        body = """<html><body>
        <h1>Error al cerrar sesión</h1>
        <p>No se pudo eliminar tu IP del sistema. Es posible que ya no estuvieras autenticado.</p>
        <p><a href="/login">Volver al portal</a></p>
        </body></html>"""
        return 500, {}, body
