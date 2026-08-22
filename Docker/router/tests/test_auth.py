import base64
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import auth, users


def _basic(username: str, password: str) -> str:
    raw = f"{username}:{password}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


class TestParseBasicAuth(unittest.TestCase):
    def test_valid_header(self):
        self.assertEqual(
            auth.parse_basic_auth(_basic("admin", "secret")), ("admin", "secret")
        )

    def test_missing_header(self):
        self.assertIsNone(auth.parse_basic_auth(None))
        self.assertIsNone(auth.parse_basic_auth(""))

    def test_wrong_scheme(self):
        self.assertIsNone(auth.parse_basic_auth("Bearer sometoken"))

    def test_malformed_base64(self):
        self.assertIsNone(auth.parse_basic_auth("Basic not-valid-base64!!"))

    def test_missing_colon_in_decoded_value(self):
        encoded = base64.b64encode(b"nocolonhere").decode("ascii")
        self.assertIsNone(auth.parse_basic_auth(f"Basic {encoded}"))

    def test_password_with_colon_is_preserved(self):
        # split(":", 1): solo el primer ':' separa usuario de contraseña.
        user, password = auth.parse_basic_auth(_basic("admin", "pass:with:colons"))
        self.assertEqual(user, "admin")
        self.assertEqual(password, "pass:with:colons")


class TestIsAdmin(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp_dir.name) / "users.json"
        self.ctx = patch.object(users, "USERS_FILE", self.path)
        self.ctx.start()
        users.save_users(
            [
                {"u": "admin", "p": users._hash_password("supersecret")},
                {"u": "alice", "p": users._hash_password("alicepass")},
            ]
        )

    def tearDown(self):
        self.ctx.stop()
        self.tmp_dir.cleanup()

    def test_admin_with_correct_password(self):
        self.assertTrue(auth.is_admin("admin", "supersecret"))

    def test_admin_with_wrong_password(self):
        self.assertFalse(auth.is_admin("admin", "wrongpass"))

    def test_non_admin_user_is_never_admin_even_with_correct_password(self):
        # Solo 'admin' puede entrar al panel, aunque alice tenga credenciales
        # válidas para el portal.
        self.assertFalse(auth.is_admin("alice", "alicepass"))

    def test_nonexistent_user(self):
        self.assertFalse(auth.is_admin("ghost", "whatever"))


if __name__ == "__main__":
    unittest.main()
