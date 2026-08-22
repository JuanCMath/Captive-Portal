import unittest
from unittest.mock import patch

from app import ipset_utils
from .fakes import FakeSystem

IP = "10.200.0.5"
MAC = "aa:bb:cc:dd:ee:ff"
OTHER_MAC = "11:22:33:44:55:66"


class TestSudoPrefixing(unittest.TestCase):
    """
    ipset_utils._ipset_cmd decide si anteponer 'sudo -n' según el UID
    efectivo del proceso -- root (Docker) llama a ipset directo, un
    usuario sin privilegios (native/install.sh) necesita sudo. Ver el
    sudoers generado por native/install.sh, que solo autoriza estos
    subcomandos exactos sobre 'authed'.
    """

    def test_runs_ipset_directly_as_root(self):
        fs = FakeSystem()
        with fs.patch_subprocess(), patch("app.ipset_utils.os.geteuid", return_value=0, create=True):
            ipset_utils.add_to_ipset(IP, MAC)
        self.assertEqual(fs.calls[0][0], "ipset")

    def test_prefixes_sudo_when_not_root(self):
        fs = FakeSystem()
        with fs.patch_subprocess(), patch("app.ipset_utils.os.geteuid", return_value=1000, create=True):
            ipset_utils.add_to_ipset(IP, MAC)
        self.assertEqual(fs.calls[0][:3], ["sudo", "-n", "ipset"])

    def test_sudo_prefix_still_reaches_correct_ipset_subcommand(self):
        # No solo que anteponga sudo: que el ipset_utils resultante siga
        # funcionando de punta a punta (fakes.py despoja el prefijo antes
        # de interpretar el comando).
        fs = FakeSystem()
        with fs.patch_subprocess(), patch("app.ipset_utils.os.geteuid", return_value=1000, create=True):
            self.assertTrue(ipset_utils.add_to_ipset(IP, MAC))
            self.assertTrue(ipset_utils.check_ipset(IP, MAC))
            self.assertTrue(ipset_utils.remove_from_ipset(IP, MAC))


class TestAddCheckRemove(unittest.TestCase):
    def test_add_then_check_matches(self):
        fs = FakeSystem()
        with fs.patch_subprocess():
            self.assertTrue(ipset_utils.add_to_ipset(IP, MAC))
            self.assertTrue(ipset_utils.check_ipset(IP, MAC))

    def test_check_fails_for_wrong_mac_same_ip(self):
        # La propiedad central de todo el cambio IP+MAC: la IP sola no basta.
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3600)
        with fs.patch_subprocess():
            self.assertFalse(ipset_utils.check_ipset(IP, OTHER_MAC))
            self.assertTrue(ipset_utils.check_ipset(IP, MAC))

    def test_check_is_case_insensitive_on_mac(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3600)
        with fs.patch_subprocess():
            self.assertTrue(ipset_utils.check_ipset(IP, MAC.upper()))

    def test_remove_deletes_exact_pair(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3600)
        with fs.patch_subprocess():
            self.assertTrue(ipset_utils.remove_from_ipset(IP, MAC))
            self.assertFalse(ipset_utils.check_ipset(IP, MAC))

    def test_remove_nonexistent_pair_returns_false(self):
        fs = FakeSystem()
        with fs.patch_subprocess():
            self.assertFalse(ipset_utils.remove_from_ipset(IP, MAC))

    def test_add_failure_returns_false_not_raise(self):
        fs = FakeSystem()
        fs.ipset_add_fails = True
        with fs.patch_subprocess():
            self.assertFalse(ipset_utils.add_to_ipset(IP, MAC))

    def test_remove_failure_returns_false_not_raise(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3600)
        fs.ipset_del_fails = True
        with fs.patch_subprocess():
            self.assertFalse(ipset_utils.remove_from_ipset(IP, MAC))


class TestRemoveByIp(unittest.TestCase):
    def test_removes_all_entries_for_ip_regardless_of_mac(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3600)
        with fs.patch_subprocess():
            self.assertTrue(ipset_utils.remove_from_ipset_by_ip(IP))
            self.assertFalse(ipset_utils.check_ipset(IP, MAC))

    def test_does_not_touch_other_ips(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3600)
        fs.seed_authed("10.200.0.9", OTHER_MAC, timeout=3600)
        with fs.patch_subprocess():
            ipset_utils.remove_from_ipset_by_ip(IP)
            self.assertTrue(ipset_utils.check_ipset("10.200.0.9", OTHER_MAC))

    def test_returns_false_when_nothing_matches(self):
        fs = FakeSystem()
        with fs.patch_subprocess():
            self.assertFalse(ipset_utils.remove_from_ipset_by_ip(IP))

    def test_returns_false_when_list_fails(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3600)
        fs.ipset_list_fails = True
        with fs.patch_subprocess():
            self.assertFalse(ipset_utils.remove_from_ipset_by_ip(IP))


class TestGetRemainingTimeout(unittest.TestCase):
    def test_returns_timeout_for_matching_pair(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3542)
        with fs.patch_subprocess():
            self.assertEqual(ipset_utils.get_remaining_timeout(IP, MAC), 3542)

    def test_matches_despite_ipset_uppercasing_mac_in_listing(self):
        # Bug real de E2E: `ipset list` devuelve la MAC en mayúsculas sin
        # importar cómo se insertó (ver fakes.py). Antes de corregirlo esto
        # devolvía siempre 0 pese a existir una sesión activa.
        fs = FakeSystem()
        fs.seed_authed(IP, MAC.upper(), timeout=3542)
        with fs.patch_subprocess():
            self.assertEqual(ipset_utils.get_remaining_timeout(IP, MAC.lower()), 3542)

    def test_returns_zero_for_wrong_mac(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3542)
        with fs.patch_subprocess():
            self.assertEqual(ipset_utils.get_remaining_timeout(IP, OTHER_MAC), 0)

    def test_returns_zero_when_not_present(self):
        fs = FakeSystem()
        with fs.patch_subprocess():
            self.assertEqual(ipset_utils.get_remaining_timeout(IP, MAC), 0)

    def test_returns_zero_when_list_fails(self):
        fs = FakeSystem()
        fs.seed_authed(IP, MAC, timeout=3542)
        fs.ipset_list_fails = True
        with fs.patch_subprocess():
            self.assertEqual(ipset_utils.get_remaining_timeout(IP, MAC), 0)


if __name__ == "__main__":
    unittest.main()
