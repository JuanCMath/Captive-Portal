# app/main.py
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from .routers import portal, admin

app = FastAPI(title="Captive Portal")

# Rutas del portal y panel admin
app.include_router(portal.router)
app.include_router(admin.router)

# Servir archivos estáticos (CSS)
app.mount("/static", StaticFiles(directory="app/static"), name="static")
