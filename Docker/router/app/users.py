# app/users.py
import hashlib
import hmac
import json
import os
import secrets
import threading
from pathlib import Path
from typing import List, Dict, Tuple

from .config import USERS_FILE

# Lock global: protege operaciones críticas de lectura+escritura del users.json
_USERS_LOCK = threading.Lock()

# ----------------------------
# Hash de contraseñas (PBKDF2-HMAC-SHA256, solo librería estándar)
# ----------------------------

_PBKDF2_ALGO = "pbkdf2_sha256"
_PBKDF2_ITERATIONS = 260_000

# Salt fijo usado únicamente para "quemar" tiempo de CPU cuando el usuario
# no existe, y así no filtrar por temporización si una cuenta existe o no.
_DUMMY_SALT = secrets.token_bytes(16)


def _hash_password(password: str, *, salt: bytes | None = None) -> str:
    if salt is None:
        salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, _PBKDF2_ITERATIONS)
    return f"{_PBKDF2_ALGO}${_PBKDF2_ITERATIONS}${salt.hex()}${dk.hex()}"


def _is_hashed(value: str) -> bool:
    return value.startswith(f"{_PBKDF2_ALGO}$")


def _verify_password(password: str, stored: str) -> bool:
    """Verifica una contraseña contra el valor almacenado.

    Soporta el formato con hash (pbkdf2_sha256$iteraciones$salt$hash, en
    hexadecimal) y, por compatibilidad con archivos users.json antiguos,
    contraseñas en texto plano (comparación en tiempo constante). Las
    entradas en texto plano se migran automáticamente a hash tras el primer
    login correcto (ver check_credentials).
    """
    if _is_hashed(stored):
        try:
            _algo, iterations_s, salt_hex, hash_hex = stored.split("$", 3)
            iterations = int(iterations_s)
            salt = bytes.fromhex(salt_hex)
            expected = bytes.fromhex(hash_hex)
        except (ValueError, IndexError):
            return False
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
        return hmac.compare_digest(dk, expected)

    return hmac.compare_digest(stored.encode("utf-8"), password.encode("utf-8"))


# ----------------------------
# Carga / persistencia
# ----------------------------

def _load_from_env() -> List[Dict[str, str]]:
    """
    Permite definir usuarios vía variable de entorno USERS_JSON.
    Debe ser una lista: [{"u":"user","p":"pass_o_hash"}, ...]
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


def _write_initial_password_notice(password: str) -> None:
    msg = (
        "\n"
        "============================================================\n"
        " Portal cautivo: credenciales de administrador generadas\n"
        "   Usuario:     admin\n"
        f"   Contraseña:  {password}\n"
        " Guarda esta contraseña ahora; no se volverá a mostrar por\n"
        " consola. Cámbiala desde /admin/users en cuanto puedas.\n"
        "============================================================\n"
    )
    print(msg, flush=True)
    try:
        notice_path = USERS_FILE.parent / "admin_password_initial.txt"
        notice_path.write_text(
            "usuario: admin\n"
            f"contraseña: {password}\n"
            "Este archivo se genera una sola vez, en el primer arranque.\n"
            "Bórralo en cuanto hayas anotado la contraseña en un lugar seguro.\n",
            encoding="utf-8",
        )
        try:
            os.chmod(notice_path, 0o600)
        except OSError:
            pass
    except OSError as e:
        print(f"[users] no se pudo escribir el aviso de contraseña inicial: {e}", flush=True)


def _bootstrap_admin_if_needed() -> None:
    """Si no existe ni USERS_JSON ni el archivo de usuarios, crea la cuenta
    'admin' con una contraseña aleatoria segura, en vez de usar credenciales
    fijas y predecibles (admin/admin). Solo ocurre una vez, en el primer
    arranque del portal en una instalación nueva.
    """
    if os.getenv("USERS_JSON"):
        return
    if USERS_FILE.exists():
        return

    with _USERS_LOCK:
        if USERS_FILE.exists():  # doble verificación tras adquirir el lock
            return
        password = secrets.token_urlsafe(15)
        users = [{"u": "admin", "p": _hash_password(password)}]
        save_users(users)
        _write_initial_password_notice(password)


def load_users() -> Tuple[List[Dict[str, str]], Dict[str, str]]:
    """
    Carga usuarios desde:
      1) USERS_JSON (si existe)
      2) Archivo USERS_FILE (se crea automáticamente con admin/<contraseña
         aleatoria> si no existe ninguna fuente de usuarios)

    Devuelve:
      (lista_de_usuarios, mapping_usuario->password_o_hash)

    Donde cada usuario es {"u": "...", "p": "..."}.
    """
    data = _load_from_env()

    if not data:
        _bootstrap_admin_if_needed()
        if USERS_FILE.exists():
            try:
                data = json.loads(USERS_FILE.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                print("users.json mal formado, usando fallback.", flush=True)
                data = []
        if not data:
            # Último recurso (p.ej. no se pudo escribir el bootstrap por
            # permisos): admin/admin con aviso explícito para no dejar el
            # sistema totalmente inaccesible.
            print(
                "[users] ADVERTENCIA: no se pudo generar una contraseña de "
                "administrador segura; usando admin/admin de EMERGENCIA. "
                "Cámbiala de inmediato desde /admin/users.",
                flush=True,
            )
            data = [{"u": "admin", "p": _hash_password("admin")}]

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
        mapping[u] = p  # <- password en texto plano o hash, según el registro

    return cleaned, mapping


def save_users(users_list: List[Dict[str, str]]) -> None:
    """
    Guarda la lista de usuarios en USERS_FILE de forma atómica (escribe a un
    archivo temporal y hace rename), para evitar corromper el archivo si el
    proceso se interrumpe a mitad de escritura. Restringe permisos a 600
    porque el archivo contiene hashes de contraseñas (y, en instalaciones
    migradas desde versiones antiguas, posiblemente texto plano hasta el
    primer login).

    NOTA: debe llamarse desde una sección protegida por _USERS_LOCK
    cuando el server está en multihilo.
    """
    USERS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = USERS_FILE.with_suffix(USERS_FILE.suffix + ".tmp")
    tmp_path.write_text(
        json.dumps(users_list, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    try:
        os.chmod(tmp_path, 0o600)
    except OSError:
        pass
    os.replace(tmp_path, USERS_FILE)


# ----------------------------
# Autenticación
# ----------------------------

def check_credentials(username: str, password: str) -> bool:
    """Verifica usuario/contraseña con comparación en tiempo constante.

    Si la cuenta existía con contraseña en texto plano (users.json de
    versiones anteriores) y la verificación es correcta, migra
    automáticamente esa contraseña a formato hasheado en disco.
    """
    _, mapping = load_users()
    stored = mapping.get(username)

    if stored is None:
        # Ejecutamos un hash "señuelo" para que el tiempo de respuesta no
        # revele si el usuario existe o no.
        _hash_password(password, salt=_DUMMY_SALT)
        return False

    ok = _verify_password(password, stored)

    if ok and not _is_hashed(stored):
        with _USERS_LOCK:
            users, _mapping = load_users()
            changed = False
            for u in users:
                if u.get("u") == username:
                    u["p"] = _hash_password(password)
                    changed = True
                    break
            if changed:
                save_users(users)

    return ok


# ----------------------------
# Gestión de cuentas (panel admin)
# ----------------------------

MIN_PASSWORD_LENGTH = int(os.getenv("MIN_PASSWORD_LENGTH", "8"))


def create_user(username: str, password: str) -> Tuple[bool, str]:
    username = username.strip()

    if not username or " " in username:
        return False, "El nombre de usuario no puede estar vacío ni contener espacios."

    if len(password) < MIN_PASSWORD_LENGTH:
        return False, f"La contraseña debe tener al menos {MIN_PASSWORD_LENGTH} caracteres."

    with _USERS_LOCK:
        users, mapping = load_users()
        if username in mapping:
            return False, f"El usuario '{username}' ya existe."

        users.append({"u": username, "p": _hash_password(password)})
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
