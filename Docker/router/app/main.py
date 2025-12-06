# app/main.py
import os
import sys
import json
import mimetypes
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs
from io import BufferedIOBase

from . import portal
from . import admin as admin_module
from . import auth
from .config import AUTH_TIMEOUT

APP_ROOT = Path(__file__).resolve().parent
STATIC_ROOT = APP_ROOT / "static"

def log(msg: str) -> None:
    print(msg, flush=True)


class PortalRequestHandler(BaseHTTPRequestHandler):
    server_version = "CaptivePortal/1.0"

    # --- Helpers ---

    @property
    def client_ip(self) -> str:
        """
        Devuelve la IP real del cliente.
        - Si viene detrás de nginx, usa X-Real-IP / X-Forwarded-For.
        - Si no, usa self.client_address[0] (acceso directo).
        """
        # 1) Intentar X-Real-IP (nginx la pone igual que $remote_addr)
        real_ip = self.headers.get("X-Real-IP")
        if real_ip:
            return real_ip

        # 2) Intentar X-Forwarded-For (puede traer lista de IPs)
        fwd_for = self.headers.get("X-Forwarded-For")
        if fwd_for:
            # nos quedamos con la primera IP de la lista
            return fwd_for.split(",")[0].strip()

        # 3) Fallback: conexión directa sin proxy
        return self.client_address[0]

    def _send_response(self, status: int, headers: dict | None = None, body: bytes | None = None) -> None:
        self.send_response(status)
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        if body is not None and not any(k.lower() == "content-type" for k in (headers or {})):
            self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _parse_post_form(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", errors="ignore")
        return parse_qs(raw)

    def _handle_static(self, path: str) -> None:
        rel = path[len("/static/") :]
        safe_path = Path(rel).name if "/" not in rel and "\\" not in rel else rel
        file_path = STATIC_ROOT / safe_path
        if not file_path.is_file():
            self._send_response(404, body=b"Not Found")
            return
        ctype, _ = mimetypes.guess_type(str(file_path))
        if not ctype:
            ctype = "application/octet-stream"
        data = file_path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _require_admin(self) -> str | None:
        auth_header = self.headers.get("Authorization")
        creds = auth.parse_basic_auth(auth_header)
        if not creds or not auth.is_admin(*creds):
            # 401 con WWW-Authenticate
            body = "Administracion - autenticacion requerida".encode("utf-8")
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Admin"')
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return None
        return creds[0]

    def do_HEAD(self):
        # Creamos un "writer" que descarta todo lo que se escriba
        class _NullWriter(BufferedIOBase):
            def write(self, data: bytes) -> None:
                # ignoramos el cuerpo
                pass
                pass
            
        # Guardamos el writer real y lo sustituimos por el dummy
        original_wfile = self.wfile
        try:
            self.wfile = _NullWriter()
            # Reutiliza toda la lógica de rutas de do_GET
            self.do_GET()
        finally:
            # Restauramos el writer real
            self.wfile = original_wfile

    # --- HTTP GET ---

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        log(f"GET {path} from {self.client_ip}")

        if path.startswith("/static/"):
            self._handle_static(path)
            return

        if path in ("/", "/login"):
            html_body = portal.render_login_page(
                client_ip=self.client_ip,
                auth_timeout=AUTH_TIMEOUT,
                error=None,
            )
            self._send_response(200, body=html_body.encode("utf-8"))
            return

        if path == "/status":
            html_body = portal.render_status_page()
            self._send_response(200, body=html_body.encode("utf-8"))
            return

        if path == "/status.json":
            data = portal.get_status_json(self.client_ip)
            body = json.dumps(data).encode("utf-8")
            headers = {"Content-Type": "application/json; charset=utf-8"}
            self._send_response(200, headers=headers, body=body)
            return

        if path in ("/admin", "/admin/"):
            # Redirigir a /admin/users
            headers = {"Location": "/admin/users"}
            self._send_response(302, headers=headers, body=b"")
            return

        if path == "/admin/users":
            admin_user = self._require_admin()
            if not admin_user:
                return
            html_body = admin_module.render_admin_page(admin_user=admin_user, message=None)
            self._send_response(200, body=html_body.encode("utf-8"))
            return

        # 404 por defecto
        self._send_response(404, body=b"Not Found")

    # --- HTTP POST ---

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        log(f"POST {path} from {self.client_ip}")
        form = self._parse_post_form()

        if path == "/login":
            status, headers, body_text = portal.process_login(self.client_ip, form)
            body_bytes = body_text.encode("utf-8") if body_text else b""
            if status == 302:
                # Redirección, asegura Location
                headers = headers or {}
                if "Location" not in headers:
                    headers["Location"] = "/status"
            self._send_response(status, headers=headers, body=body_bytes)
            return

        if path in ("/admin/users/create", "/admin/users/delete"):
            admin_user = self._require_admin()
            if not admin_user:
                return

            message: str | None = None
            if path == "/admin/users/create":
                username = (form.get("username") or [""])[0]
                password = (form.get("password") or [""])[0]
                message = admin_module.handle_create_user(username, password)
            elif path == "/admin/users/delete":
                username = (form.get("username") or [""])[0]
                message = admin_module.handle_delete_user(username)

            html_body = admin_module.render_admin_page(admin_user=admin_user, message=message)
            self._send_response(200, body=html_body.encode("utf-8"))
            return

        if path == "/logout":
            status, headers, body_text = portal.process_logout(self.client_ip)
            body_bytes = body_text.encode("utf-8") if body_text else b""
            self._send_response(status, headers=headers, body=body_bytes)
            return

        # Otros POST no soportados
        self._send_response(404, body=b"Not Found")


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def run_server(port: int) -> None:
    addr = ("0.0.0.0", port)
    httpd = ThreadingHTTPServer(addr, PortalRequestHandler)
    log(f"Servidor HTTP escuchando en puerto {port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("Servidor detenido por KeyboardInterrupt")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    env_port = os.getenv("PORTAL_PORT")
    if env_port:
        port = int(env_port)
    elif len(sys.argv) >= 2:
        port = int(sys.argv[1])
    else:
        port = 80
    run_server(port)
