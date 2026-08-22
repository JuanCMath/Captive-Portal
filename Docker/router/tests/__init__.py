"""
Batería de pruebas del backend del portal cautivo (solo librería estándar,
igual que el propio backend: unittest + unittest.mock, sin pytest).

Ejecutar desde Docker/router/:
    python -m unittest discover -s tests -v

Nada aquí toca ipset/iptables/nginx reales: subprocess.run se reemplaza por
un doble de prueba (ver tests/fakes.py) que reproduce el comportamiento real
observado en pruebas end-to-end contra Docker, incluida alguna rareza de
`ipset` (p.ej. que normaliza la MAC a mayúsculas al listarla) que causó un
bug real en su momento.
"""
import os
import tempfile

# audit_log() lee AUDIT_LOG_FILE en cada llamada (no al importar el módulo),
# así que basta con fijarlo aquí, antes de que se ejecute cualquier test,
# para que ningún test escriba dentro del propio repo.
_AUDIT_DIR = tempfile.mkdtemp(prefix="captive-portal-tests-audit-")
os.environ["AUDIT_LOG_FILE"] = os.path.join(_AUDIT_DIR, "audit.log")
