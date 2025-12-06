# app/config.py
import os
from pathlib import Path

# Tiempo que una IP permanece autenticada en ipset (segundos)
AUTH_TIMEOUT = int(os.getenv("AUTH_TIMEOUT", "3600"))

def _detect_users_file() -> Path:
    """
    Detecta la ubicación del archivo de usuarios según el entorno:
    1. Variable de entorno USERS_FILE (máxima prioridad)
    2. /app/app/users.json (Docker)
    3. Directorio del script + users.json (Linux nativo)
    """
    # Prioridad 1: Variable de entorno explícita
    env_path = os.getenv("USERS_FILE")
    if env_path:
        return Path(env_path)
    
    # Prioridad 2: Ruta Docker (si existe)
    docker_path = Path("/app/app/users.json")
    if docker_path.parent.exists():
        return docker_path
    
    # Prioridad 3: Ruta relativa al script (Linux nativo)
    return Path(__file__).resolve().parent / "users.json"

# Ubicación del archivo de usuarios (detección automática)
USERS_FILE = _detect_users_file()
