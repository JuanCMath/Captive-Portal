# app/main.py
import os
import sys
import json
import socket
import mimetypes
import queue
import threading
from pathlib import Path
from urllib.parse import urlparse, parse_qs

from . import portal
from . import admin as admin_module
from . import auth
from .config import AUTH_TIMEOUT

APP_ROOT = Path(__file__).resolve().parent
STATIC_ROOT = APP_ROOT / "static"


def log(msg: str) -> None:
    print(msg, flush=True)


# ----------------------------
# HTTP helpers (manual)
# ----------------------------

_REASON = {
    200: "OK",
    204: "No Content",
    302: "Found",
    400: "Bad Request",
    401: "Unauthorized",
    404: "Not Found",
    405: "Method Not Allowed",
    413: "Payload Too Large",
    500: "Internal Server Error",
}


def _reason(status: int) -> str:
    return _REASON.get(status, "OK")


def _http_date_stub() -> str:
    # Opcional (no obligatorio). Para tu caso podemos omitir Date.
    return ""


def build_response(status: int, headers: dict | None, body: bytes | None) -> bytes:
    headers = dict(headers or {})
    if body is None:
        body = b""

    # Si no hay Content-Type y hay body, ponemos text/html por defecto
    if body and not any(k.lower() == "content-type" for k in headers.keys()):
        headers["Content-Type"] = "text/html; charset=utf-8"

    headers["Content-Length"] = str(len(body))
    # Cerramos conexión para simplificar HTTP/1.1 (sin keep-alive)
    headers["Connection"] = "close"

    status_line = f"HTTP/1.1 {status} {_reason(status)}\r\n"
    head = status_line + "".join(f"{k}: {v}\r\n" for k, v in headers.items()) + "\r\n"
    return head.encode("utf-8") + body


def _recv_until(sock: socket.socket, marker: bytes, max_bytes: int = 64 * 1024) -> bytes:
    """
    Lee del socket hasta encontrar marker o llegar al límite.
    """
    data = b""
    while marker not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > max_bytes:
            raise ValueError("header too large")
    return data


def parse_http_request(sock: socket.socket) -> tuple[str, str, dict, bytes]:
    """
    Parseo HTTP MUY simple:
    - Lee headers hasta \r\n\r\n
    - Parsea request line
    - Parsea headers
    - Si hay Content-Length, lee el body completo
    Devuelve: (method, path, headers_dict, body_bytes)
    """
    raw = _recv_until(sock, b"\r\n\r\n", max_bytes=128 * 1024)
    if b"\r\n\r\n" not in raw:
        raise ValueError("incomplete headers")

    head, rest = raw.split(b"\r\n\r\n", 1)
    lines = head.split(b"\r\n")
    if not lines:
        raise ValueError("empty request")

    # Request line: METHOD SP PATH SP HTTP/1.1
    req_line = lines[0].decode("iso-8859-1", errors="replace")
    parts = req_line.split()
    if len(parts) < 2:
        raise ValueError("bad request line")

    method = parts[0].upper()
    path = parts[1]

    headers: dict[str, str] = {}
    for ln in lines[1:]:
        s = ln.decode("iso-8859-1", errors="replace")
        if ":" in s:
            k, v = s.split(":", 1)
            headers[k.strip()] = v.strip()

    # Body
    body = b""
    content_length = headers.get("Content-Length") or headers.get("content-length")
    if content_length:
        try:
            n = int(content_length)
        except ValueError:
            raise ValueError("bad content-length")

        if n > 2 * 1024 * 1024:
            # evita DoS tonto
            raise ValueError("payload too large")

        body = rest
        while len(body) < n:
            chunk = sock.recv(min(4096, n - len(body)))
            if not chunk:
                break
            body += chunk
        body = body[:n]

    return method, path, headers, body


def client_ip_from_headers(headers: dict, peer_ip: str) -> str:
    # Si viene de nginx, usa X-Real-IP / X-Forwarded-For; si no, peer_ip
    real_ip = headers.get("X-Real-IP") or headers.get("x-real-ip")
    if real_ip:
        return real_ip.strip()
    fwd = headers.get("X-Forwarded-For") or headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    return peer_ip


def parse_form_urlencoded(body: bytes) -> dict:
    # body: b"username=...&password=..."
    raw = body.decode("utf-8", errors="ignore")
    return parse_qs(raw)


def handle_static(path: str) -> tuple[int, dict, bytes]:
    rel = path[len("/static/") :]
    # Evita traversal básico
    if ".." in rel or "\\" in rel:
        return 404, {}, b"Not Found"

    file_path = STATIC_ROOT / rel
    if not file_path.is_file():
        return 404, {}, b"Not Found"

    ctype, _ = mimetypes.guess_type(str(file_path))
    if not ctype:
        ctype = "application/octet-stream"
    data = file_path.read_bytes()
    return 200, {"Content-Type": ctype}, data


def require_admin(headers: dict) -> tuple[bool, bytes]:
    auth_header = headers.get("Authorization") or headers.get("authorization")
    creds = auth.parse_basic_auth(auth_header)
    if not creds or not auth.is_admin(*creds):
        body = b"Administracion - autenticacion requerida"
        resp = build_response(
            401,
            {
                "WWW-Authenticate": 'Basic realm="Admin"',
                "Content-Type": "text/plain; charset=utf-8",
            },
            body,
        )
        return False, resp
    return True, b""


# ----------------------------
# Router (manual)
# ----------------------------

def route_request(method: str, raw_path: str, headers: dict, body: bytes, peer_ip: str) -> bytes:
    parsed = urlparse(raw_path)
    path = parsed.path
    client_ip = client_ip_from_headers(headers, peer_ip)

    log(f"{method} {path} from {client_ip}")

    # STATIC
    if path.startswith("/static/") and method in ("GET", "HEAD"):
        st, h, b = handle_static(path)
        if method == "HEAD":
            b = b""
        return build_response(st, h, b)

    # GET
    if method == "GET":
        if path in ("/", "/login"):
            html_body = portal.render_login_page(
                client_ip=client_ip,
                auth_timeout=AUTH_TIMEOUT,
                error=None,
            ).encode("utf-8")
            return build_response(200, {"Content-Type": "text/html; charset=utf-8"}, html_body)

        if path == "/status":
            html_body = portal.render_status_page().encode("utf-8")
            return build_response(200, {"Content-Type": "text/html; charset=utf-8"}, html_body)

        if path == "/status.json":
            data = portal.get_status_json(client_ip)
            out = json.dumps(data).encode("utf-8")
            return build_response(200, {"Content-Type": "application/json; charset=utf-8"}, out)

        if path in ("/admin", "/admin/"):
            return build_response(302, {"Location": "/admin/users"}, b"")

        if path == "/admin/users":
            ok, resp = require_admin(headers)
            if not ok:
                return resp
            # usuario admin para mostrar
            admin_user = "admin"
            html_body = admin_module.render_admin_page(admin_user=admin_user, message=None).encode("utf-8")
            return build_response(200, {"Content-Type": "text/html; charset=utf-8"}, html_body)

        return build_response(404, {}, b"Not Found")

    # HEAD (reusa lógica GET pero sin body)
    if method == "HEAD":
        resp = route_request("GET", raw_path, headers, b"", peer_ip)
        # quitar body manteniendo headers/content-length correcto (0)
        # reconstruimos: parsear hasta \r\n\r\n
        head = resp.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"
        # Ajustar Content-Length a 0 (por seguridad)
        # Más simple: volver a construir desde status line+headers no es trivial sin parseo.
        # Para tu portal no hace falta perfecto; pero lo dejamos consistente:
        # hack: reemplazar Content-Length: N por 0 si aparece.
        head = head.replace(b"Content-Length: ", b"Content-Length: ")
        if b"Content-Length:" in head:
            lines = head.split(b"\r\n")
            new_lines = []
            for ln in lines:
                if ln.lower().startswith(b"content-length:"):
                    new_lines.append(b"Content-Length: 0")
                else:
                    new_lines.append(ln)
            head = b"\r\n".join(new_lines)
        return head  # sin body

    # POST
    if method == "POST":
        if path == "/login":
            form = parse_form_urlencoded(body)
            status, hdrs, body_text = portal.process_login(client_ip, form)
            hdrs = dict(hdrs or {})
            if status == 302 and "Location" not in hdrs:
                hdrs["Location"] = "/status"
            return build_response(status, hdrs, (body_text or "").encode("utf-8"))

        if path in ("/admin/users/create", "/admin/users/delete"):
            ok, resp = require_admin(headers)
            if not ok:
                return resp

            form = parse_form_urlencoded(body)
            msg = None
            if path == "/admin/users/create":
                username = (form.get("username") or [""])[0]
                password = (form.get("password") or [""])[0]
                msg = admin_module.handle_create_user(username, password)
            else:
                username = (form.get("username") or [""])[0]
                msg = admin_module.handle_delete_user(username)

            html_body = admin_module.render_admin_page(admin_user="admin", message=msg).encode("utf-8")
            return build_response(200, {"Content-Type": "text/html; charset=utf-8"}, html_body)

        if path == "/logout":
            status, hdrs, body_text = portal.process_logout(client_ip)
            return build_response(status, dict(hdrs or {}), (body_text or "").encode("utf-8"))

        return build_response(404, {}, b"Not Found")

    return build_response(405, {}, b"Method Not Allowed")


# ----------------------------
# Thread pool server (manual)
# ----------------------------

class ManualThreadPoolHTTPServer:
    """
    Servidor TCP manual + HTTP parse manual:
    - accept() en hilo principal
    - pone (client_socket, client_addr) en cola FIFO
    - N workers procesan: parse HTTP -> route -> send -> close
    """

    def __init__(self, host: str, port: int, *, workers: int = 10, queue_size: int = 0):
        self.host = host
        self.port = port
        self.workers = workers
        self._q = queue.Queue(maxsize=queue_size) if queue_size and queue_size > 0 else queue.Queue()
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._sock: socket.socket | None = None

    def start(self):
        # Crear socket servidor
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.host, self.port))
        srv.listen(128)
        self._sock = srv

        # Workers
        for i in range(self.workers):
            t = threading.Thread(target=self._worker_loop, name=f"cp-worker-{i+1}", daemon=True)
            t.start()
            self._threads.append(t)

        log(f"Servidor TCP(HTTP) manual escuchando en {self.host}:{self.port} (pool={self.workers})")

        # Accept loop (hilo principal)
        try:
            while not self._stop.is_set():
                client_sock, client_addr = srv.accept()
                # Backpressure: si cola llena, accept sigue aceptando,
                # pero put() bloqueará y frenará el loop.
                self._q.put((client_sock, client_addr))
        except KeyboardInterrupt:
            log("Servidor detenido por KeyboardInterrupt")
        finally:
            self.stop()

    def stop(self):
        self._stop.set()
        if self._sock:
            try:
                self._sock.close()
            except Exception:
                pass

        # Despertar workers
        for _ in self._threads:
            self._q.put(None)

        for t in self._threads:
            t.join(timeout=1.0)

    def _worker_loop(self):
        while not self._stop.is_set():
            item = self._q.get()
            if item is None:
                self._q.task_done()
                break

            client_sock, client_addr = item
            peer_ip = client_addr[0]

            try:
                client_sock.settimeout(5.0)
                method, path, headers, body = parse_http_request(client_sock)
                resp = route_request(method, path, headers, body, peer_ip)
            except ValueError as e:
                # headers demasiado grandes / malformado / payload grande
                msg = str(e).encode("utf-8", errors="ignore")
                if b"payload too large" in msg:
                    resp = build_response(413, {}, b"Payload Too Large")
                else:
                    resp = build_response(400, {}, b"Bad Request")
            except Exception as e:
                resp = build_response(500, {}, b"Internal Server Error")
            finally:
                try:
                    client_sock.sendall(resp)
                except Exception:
                    pass
                try:
                    client_sock.close()
                except Exception:
                    pass
                self._q.task_done()


def run_server(port: int) -> None:
    srv = ManualThreadPoolHTTPServer("0.0.0.0", port, workers=10)
    srv.start()


if __name__ == "__main__":
    env_port = os.getenv("PORTAL_PORT")
    if env_port:
        port = int(env_port)
    elif len(sys.argv) >= 2:
        port = int(sys.argv[1])
    else:
        port = 8080
    run_server(port)
