# app/routers/admin.py
from fastapi import APIRouter, Form, Depends, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from ..auth import get_admin
from ..users import load_users, create_user, delete_user
from ..config import AUTH_TIMEOUT

router = APIRouter(prefix="/admin", tags=["admin"])
templates = Jinja2Templates(directory="app/templates")


@router.get("/users", response_class=HTMLResponse)
async def admin_users(
    request: Request,
    admin_user: str = Depends(get_admin),
):
    users_list, _ = load_users()
    return templates.TemplateResponse(
        "admin.html",
        {
            "request": request,
            "users": users_list,
            "message": None,
            "auth_timeout": AUTH_TIMEOUT,
            "admin_user": admin_user,
        },
    )


@router.post("/users/create", response_class=HTMLResponse)
async def admin_create_user(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    admin_user: str = Depends(get_admin),
):
    ok, msg = create_user(username, password)
    users_list, _ = load_users()
    return templates.TemplateResponse(
        "admin.html",
        {
            "request": request,
            "users": users_list,
            "message": msg,
            "auth_timeout": AUTH_TIMEOUT,
            "admin_user": admin_user,
        },
    )


@router.post("/users/delete", response_class=HTMLResponse)
async def admin_delete_user(
    request: Request,
    username: str = Form(...),
    admin_user: str = Depends(get_admin),
):
    ok, msg = delete_user(username)
    users_list, _ = load_users()
    return templates.TemplateResponse(
        "admin.html",
        {
            "request": request,
            "users": users_list,
            "message": msg,
            "auth_timeout": AUTH_TIMEOUT,
            "admin_user": admin_user,
        },
    )
