from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, PlainTextResponse
from pathlib import Path
import json
import os
import subprocess
from jinja2 import Template

app = FastAPI(title="Captive Portal")

USERS_FILE = Path("/app/app/users.json")
AUTH_TIMEOUT = int(os.getenv("AUTH_TIMEOUT", "3600"))

LOGIN_HTML = Template("""
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Portal Cautivo</title></head>
<body>
  <h2>Portal Cautivo</h2>
  <p>Por favor, inicia sesión para acceder a Internet.</p>
  {% if error %}<p style="color:red">{{ error }}</p>{% endif %}
  <form method="post" action="/login">
    <label>Usuario:<br><input name="username" required></label><br><br>
    <label>Contraseña:<br><input type="password" name="password" required></label><br><br>
    <button type="submit">Entrar</button>
  </form>
</body>
</html>
""")

def load_users():
    # 1) variables de entorno (USERS_JSON='[{"u":"a","p":"b"}]')
    env_json = os.getenv("USERS_JSON")
    if env_json:
        return {u["u"]: u["p"] for u in json.loads(env_json)}
    # 2) archivo users.json
    if USERS_FILE.exists():
        data = json.loads(USERS_FILE.read_text(encoding="utf-8"))
        return {u["u"]: u["p"] for u in data}
    # 3) fallback demo
    return {"admin": "admin"}

def add_to_ipset(ip: str):
    # ipset add authed <IP> timeout <AUTH_TIMEOUT>
    try:
        subprocess.run(
            ["ipset", "add", "authed", ip, "timeout", str(AUTH_TIMEOUT)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return True
    except subprocess.CalledProcessError as e:
        return False

def check_ipset(ip: str) -> bool:
    try:
        out = subprocess.run(
            ["ipset", "test", "authed", ip],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        return "is in set" in out.stdout
    except Exception:
        return False

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return LOGIN_HTML.render(error=None)

@app.post("/login")
async def login(request: Request, username: str = Form(...), password: str = Form(...)):
    users = load_users()
    if username in users and users[username] == password:
        # IP del cliente (en Docker bridge será la IP del contenedor cliente)
        client_ip = request.client.host
        ok = add_to_ipset(client_ip)
        if not ok:
            return PlainTextResponse("Autenticado pero no pude añadir tu IP al ipset.", status_code=500)
        # Redirige a una página de estado simple
        return RedirectResponse(url="/status", status_code=302)
    return HTMLResponse(LOGIN_HTML.render(error="Credenciales inválidas"), status_code=401)

@app.get("/status")
async def status(request: Request):
    client_ip = request.client.host
    authed = check_ipset(client_ip)
    return JSONResponse({"client_ip": client_ip, "authenticated": authed, "expires_in_seconds": AUTH_TIMEOUT})
