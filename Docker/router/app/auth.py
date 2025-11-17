# app/auth.py
"""
Autenticación HTTP Basic para el panel de administración,
sin dependencias externas (solo librerías estándar).
"""

import base64
from typing import Optional, Tuple

from .users import load_users


def parse_basic_auth(header_value: Optional[str]) -> Optional[Tuple[str, str]]:
    """
    Parsea un encabezado Authorization: Basic ...

    Devuelve (username, password) o None si no es válido.
    """
    if not header_value:
        return None
    if not header_value.startswith("Basic "):
        return None
    try:
        b64_part = header_value.split(" ", 1)[1].strip()
        decoded = base64.b64decode(b64_part).decode("utf-8")
        if ":" not in decoded:
            return None
        username, password = decoded.split(":", 1)
        return username, password
    except Exception:
        return None


def is_admin(username: str, password: str) -> bool:
    """
    Comprueba si las credenciales corresponden al usuario 'admin'
    definido en users.json o en USERS_JSON.
    """
    _, mapping = load_users()
    stored = mapping.get(username)
    return username == "admin" and stored is not None and stored == password
