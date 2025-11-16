# app/routers/portal.py
from fastapi import APIRouter, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.templating import Jinja2Templates

from ..ipset_utils import add_to_ipset, check_ipset
from ..users import load_users
from ..config import AUTH_TIMEOUT

router = APIRouter(tags=["portal"])

# Directorio de templates
templates = Jinja2Templates(directory="app/templates")


@router.get("/", response_class=HTMLResponse)
@router.get("/login", response_class=HTMLResponse)
async def login_form(request: Request):
    client_ip = request.client.host
    return templates.TemplateResponse(
        "login.html",
        {
            "request": request,
            "error": None,
            "client_ip": client_ip,
            "auth_timeout": AUTH_TIMEOUT,
        },
    )


@router.post("/login", response_class=HTMLResponse)
async def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    client_ip = request.client.host
    _, mapping = load_users()
    stored = mapping.get(username)

    if stored is None or stored != password:
        return templates.TemplateResponse(
            "login.html",
            {
                "request": request,
                "error": "Credenciales inválidas. Verifica usuario y contraseña.",
                "client_ip": client_ip,
                "auth_timeout": AUTH_TIMEOUT,
            },
            status_code=401,
        )

    ok = add_to_ipset(client_ip)
    if not ok:
        # Error de servidor al añadir al ipset
        return HTMLResponse(
            "Autenticado, pero no se pudo registrar tu IP en el portal. "
            "Contacta con el administrador.",
            status_code=500,
        )

    return RedirectResponse(url="/status", status_code=302)


@router.get("/status", response_class=HTMLResponse)
async def status_page(request: Request):
    client_ip = request.client.host
    authed = check_ipset(client_ip)
    return templates.TemplateResponse(
        "status.html",
        {
            "request": request,
            "client_ip": client_ip,
            "authenticated": authed,
            "auth_timeout": AUTH_TIMEOUT,
        },
    )


@router.get("/status.json")
async def status_json(request: Request):
    client_ip = request.client.host
    authed = check_ipset(client_ip)
    return JSONResponse(
        {
            "client_ip": client_ip,
            "authenticated": authed,
            "expires_in_seconds": AUTH_TIMEOUT,
        }
    )
