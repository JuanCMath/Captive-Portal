# app/ipset_utils.py
import subprocess
from typing import Optional
from .config import AUTH_TIMEOUT


def add_to_ipset(ip: str, mac: str) -> bool:
    """Añade el par IP,MAC al conjunto 'authed' con timeout."""
    try:
        subprocess.run(
            ["ipset", "add", "authed", f"{ip},{mac}", "timeout", str(AUTH_TIMEOUT), "-exist"],
            check=True,
        )
        return True
    except Exception as e:
        print(f"Error añadiendo {ip},{mac} a ipset: {e}")
        return False


def check_ipset(ip: str, mac: str) -> bool:
    """Devuelve True si el par IP,MAC está actualmente en el ipset 'authed'."""
    try:
        res = subprocess.run(
            ["ipset", "test", "authed", f"{ip},{mac}"],
            capture_output=True,
        )
        return res.returncode == 0
    except Exception as e:
        print(f"Error comprobando ipset para {ip},{mac}: {e}")
        return False


def remove_from_ipset(ip: str, mac: str) -> bool:
    """Elimina el par IP,MAC del conjunto 'authed' (logout)."""
    try:
        subprocess.run(
            ["ipset", "del", "authed", f"{ip},{mac}"],
            check=True,
        )
        return True
    except Exception as e:
        print(f"Error eliminando {ip},{mac} de ipset: {e}")
        return False


def remove_from_ipset_by_ip(ip: str) -> bool:
    """
    Elimina cualquier entrada de 'authed' cuya IP sea `ip`, sin conocer la
    MAC. Fallback de logout para cuando el dispositivo ya no está en la
    tabla de vecinos (por ejemplo, se desconectó) y por tanto no se puede
    componer el miembro exacto "ip,mac" para borrarlo directamente.
    """
    try:
        res = subprocess.run(
            ["ipset", "list", "authed"],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            return False

        removed_any = False
        prefix = f"{ip},"
        for line in res.stdout.splitlines():
            member = line.strip().split()[0] if line.strip() else ""
            if member.startswith(prefix):
                del_res = subprocess.run(
                    ["ipset", "del", "authed", member],
                    capture_output=True,
                )
                if del_res.returncode == 0:
                    removed_any = True
        return removed_any
    except Exception as e:
        print(f"Error eliminando entradas de {ip} en ipset: {e}")
        return False


def get_remaining_timeout(ip: str, mac: str) -> int:
    """
    Obtiene el tiempo restante en segundos para el par IP,MAC en el ipset.
    Devuelve 0 si no está en el conjunto o hay error.
    """
    try:
        res = subprocess.run(
            ["ipset", "list", "authed"],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            return 0
        # Formato de línea: "192.168.100.2,aa:bb:cc:dd:ee:ff timeout 3542"
        target = f"{ip},{mac}"
        for line in res.stdout.splitlines():
            parts = line.split()
            if not parts or parts[0] != target:
                continue
            if "timeout" in parts:
                try:
                    idx = parts.index("timeout")
                    return int(parts[idx + 1])
                except (ValueError, IndexError):
                    pass
        return 0
    except Exception as e:
        print(f"Error obteniendo timeout para {ip},{mac}: {e}")
        return 0
