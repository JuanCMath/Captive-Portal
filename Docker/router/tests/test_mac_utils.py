import unittest
from unittest.mock import patch

from app.mac_utils import get_mac_for_ip
from .fakes import FakeSystem

IP = "10.200.0.5"
MAC = "aa:bb:cc:dd:ee:ff"


class TestGetMacForIp(unittest.TestCase):
    def test_resolves_mac_from_reachable_entry(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "REACHABLE")
        with fs.patch_subprocess():
            self.assertEqual(get_mac_for_ip(IP), MAC)

    def test_resolves_mac_from_stale_entry(self):
        # STALE sigue siendo una MAC válida, solo que el kernel quiere
        # reconfirmarla; no debe tratarse como ausente.
        fs = FakeSystem()
        fs.set_neigh(IP, MAC, "STALE")
        with fs.patch_subprocess():
            self.assertEqual(get_mac_for_ip(IP), MAC)

    def test_ignores_incomplete_entry_without_mac(self):
        fs = FakeSystem()
        fs.set_neigh(IP, None, "INCOMPLETE")
        with fs.patch_subprocess():
            self.assertIsNone(get_mac_for_ip(IP))

    def test_ignores_failed_entry(self):
        fs = FakeSystem()
        fs.set_neigh(IP, None, "FAILED")
        with fs.patch_subprocess():
            self.assertIsNone(get_mac_for_ip(IP))

    def test_no_neigh_entry_returns_none(self):
        fs = FakeSystem()
        with fs.patch_subprocess():
            self.assertIsNone(get_mac_for_ip(IP))

    def test_normalizes_to_lowercase(self):
        fs = FakeSystem()
        fs.set_neigh(IP, MAC.upper(), "REACHABLE")
        with fs.patch_subprocess():
            self.assertEqual(get_mac_for_ip(IP), MAC.lower())

    def test_subprocess_error_returns_none_instead_of_raising(self):
        def boom(cmd, **kw):
            raise OSError("ip: command not found")

        with patch("subprocess.run", side_effect=boom):
            self.assertIsNone(get_mac_for_ip(IP))


if __name__ == "__main__":
    unittest.main()
