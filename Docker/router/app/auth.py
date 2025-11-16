# app/auth.py
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi import Depends, HTTPException
from .users import load_users

security = HTTPBasic()

def get_admin(credentials: HTTPBasicCredentials = Depends(security)) -> str:
    """
    Autenticación HTTP Basic para el panel admin.
    Solo permite el usuario 'admin' definido en users.json o USERS_JSON.
    """
    _, mapping = load_users()
    password = mapping.get(credentials.username)

    if credentials.username != "admin" or password != credentials.password:
        raise HTTPException(
            status_code=401,
            detail="Credenciales de administrador inválidas",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username
