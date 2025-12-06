# app/ipset_utils.py
import subprocess
from .config import AUTH_TIMEOUT

def add_to_ipset(ip: str) -> bool:
    """Añade la IP al conjunto 'authed' con timeout."""
    try:
        subprocess.run(
            ["ipset", "add", "authed", ip, "timeout", str(AUTH_TIMEOUT), "-exist"],
            check=True,
        )
        return True
    except Exception as e:
        print(f"Error añadiendo {ip} a ipset: {e}")
        return False


def check_ipset(ip: str) -> bool:
    """Devuelve True si la IP está actualmente en el ipset 'authed'."""
    try:
        res = subprocess.run(
            ["ipset", "test", "authed", ip],
            capture_output=True,
        )
        return res.returncode == 0
    except Exception as e:
        print(f"Error comprobando ipset para {ip}: {e}")
        return False


def remove_from_ipset(ip: str) -> bool:
    """Elimina la IP del conjunto 'authed' (logout)."""
    try:
        subprocess.run(
            ["ipset", "del", "authed", ip],
            check=True,
        )
        return True
    except Exception as e:
        print(f"Error eliminando {ip} de ipset: {e}")
        return False


def get_remaining_timeout(ip: str) -> int:
    """
    Obtiene el tiempo restante en segundos para una IP en el ipset.
    Devuelve 0 si la IP no está en el conjunto o hay error.
    """
    try:
        res = subprocess.run(
            ["ipset", "list", "authed"],
            capture_output=True,
            text=True,
        )
        if res.returncode != 0:
            return 0
        # Buscar línea con la IP y extraer timeout
        # Formato: "192.168.100.2 timeout 3542"
        for line in res.stdout.splitlines():
            if ip in line and "timeout" in line:
                parts = line.split()
                try:
                    idx = parts.index("timeout")
                    return int(parts[idx + 1])
                except (ValueError, IndexError):
                    pass
        return 0
    except Exception as e:
        print(f"Error obteniendo timeout para {ip}: {e}")
        return 0
