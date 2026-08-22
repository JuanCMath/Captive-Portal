import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import security


class TestCsrfToken(unittest.TestCase):
    IP = "10.200.0.5"

    def test_issued_token_verifies_for_same_ip(self):
        token = security.issue_csrf_token(self.IP)
        self.assertTrue(security.verify_csrf_token(self.IP, token))

    def test_token_rejected_for_different_ip(self):
        token = security.issue_csrf_token(self.IP)
        self.assertFalse(security.verify_csrf_token("10.200.0.9", token))

    def test_empty_or_none_token_rejected(self):
        self.assertFalse(security.verify_csrf_token(self.IP, ""))
        self.assertFalse(security.verify_csrf_token(self.IP, None))

    def test_garbage_token_rejected(self):
        self.assertFalse(security.verify_csrf_token(self.IP, "not-a-valid-token"))

    def test_tampered_token_rejected(self):
        token = security.issue_csrf_token(self.IP)
        # Voltear el último carácter debe invalidar la firma HMAC.
        tampered = token[:-1] + ("A" if token[-1] != "A" else "B")
        self.assertFalse(security.verify_csrf_token(self.IP, tampered))

    def test_expired_token_rejected(self):
        with patch("app.security.time.time", return_value=1_000_000.0):
            token = security.issue_csrf_token(self.IP)

        just_before_expiry = 1_000_000.0 + security._CSRF_TTL_SECONDS - 1
        with patch("app.security.time.time", return_value=just_before_expiry):
            self.assertTrue(security.verify_csrf_token(self.IP, token))

        after_expiry = 1_000_000.0 + security._CSRF_TTL_SECONDS + 1
        with patch("app.security.time.time", return_value=after_expiry):
            self.assertFalse(security.verify_csrf_token(self.IP, token))


class TestRateLimiter(unittest.TestCase):
    def _limiter(self):
        return security.RateLimiter(max_attempts=3, window_seconds=60, lockout_seconds=120)

    def test_not_blocked_before_reaching_max_attempts(self):
        rl = self._limiter()
        with patch("app.security.time.time", return_value=1000.0):
            rl.record_failure("1.2.3.4")
            rl.record_failure("1.2.3.4")
            blocked, _ = rl.is_blocked("1.2.3.4")
        self.assertFalse(blocked)

    def test_blocks_on_reaching_max_attempts(self):
        rl = self._limiter()
        with patch("app.security.time.time", return_value=1000.0):
            for _ in range(3):
                rl.record_failure("1.2.3.4")
            blocked, retry_after = rl.is_blocked("1.2.3.4")
        self.assertTrue(blocked)
        self.assertGreater(retry_after, 0)

    def test_keys_are_independent(self):
        rl = self._limiter()
        with patch("app.security.time.time", return_value=1000.0):
            for _ in range(3):
                rl.record_failure("1.2.3.4")
            blocked_other, _ = rl.is_blocked("9.9.9.9")
        self.assertFalse(blocked_other)

    def test_success_clears_block_and_history(self):
        rl = self._limiter()
        with patch("app.security.time.time", return_value=1000.0):
            for _ in range(3):
                rl.record_failure("1.2.3.4")
            rl.record_success("1.2.3.4")
            blocked, _ = rl.is_blocked("1.2.3.4")
        self.assertFalse(blocked)

    def test_unblocks_after_lockout_expires(self):
        rl = self._limiter()
        with patch("app.security.time.time", return_value=1000.0):
            for _ in range(3):
                rl.record_failure("1.2.3.4")
        with patch("app.security.time.time", return_value=1000.0 + 120.0 + 1):
            blocked, _ = rl.is_blocked("1.2.3.4")
        self.assertFalse(blocked)

    def test_failures_outside_window_do_not_accumulate(self):
        rl = self._limiter()
        with patch("app.security.time.time", return_value=1000.0):
            rl.record_failure("1.2.3.4")
            rl.record_failure("1.2.3.4")
        # Fuera de la ventana de 60s: las dos fallas anteriores ya no cuentan.
        with patch("app.security.time.time", return_value=1000.0 + 61):
            rl.record_failure("1.2.3.4")
            blocked, _ = rl.is_blocked("1.2.3.4")
        self.assertFalse(blocked)


class TestAuditLog(unittest.TestCase):
    def test_writes_one_json_line_per_event(self):
        tmp_dir = tempfile.TemporaryDirectory()
        try:
            log_path = Path(tmp_dir.name) / "audit.log"
            with patch("app.security._audit_log_path", return_value=log_path):
                security.audit_log("login_success", ip="10.0.0.1", user="alice")
                security.audit_log("logout", ip="10.0.0.1")

            lines = log_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 2)
            first = json.loads(lines[0])
            self.assertEqual(first["event"], "login_success")
            self.assertEqual(first["user"], "alice")
            self.assertIn("ts", first)
        finally:
            tmp_dir.cleanup()

    def test_never_raises_even_if_disk_write_fails(self):
        with patch("app.security._audit_log_path", side_effect=OSError("disco lleno")):
            try:
                security.audit_log("login_failed", ip="10.0.0.1")
            except Exception as e:  # noqa: BLE001
                self.fail(f"audit_log no debe propagar excepciones, lanzó: {e!r}")


if __name__ == "__main__":
    unittest.main()
