import unittest
from unittest.mock import patch

from app import portal, security
from .fakes import FakeSystem

IP = "10.200.0.5"
MAC = "aa:bb:cc:dd:ee:ff"
OTHER_MAC = "11:22:33:44:55:66"


def _reset_login_limiter():
    security.login_limiter._attempts = {}
    security.login_limiter._blocked_until = {}


class PortalTestCase(unittest.TestCase):
    def setUp(self):
        _reset_login_limiter()
        self.csrf = security.issue_csrf_token(IP)


class TestRenderLoginPage(unittest.TestCase):
    def test_embeds_csrf_token(self):
        html = portal.render_login_page(IP, 3600, csrf_token="tok123")
        self.assertIn('value="tok123"', html)

    def test_escapes_error_message(self):
        html = portal.render_login_page(
            IP, 3600, error="<script>alert(1)</script>", csrf_token="tok"
        )
        self.assertNotIn("<script>alert(1)</script>", html)
        self.assertIn("&lt;script&gt;", html)


class TestProcessLoginCsrfAndRateLimit(PortalTestCase):
    def test_missing_csrf_rejected(self):
        fs = FakeSystem()
        with fs.patch_subprocess():
            status, _headers, _body = portal.process_login(
                IP, {"username": ["alice"], "password": ["x"]}, csrf_token=None
            )
        self.assertEqual(status, 400)

    def test_invalid_csrf_rejected(self):
        fs = FakeSystem()
        with fs.patch_subprocess():
            status, _headers, _body = portal.process_login(
                IP, {"username": ["alice"], "password": ["x"]}, csrf_token="garbage"
            )
        self.assertEqual(status, 400)

    def test_rate_limited_after_max_failed_attempts(self):
        fs = FakeSystem()
        with fs.patch_subprocess(), patch("app.portal.check_credentials", return_value=False):
            for _ in range(security.login_limiter.max_attempts):
                csrf = security.issue_csrf_token(IP)
                portal.process_login(IP, {"username": ["alice"], "password": ["bad"]}, csrf)

            csrf = security.issue_csrf_token(IP)
            status, _headers, _body = portal.process_login(
                IP, {"username": ["alice"], "password": ["bad"]}, csrf
            )
        self.assertEqual(status, 429)

    def test_wrong_credentials_return_401(self):
        fs = FakeSystem()
        with fs.patch_subprocess(), patch("app.portal.check_credentials", return_value=False):
            status, _headers, _body = portal.process_login(
                IP, {"username": ["alice"], "password": ["bad"]}, self.csrf
            )
        self.assertEqual(status, 401)


class TestProcessLoginSuccess(PortalTestCase):
    def test_success_binds_ip_and_mac_in_ipset(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "REACHABLE")
        with fs.patch_subprocess(), patch("app.portal.check_credentials", return_value=True):
            status, headers, _body = portal.process_login(
                IP, {"username": ["alice"], "password": ["good"]}, self.csrf
            )
            self.assertEqual(status, 302)
            self.assertEqual(headers.get("Location"), "/status")
            self.assertTrue(portal.check_ipset(IP, MAC))

    def test_success_without_resolvable_mac_returns_503_and_does_not_authenticate(self):
        fs = FakeSystem()  # sin entrada en ip neigh
        with fs.patch_subprocess(), patch("app.portal.check_credentials", return_value=True):
            status, _headers, body = portal.process_login(
                IP, {"username": ["alice"], "password": ["good"]}, self.csrf
            )
        self.assertEqual(status, 503)
        self.assertIn("verificar tu dispositivo", body)
        self.assertEqual(len(fs.ipset_members), 0)

    def test_ipset_add_failure_returns_500(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "REACHABLE")
        fs.ipset_add_fails = True
        with fs.patch_subprocess(), patch("app.portal.check_credentials", return_value=True):
            status, _headers, _body = portal.process_login(
                IP, {"username": ["alice"], "password": ["good"]}, self.csrf
            )
        self.assertEqual(status, 500)


class TestStatusJson(unittest.TestCase):
    def test_authenticated_when_ip_and_mac_match(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "REACHABLE")
        fs.seed_authed(IP, MAC, timeout=3500)
        with fs.patch_subprocess():
            data = portal.get_status_json(IP)
        self.assertTrue(data["authenticated"])
        self.assertEqual(data["expires_in_seconds"], 3500)
        self.assertEqual(data["client_ip"], IP)

    def test_not_authenticated_when_mac_does_not_match(self):
        # El caso que motivó todo el cambio: otro dispositivo (MAC distinta)
        # que ahora tiene la IP que estaba autenticada no debe heredar la
        # sesión.
        fs = FakeSystem()
        fs.set_neigh(IP, OTHER_MAC, "REACHABLE")
        fs.seed_authed(IP, MAC, timeout=3500)
        with fs.patch_subprocess():
            data = portal.get_status_json(IP)
        self.assertFalse(data["authenticated"])
        self.assertEqual(data["expires_in_seconds"], 0)

    def test_not_authenticated_when_mac_unresolvable(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3500)
        with fs.patch_subprocess():
            data = portal.get_status_json(IP)
        self.assertFalse(data["authenticated"])

    def test_not_authenticated_when_never_logged_in(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "REACHABLE")
        with fs.patch_subprocess():
            data = portal.get_status_json(IP)
        self.assertFalse(data["authenticated"])


class TestProcessLogout(unittest.TestCase):
    def test_logout_with_resolvable_mac_removes_exact_session(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "REACHABLE")
        fs.seed_authed(IP, MAC, timeout=3500)
        with fs.patch_subprocess():
            status, headers, _body = portal.process_logout(IP)
            self.assertEqual(status, 302)
            self.assertEqual(headers.get("Location"), "/login")
            self.assertFalse(portal.check_ipset(IP, MAC))

    def test_logout_without_resolvable_mac_falls_back_to_scan_by_ip(self):
        # El dispositivo ya se desconectó (sin entrada ARP), pero su sesión
        # sigue viva en el ipset: el logout debe encontrarla igual.
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3500)
        with fs.patch_subprocess():
            status, _headers, _body = portal.process_logout(IP)
            self.assertEqual(status, 302)
            self.assertFalse(portal.check_ipset(IP, MAC))

    def test_logout_when_nothing_to_remove_returns_500(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "REACHABLE")
        with fs.patch_subprocess():
            status, _headers, _body = portal.process_logout(IP)
        self.assertEqual(status, 500)


if __name__ == "__main__":
    unittest.main()
