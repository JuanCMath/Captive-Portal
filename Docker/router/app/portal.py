# app/portal.py
"""
Lógica del portal cautivo (login, estado) usando solo librerías estándar.
"""

from typing import Dict, List, Tuple, Optional
import html

from .config import AUTH_TIMEOUT
from .users import load_users
from .ipset_utils import add_to_ipset, check_ipset


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
    headers = {"Location": "https://portal.local/status"}
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
            Tiempo restante de sesión: <strong id="expires">-</strong> segundos
        </div>

        <!-- Enlace al portal -->
        <div class="admin-link">
            <a href="/login">Volver al portal</a>
        </div>
      </div>
  </div>
</div>

<script>
// --- AUTO-ACTUALIZACIÓN DE ESTADO ---
async function refreshStatus() {
    try {
        const res = await fetch('/status.json', {cache: 'no-store'});
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const data = await res.json();

        const dot = document.getElementById('dot');
        const text = document.getElementById('text');
        const expires = document.getElementById('expires');
        const clientIp = document.getElementById('client_ip');

        clientIp.textContent = data.client_ip || 'desconocida';

        if (data.authenticated) {
            dot.classList.add('ok');
            text.textContent = "Conectado · acceso a Internet habilitado";
        } else {
            dot.classList.remove('ok');
            text.textContent = "Sesión expirada · vuelve a iniciar sesión";
        }

        if (typeof data.expires_in_seconds !== 'undefined') {
            expires.textContent = data.expires_in_seconds;
        }

    } catch (e) {
        console.error("Error refrescando estado:", e);
        const text = document.getElementById('text');
        text.textContent = "Error obteniendo estado del portal";
    }
}

setInterval(refreshStatus, 5000);
document.addEventListener('DOMContentLoaded', refreshStatus);
</script>

</body>
</html>
"""


def get_status_json(client_ip: str) -> Dict[str, object]:
    """Devuelve el JSON con el estado de autenticación."""
    authed = check_ipset(client_ip)
    return {
        "client_ip": client_ip,
        "authenticated": authed,
        # Para simplificar, devolvemos siempre AUTH_TIMEOUT como duración teórica
        "expires_in_seconds": AUTH_TIMEOUT,
    }
