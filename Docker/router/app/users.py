# app/users.py
import json
import os
import threading
from typing import List, Dict, Tuple

from .config import USERS_FILE

# Lock global: protege operaciones críticas de lectura+escritura del users.json
_USERS_LOCK = threading.Lock()


def _load_from_env() -> List[Dict[str, str]]:
    """
    Permite definir usuarios vía variable de entorno USERS_JSON.
    Debe ser una lista: [{"u":"user","p":"pass"}, ...]
    """
    env_json = os.getenv("USERS_JSON")
    if not env_json:
        return []

    try:
        data = json.loads(env_json)
        if isinstance(data, list):
            return data
    except Exception:
        pass

    return []


def load_users() -> Tuple[List[Dict[str, str]], Dict[str, str]]:
    """
    Carga usuarios desde:
      1) USERS_JSON (si existe)
      2) Archivo USERS_FILE
      3) Fallback: admin/admin

    Devuelve:
      (lista_de_usuarios, mapping_usuario->password)

    Donde cada usuario es {"u": "...", "p": "..."}.
    """
    data = _load_from_env()

    if not data:
        if USERS_FILE.exists():
            try:
                data = json.loads(USERS_FILE.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                print("users.json mal formado, usando fallback.")
                data = []
        if not data:
            data = [{"u": "admin", "p": "admin"}]

    cleaned: List[Dict[str, str]] = []
    mapping: Dict[str, str] = {}

    for item in data:
        if not isinstance(item, dict):
            continue
        u = item.get("u")
        p = item.get("p")

        if not u or p is None:
            continue

        u = str(u)
        p = str(p)

        cleaned.append({"u": u, "p": p})
        mapping[u] = p  # <- IMPORTANTÍSIMO: password como string

    return cleaned, mapping


def save_users(users_list: List[Dict[str, str]]) -> None:
    """
    Guarda la lista de usuarios en USERS_FILE.
    NOTA: debe llamarse desde una sección protegida por _USERS_LOCK
    cuando el server está en multihilo.
    """
    USERS_FILE.parent.mkdir(parents=True, exist_ok=True)
    USERS_FILE.write_text(
        json.dumps(users_list, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )


def create_user(username: str, password: str) -> Tuple[bool, str]:
    username = username.strip()

    if not username or " " in username:
        return False, "El nombre de usuario no puede estar vacío ni contener espacios."

    with _USERS_LOCK:
        users, mapping = load_users()
        if username in mapping:
            return False, f"El usuario '{username}' ya existe."

        users.append({"u": username, "p": str(password)})
        save_users(users)

    return True, f"Usuario '{username}' creado correctamente."


def delete_user(username: str) -> Tuple[bool, str]:
    username = username.strip()

    with _USERS_LOCK:
        users, mapping = load_users()

        if username == "admin":
            return False, "No se puede eliminar la cuenta 'admin'."

        if username not in mapping:
            return False, f"El usuario '{username}' no existe."

        new_users = [u for u in users if u.get("u") != username]
        save_users(new_users)

    return True, f"Usuario '{username}' eliminado correctamente."
