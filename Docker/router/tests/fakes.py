"""
Doble de prueba para subprocess.run, compartido por los tests que ejercitan
código que llama a `ip neigh` / `ipset`. Reproduce el formato de salida real
de esas herramientas (comprobado contra Docker real), incluyendo que `ipset
list` normaliza la MAC a MAYÚSCULAS sin importar en qué formato se insertó
-- el origen de un bug real encontrado en pruebas end-to-end.
"""
import subprocess
from unittest.mock import MagicMock, patch


class FakeSystem:
    def __init__(self):
        # ip -> (mac, estado tal como lo reportaría "ip neigh show")
        self.neigh: dict[str, tuple[str, str]] = {}
        # "ip,mac" en minúsculas -> timeout en segundos
        self.ipset_members: dict[str, int] = {}
        self.calls: list[list[str]] = []
        self.ipset_add_fails = False
        self.ipset_del_fails = False
        self.ipset_list_fails = False

    # ---- helpers de configuración ----

    def set_neigh(self, ip: str, mac: str | None, state: str = "REACHABLE") -> None:
        """mac=None simula una entrada sin lladdr resuelto (INCOMPLETE/FAILED)."""
        self.neigh[ip] = (mac, state)

    def clear_neigh(self, ip: str) -> None:
        self.neigh.pop(ip, None)

    def seed_authed(self, ip: str, mac: str, timeout: int) -> None:
        """Da de alta una sesión directamente, sin pasar por 'ipset add'."""
        self.ipset_members[f"{ip},{mac}".lower()] = timeout

    def patch_subprocess(self):
        return patch("subprocess.run", side_effect=self._run)

    # ---- doble de subprocess.run ----

    def _run(self, cmd, **kwargs):
        self.calls.append(list(cmd))
        res = MagicMock()
        res.returncode = 0
        res.stdout = ""

        if cmd[:3] == ["ip", "neigh", "show"]:
            res.stdout = self._neigh_output(cmd[3])
            return res

        if cmd and cmd[0] == "ipset":
            return self._ipset(cmd, res)

        raise AssertionError(f"comando no soportado por FakeSystem: {cmd}")

    def _neigh_output(self, ip: str) -> str:
        if ip not in self.neigh:
            return ""
        mac, state = self.neigh[ip]
        if mac is None:
            return f"{ip} dev eth1  {state}\n"
        return f"{ip} dev eth1 lladdr {mac} {state}\n"

    def _ipset(self, cmd, res):
        action = cmd[1]

        if action == "add":
            if self.ipset_add_fails:
                raise subprocess.CalledProcessError(1, cmd)
            member, timeout = cmd[3], cmd[5]
            self.ipset_members[member.lower()] = int(timeout)
            return res

        if action == "del":
            if self.ipset_del_fails:
                raise subprocess.CalledProcessError(1, cmd)
            member = cmd[3].lower()
            if member not in self.ipset_members:
                raise subprocess.CalledProcessError(1, cmd)
            del self.ipset_members[member]
            return res

        if action == "test":
            member = cmd[3].lower()
            res.returncode = 0 if member in self.ipset_members else 1
            return res

        if action == "list":
            if self.ipset_list_fails:
                res.returncode = 1
                return res
            res.stdout = self._list_output()
            return res

        raise AssertionError(f"subcomando ipset no soportado: {cmd}")

    def _list_output(self) -> str:
        lines = [
            "Name: authed",
            "Type: hash:ip,mac",
            "Header: family inet hashsize 1024 maxelem 65536",
            "Members:",
        ]
        for member, timeout in self.ipset_members.items():
            ip, mac = member.split(",", 1)
            # Real, no cosmético: ipset devuelve la MAC en mayúsculas al
            # listar, sin importar el formato con el que se insertó.
            lines.append(f"{ip},{mac.upper()} timeout {timeout}")
        return "\n".join(lines) + "\n"
