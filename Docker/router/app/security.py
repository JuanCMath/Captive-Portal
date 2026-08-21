# app/security.py
"""
Utilidades transversales de seguridad para el portal cautivo:

- CSRF: tokens sin estado (HMAC) ligados a la IP del cliente, para proteger
  los formularios de login y del panel de administración.
- Rate limiting: bloqueo temporal tras varios intentos fallidos de login o
  de autenticación de administrador (protección básica contra fuerza bruta).
- Auditoría: registro estructurado (JSON lines) de eventos de autenticación
  y de acciones administrativas, para trazabilidad/cumplimiento.

Todo implementado con la biblioteca estándar de Python, en línea con el
resto del proyecto.
"""

import base64
import hashlib
import hmac
import json
import os
import threading
import time
from pathlib import Path
from typing import Tuple

# ----------------------------
# CSRF (sin estado, ligado a IP)
# ----------------------------

_CSRF_SECRET = os.urandom(32)  # se regenera en cada arranque del proceso
_CSRF_TTL_SECONDS = 3600


_SHA256_DIGEST_SIZE = hashlib.sha256().digest_size  # 32 bytes, longitud fija


def issue_csrf_token(client_ip: str) -> str:
    """Genera un token CSRF firmado, válido durante _CSRF_TTL_SECONDS
    y atado a la IP del cliente que lo solicitó."""
    expires = int(time.time()) + _CSRF_TTL_SECONDS
    msg = f"{client_ip}:{expires}".encode("utf-8")
    sig = hmac.new(_CSRF_SECRET, msg, hashlib.sha256).digest()
    # sig tiene longitud fija (32 bytes): la concatenamos sin separador para
    # no depender de que ningún byte de sig coincida con un carácter
    # separador (con un separador de 1 byte, ~1 de cada 8 tokens sería
    # inválido solo por azar, ya que sig es aleatorio uniforme).
    return base64.urlsafe_b64encode(msg + sig).decode("ascii")


def verify_csrf_token(client_ip: str, token: str) -> bool:
    if not token:
        return False
    try:
        raw = base64.urlsafe_b64decode(token.encode("ascii"))
        if len(raw) <= _SHA256_DIGEST_SIZE:
            return False
        msg, sig = raw[:-_SHA256_DIGEST_SIZE], raw[-_SHA256_DIGEST_SIZE:]
        expected_sig = hmac.new(_CSRF_SECRET, msg, hashlib.sha256).digest()
        if not hmac.compare_digest(sig, expected_sig):
            return False
        ip_part, expires_part = msg.decode("utf-8").rsplit(":", 1)
        if ip_part != client_ip:
            return False
        if int(expires_part) < int(time.time()):
            return False
        return True
    except Exception:
        return False


# ----------------------------
# Rate limiting (fuerza bruta)
# ----------------------------

class RateLimiter:
    """Limitador simple en memoria: tras `max_attempts` fallos en una
    ventana de `window_seconds`, bloquea la clave (normalmente una IP)
    durante `lockout_seconds`.

    Nota: el estado vive en memoria del proceso. Es suficiente para un
    portal cautivo de una sola instancia (arquitectura actual), pero no
    se comparte entre réplicas si el servicio se escala horizontalmente.
    """

    def __init__(self, max_attempts: int, window_seconds: int, lockout_seconds: int):
        self.max_attempts = max_attempts
        self.window_seconds = window_seconds
        self.lockout_seconds = lockout_seconds
        self._lock = threading.Lock()
        self._attempts: dict[str, list[float]] = {}
        self._blocked_until: dict[str, float] = {}

    def is_blocked(self, key: str) -> Tuple[bool, int]:
        now = time.time()
        with self._lock:
            until = self._blocked_until.get(key, 0.0)
            if until > now:
                return True, int(until - now) + 1
            return False, 0

    def record_failure(self, key: str) -> None:
        now = time.time()
        with self._lock:
            attempts = [t for t in self._attempts.get(key, []) if now - t < self.window_seconds]
            attempts.append(now)
            if len(attempts) >= self.max_attempts:
                self._blocked_until[key] = now + self.lockout_seconds
                self._attempts[key] = []
            else:
                self._attempts[key] = attempts

    def record_success(self, key: str) -> None:
        with self._lock:
            self._attempts.pop(key, None)
            self._blocked_until.pop(key, None)


# Login del portal: 5 intentos por minuto, bloqueo de 2 minutos
login_limiter = RateLimiter(max_attempts=5, window_seconds=60, lockout_seconds=120)

# Panel de administración (HTTP Basic): más estricto, bloqueo de 5 minutos
admin_limiter = RateLimiter(max_attempts=5, window_seconds=60, lockout_seconds=300)


# ----------------------------
# Auditoría
# ----------------------------

_AUDIT_LOCK = threading.Lock()


def _audit_log_path() -> Path:
    env_path = os.getenv("AUDIT_LOG_FILE")
    if env_path:
        return Path(env_path)

    candidate = Path("/var/log/captive-portal/audit.log")
    if candidate.parent.exists() and os.access(candidate.parent, os.W_OK):
        return candidate

    # Entorno de desarrollo/pruebas sin permisos de root: log local junto a la app
    local_dir = Path(__file__).resolve().parent.parent / "logs"
    try:
        local_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    return local_dir / "audit.log"


def audit_log(event: str, **fields) -> None:
    """Registra un evento de auditoría (login, acciones de admin, etc.)
    como línea JSON. Nunca lanza excepción: un fallo de logging no debe
    tumbar el portal."""
    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "event": event,
        **fields,
    }
    line = json.dumps(entry, ensure_ascii=False)
    print(f"[audit] {line}", flush=True)
    try:
        path = _audit_log_path()
        with _AUDIT_LOCK:
            with path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
    except Exception as e:  # noqa: BLE001 - logging nunca debe romper el flujo
        print(f"[audit] no se pudo escribir el log en disco: {e}", flush=True)
