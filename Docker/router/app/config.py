# app/config.py
import os
from pathlib import Path

# Tiempo que una IP permanece autenticada en ipset (segundos)
AUTH_TIMEOUT = int(os.getenv("AUTH_TIMEOUT", "3600"))

# Ubicación del archivo de usuarios dentro del contenedor
USERS_FILE = Path("/app/app/users.json")
