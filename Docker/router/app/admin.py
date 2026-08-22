# app/admin.py
"""
Panel de administración de usuarios sin FastAPI, usando solo librerías estándar.
"""

from typing import Optional, List, Dict, Tuple
import html

from .users import load_users, create_user, delete_user
from .config import AUTH_TIMEOUT
from .portal import SHIELD_ICON
from . import security


def _render_users_table(users: List[Dict[str, str]], csrf_token: str) -> str:
    rows = []
    csrf_field = f'<input type="hidden" name="csrf_token" value="{html.escape(csrf_token)}" />'

    for u in users:
        username = str(u.get("u", ""))
        username_esc = html.escape(username)

        if username == "admin":
            role_html = '<span class="badge admin">admin</span>'
            actions_html = '<span style="font-size:0.7rem;color:var(--muted);">bloqueado</span>'
        else:
            role_html = '<span class="badge">usuario</span>'
            actions_html = f"""
            <form method="post" action="/admin/users/delete">
                {csrf_field}
                <input type="hidden" name="username" value="{username_esc}" />
                <button type="submit">Eliminar</button>
            </form>
            """

        rows.append(
            f"""
          <div class="user-row">
            <div>{username_esc}</div>
            <div>{role_html}</div>
            <div class="user-actions">
              {actions_html}
            </div>
          </div>
        """
        )

    if not rows:
        return """
        <div style="padding:6px 0;font-size:0.78rem;color:var(--muted);">
          No hay usuarios definidos.
        </div>
        """

    return "\n".join(rows)


def render_admin_page(
    admin_user: str,
    message: Optional[str],
    csrf_token: str,
    success: Optional[bool] = None,
) -> str:
    users_list, _ = load_users()
    users_html = _render_users_table(users_list, csrf_token)
    csrf_field = f'<input type="hidden" name="csrf_token" value="{html.escape(csrf_token)}" />'
    msg_block = ""
    if message:
        msg_class = "success" if success else ("error" if success is False else "helper")
        msg_block = f"""
        <div class="{msg_class}" style="margin-top:14px;">
          {html.escape(message)}
        </div>
        """

    return f"""<!doctype html>
<html lang="es">
<head>
    <meta charset="utf-8" />
    <title>Gestión de usuarios · Portal cautivo</title>
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <link href="/static/base.css" rel="stylesheet" />
    <link rel="icon" href="/static/favicon.svg" type="image/svg+xml" />
</head>
<body>
  <canvas id="net-bg" aria-hidden="true"></canvas>
  <div class="shell wide">
    <div class="brand">
      {SHIELD_ICON}
      <span class="brand-name">Portal cautivo<small>Panel de administración</small></span>
    </div>
    <div class="card">
      <div class="card-inner">
        <h1>Gestión de usuarios</h1>
        <div class="subtitle">
          Crea o elimina cuentas que pueden autenticarse en el portal cautivo.
        </div>

        <div class="helper">
          Estás autenticado como <strong>{html.escape(admin_user)}</strong>.
          Las credenciales se validan con HTTP Basic (usuario/contraseña).
        </div>

        <div class="users">
          <div class="users-header">
            <div>Usuario</div>
            <div>Rol</div>
            <div class="user-actions">Acciones</div>
          </div>
          {users_html}
        </div>

        <div class="create-box">
          <h2>Nueva cuenta</h2>
          <form method="post" action="/admin/users/create">
            {csrf_field}
            <div>
              <label for="new_username">Usuario</label>
              <input id="new_username" name="username"
                     placeholder="p.ej. estudiante1" required />
            </div>
            <div>
              <label for="new_password">Contraseña</label>
              <input id="new_password" name="password" placeholder="••••••••"
                     type="password" minlength="8" required />
            </div>
            <div>
              <button type="submit">Crear</button>
            </div>
          </form>
        </div>

        {msg_block}

        <div class="meta">
          <span><a href="/login">Volver al portal</a></span>
          <span>Tiempo de sesión: {AUTH_TIMEOUT} s</span>
        </div>
      </div>
    </div>
  </div>
  <script src="/static/network-bg.js"></script>
</body>
</html>
"""


def handle_create_user(username: str, password: str, actor_ip: str) -> Tuple[bool, str]:
    ok, msg = create_user(username, password)
    security.audit_log(
        "admin_create_user",
        ip=actor_ip,
        target_user=username,
        result="ok" if ok else "error",
        detail=msg,
    )
    return ok, msg


def handle_delete_user(username: str, actor_ip: str) -> Tuple[bool, str]:
    ok, msg = delete_user(username)
    security.audit_log(
        "admin_delete_user",
        ip=actor_ip,
        target_user=username,
        result="ok" if ok else "error",
        detail=msg,
    )
    return ok, msg
