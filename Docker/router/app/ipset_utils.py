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
