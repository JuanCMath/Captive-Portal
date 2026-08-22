import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import users


def _temp_users_file():
    """Contexto que apunta app.users.USERS_FILE a un archivo temporal
    aislado, para que ningún test toque el users.json real del proyecto."""
    tmp_dir = tempfile.TemporaryDirectory()
    path = Path(tmp_dir.name) / "users.json"
    ctx = patch.object(users, "USERS_FILE", path)
    return tmp_dir, ctx, path


class TestPasswordHashing(unittest.TestCase):
    def test_hash_roundtrip(self):
        hashed = users._hash_password("correcthorse")
        self.assertTrue(users._is_hashed(hashed))
        self.assertTrue(users._verify_password("correcthorse", hashed))
        self.assertFalse(users._verify_password("wrongpassword", hashed))

    def test_plaintext_comparison_still_supported(self):
        # Compatibilidad con users.json heredados de versiones antiguas.
        self.assertTrue(users._verify_password("plainpass", "plainpass"))
        self.assertFalse(users._verify_password("other", "plainpass"))

    def test_same_password_hashes_differently_each_time(self):
        # Salt aleatorio por usuario: dos hashes del mismo password no deben
        # coincidir como strings, aunque ambos verifiquen correctamente.
        h1 = users._hash_password("samepass")
        h2 = users._hash_password("samepass")
        self.assertNotEqual(h1, h2)
        self.assertTrue(users._verify_password("samepass", h1))
        self.assertTrue(users._verify_password("samepass", h2))


class TestCreateDeleteUser(unittest.TestCase):
    def setUp(self):
        self.tmp_dir, self.ctx, self.path = _temp_users_file()
        self.ctx.start()
        users.save_users([{"u": "admin", "p": users._hash_password("adminpass")}])

    def tearDown(self):
        self.ctx.stop()
        self.tmp_dir.cleanup()

    def test_create_user_success(self):
        ok, msg = users.create_user("alice", "longenough")
        self.assertTrue(ok)
        self.assertIn("alice", msg)
        self.assertTrue(users.check_credentials("alice", "longenough"))

    def test_create_user_persists_hashed_not_plaintext(self):
        users.create_user("alice", "longenough")
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        alice = next(u for u in raw if u["u"] == "alice")
        self.assertTrue(users._is_hashed(alice["p"]))
        self.assertNotIn("longenough", alice["p"])

    def test_create_user_duplicate_fails(self):
        users.create_user("alice", "longenough")
        ok, msg = users.create_user("alice", "otherpassword")
        self.assertFalse(ok)
        self.assertIn("ya existe", msg)

    def test_create_user_short_password_fails(self):
        ok, msg = users.create_user("alice", "short")
        self.assertFalse(ok)
        self.assertFalse(users.check_credentials("alice", "short"))

    def test_create_user_rejects_spaces_in_username(self):
        ok, msg = users.create_user("ali ce", "longenough")
        self.assertFalse(ok)

    def test_create_user_rejects_empty_username(self):
        ok, msg = users.create_user("   ", "longenough")
        self.assertFalse(ok)

    def test_delete_admin_is_blocked(self):
        ok, msg = users.delete_user("admin")
        self.assertFalse(ok)
        self.assertTrue(users.check_credentials("admin", "adminpass"))

    def test_delete_existing_user(self):
        users.create_user("alice", "longenough")
        ok, msg = users.delete_user("alice")
        self.assertTrue(ok)
        self.assertFalse(users.check_credentials("alice", "longenough"))

    def test_delete_nonexistent_user_fails(self):
        ok, msg = users.delete_user("ghost")
        self.assertFalse(ok)


class TestCheckCredentials(unittest.TestCase):
    def setUp(self):
        self.tmp_dir, self.ctx, self.path = _temp_users_file()
        self.ctx.start()

    def tearDown(self):
        self.ctx.stop()
        self.tmp_dir.cleanup()

    def test_nonexistent_user_fails(self):
        users.save_users([{"u": "admin", "p": users._hash_password("adminpass")}])
        self.assertFalse(users.check_credentials("nobody", "whatever"))

    def test_wrong_password_fails(self):
        users.save_users([{"u": "admin", "p": users._hash_password("adminpass")}])
        self.assertFalse(users.check_credentials("admin", "wrongpass"))

    def test_plaintext_password_migrates_to_hash_on_successful_login(self):
        # Simula un users.json heredado (contraseña en texto plano).
        self.path.write_text(
            json.dumps([{"u": "legacyuser", "p": "plainpass123"}]), encoding="utf-8"
        )

        self.assertTrue(users.check_credentials("legacyuser", "plainpass123"))

        raw = json.loads(self.path.read_text(encoding="utf-8"))
        legacy = next(u for u in raw if u["u"] == "legacyuser")
        self.assertTrue(users._is_hashed(legacy["p"]))

        # La migración no debe romper logins futuros con la misma contraseña.
        self.assertTrue(users.check_credentials("legacyuser", "plainpass123"))

    def test_failed_plaintext_login_does_not_migrate(self):
        self.path.write_text(
            json.dumps([{"u": "legacyuser", "p": "plainpass123"}]), encoding="utf-8"
        )
        self.assertFalse(users.check_credentials("legacyuser", "wrongpass"))
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        legacy = next(u for u in raw if u["u"] == "legacyuser")
        self.assertEqual(legacy["p"], "plainpass123")


class TestSaveUsersAtomicWrite(unittest.TestCase):
    def setUp(self):
        self.tmp_dir, self.ctx, self.path = _temp_users_file()
        self.ctx.start()

    def tearDown(self):
        self.ctx.stop()
        self.tmp_dir.cleanup()

    def test_no_leftover_tmp_file_after_save(self):
        users.save_users([{"u": "admin", "p": "x"}])
        tmp_path = self.path.with_suffix(self.path.suffix + ".tmp")
        self.assertTrue(self.path.exists())
        self.assertFalse(tmp_path.exists())

    def test_written_content_is_valid_json(self):
        data = [{"u": "admin", "p": "x"}, {"u": "alice", "p": "y"}]
        users.save_users(data)
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(raw, data)


if __name__ == "__main__":
    unittest.main()
