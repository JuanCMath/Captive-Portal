# app/admin.py
"""
Panel de administración de usuarios sin FastAPI, usando solo librerías estándar.
"""

from typing import Optional, List, Dict
import html

from .users import load_users, create_user, delete_user
from .config import AUTH_TIMEOUT


def _render_users_table(users: List[Dict[str, str]]) -> str:
    rows = []
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


def render_admin_page(admin_user: str, message: Optional[str]) -> str:
    users_list, _ = load_users()
    users_html = _render_users_table(users_list)
    msg_block = ""
    if message:
        msg_block = f"""
        <div class="helper" style="margin-top:10px;">
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
</head>
<body>
  <div class="shell">
    <div class="card">
      <div class="card-inner">
        <h1>
          <span class="logo">CP</span>
          Gestión de usuarios
        </h1>
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
            <div>
              <label for="new_username">Usuario</label>
              <input id="new_username" name="username"
                     placeholder="p.ej. estudiante1" required />
            </div>
            <div>
              <label for="new_password">Contraseña</label>
              <input id="new_password" name="password" placeholder="••••••••" required />
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
</body>
</html>
"""


def handle_create_user(username: str, password: str) -> str:
    ok, msg = create_user(username, password)
    return msg


def handle_delete_user(username: str) -> str:
    ok, msg = delete_user(username)
    return msg
