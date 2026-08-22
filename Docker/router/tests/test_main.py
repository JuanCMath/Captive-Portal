import unittest

from app import security
from app.main import (
    build_response,
    client_ip_from_headers,
    handle_static,
    route_request,
)


def _reset_limiters():
    security.login_limiter._attempts = {}
    security.login_limiter._blocked_until = {}
    security.admin_limiter._attempts = {}
    security.admin_limiter._blocked_until = {}


class TestClientIpFromHeaders(unittest.TestCase):
    def test_trusted_proxy_uses_x_real_ip(self):
        ip = client_ip_from_headers({"X-Real-IP": "10.200.0.5"}, "127.0.0.1")
        self.assertEqual(ip, "10.200.0.5")

    def test_trusted_proxy_falls_back_to_x_forwarded_for(self):
        ip = client_ip_from_headers({"X-Forwarded-For": "10.200.0.5, 1.2.3.4"}, "127.0.0.1")
        self.assertEqual(ip, "10.200.0.5")

    def test_untrusted_peer_ignores_spoofed_header(self):
        # El hallazgo más serio de la auditoría de seguridad: un cliente de
        # la LAN no puede suplantar la IP de otro falsificando esta cabecera
        # si la conexión TCP no viene de loopback (nginx).
        ip = client_ip_from_headers({"X-Real-IP": "10.200.0.99"}, "10.200.0.7")
        self.assertEqual(ip, "10.200.0.7")

    def test_no_header_uses_peer_ip(self):
        ip = client_ip_from_headers({}, "127.0.0.1")
        self.assertEqual(ip, "127.0.0.1")


class TestHandleStatic(unittest.TestCase):
    def test_serves_existing_file(self):
        status, headers, body = handle_static("/static/base.css")
        self.assertEqual(status, 200)
        self.assertIn("css", headers.get("Content-Type", ""))
        self.assertGreater(len(body), 0)

    def test_missing_file_404(self):
        status, _headers, _body = handle_static("/static/does-not-exist.css")
        self.assertEqual(status, 404)

    def test_blocks_dotdot_traversal(self):
        # main.py existe justo un nivel por encima de STATIC_ROOT: si el
        # traversal no estuviera bloqueado, esto lo serviría.
        status, _headers, _body = handle_static("/static/../main.py")
        self.assertEqual(status, 404)

    def test_blocks_url_encoded_traversal(self):
        status, _headers, _body = handle_static("/static/%2e%2e/main.py")
        self.assertEqual(status, 404)

    def test_blocks_mixed_encoded_traversal(self):
        status, _headers, _body = handle_static("/static/..%2fmain.py")
        self.assertEqual(status, 404)


class TestBuildResponse(unittest.TestCase):
    def test_adds_default_security_headers(self):
        raw = build_response(200, {}, b"hello")
        text = raw.decode("iso-8859-1")
        self.assertIn("X-Content-Type-Options: nosniff", text)
        self.assertIn("X-Frame-Options: DENY", text)
        self.assertIn("Referrer-Policy: no-referrer", text)
        self.assertIn("Content-Length: 5", text)
        self.assertIn("Connection: close", text)

    def test_custom_content_type_is_not_overridden(self):
        raw = build_response(200, {"Content-Type": "application/json"}, b"{}")
        text = raw.decode("iso-8859-1")
        self.assertIn("Content-Type: application/json", text)
        self.assertNotIn("text/html", text)


class TestRouteRequest(unittest.TestCase):
    def setUp(self):
        _reset_limiters()

    def test_get_login_returns_200_with_csrf(self):
        resp = route_request("GET", "/login", {}, b"", "10.200.0.5")
        self.assertTrue(resp.startswith(b"HTTP/1.1 200"))
        self.assertIn(b'name="csrf_token"', resp)

    def test_unknown_path_404(self):
        resp = route_request("GET", "/no-such-path", {}, b"", "10.200.0.5")
        self.assertTrue(resp.startswith(b"HTTP/1.1 404"))

    def test_unsupported_method_405(self):
        resp = route_request("PUT", "/login", {}, b"", "10.200.0.5")
        self.assertTrue(resp.startswith(b"HTTP/1.1 405"))

    def test_admin_users_without_credentials_requires_auth(self):
        resp = route_request("GET", "/admin/users", {}, b"", "10.200.0.5")
        self.assertTrue(resp.startswith(b"HTTP/1.1 401"))
        self.assertIn(b"WWW-Authenticate", resp)

    def test_head_login_has_no_body_but_correct_content_length(self):
        resp = route_request("HEAD", "/login", {}, b"", "10.200.0.5")
        self.assertTrue(resp.startswith(b"HTTP/1.1 200"))
        head, _, body = resp.partition(b"\r\n\r\n")
        self.assertIn(b"Content-Length: 0", head)
        self.assertEqual(body, b"")


if __name__ == "__main__":
    unittest.main()
