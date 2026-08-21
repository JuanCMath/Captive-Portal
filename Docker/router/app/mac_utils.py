# app/mac_utils.py
"""
Resolución de la MAC de un cliente LAN a partir de su IP.

Se usa la tabla de vecinos del propio kernel (ARP/NDP) en vez de mantener
estado en la aplicación: para que un cliente le hable por TCP al router
(login), el kernel ya tuvo que resolver su MAC vía ARP, así que la entrada
ya existe en el momento del login tanto en el bridge Docker como en una LAN
nativa real (el router es siempre el salto L2 inmediato del cliente).
"""
import re
import subprocess
from typing import Optional

_MAC_RE = re.compile(r"([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})")
_BAD_STATES = ("FAILED", "INCOMPLETE")


def get_mac_for_ip(ip: str) -> Optional[str]:
    """Devuelve la MAC (minúsculas) asociada a `ip` según `ip neigh`, o None."""
    try:
        res = subprocess.run(
            ["ip", "neigh", "show", ip],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except Exception as e:
        print(f"Error resolviendo MAC para {ip}: {e}")
        return None

    for line in res.stdout.splitlines():
        if any(state in line for state in _BAD_STATES):
            continue
        m = _MAC_RE.search(line)
        if m:
            return m.group(1).lower()
    return None
