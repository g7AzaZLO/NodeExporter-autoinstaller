import json
import os
from pathlib import Path
import pwd
import subprocess
import time
import unittest
import urllib.request

SCRIPT = '/app/NodeExporter-auto-install.sh'
FILES = [Path('/usr/local/bin/node_exporter'), Path('/etc/systemd/system/exporterd.service'),
         Path('/etc/default/exporterd')]
MANAGER = Path('/tmp/service-manager-test')
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))

class InstallerTests(unittest.TestCase):
    def setUp(self):
        subprocess.run(['systemctl', 'stop', 'exporterd.service'], check=True)
        for path in FILES:
            path.unlink(missing_ok=True)
        (MANAGER / 'state.json').unlink(missing_ok=True)
        (MANAGER / 'fail-next-start').unlink(missing_ok=True)

    def tearDown(self):
        subprocess.run(['systemctl', 'stop', 'exporterd.service'], check=True)

    def install(self, *args, success=True, extra_env=None):
        result = subprocess.run(['bash', SCRIPT, *args], capture_output=True, text=True,
                                env={**os.environ, **(extra_env or {})}, timeout=150)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('Installed node_exporter 1.12.1', result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn('Installed node_exporter', result.stdout)
        return result

    def snapshot(self):
        return [(path.read_bytes(), path.stat().st_mode) for path in FILES]

    def metrics(self, port=9100):
        for _ in range(50):
            try:
                return HTTP.open(f'http://127.0.0.1:{port}/metrics', timeout=3).read().decode()
            except OSError:
                time.sleep(.1)
        self.fail('The real exporter did not serve metrics')

    def test_fresh_install_runs_real_exporter_without_root(self):
        self.install()
        text = self.metrics()
        self.assertIn('node_exporter_build_info{', text)
        self.assertIn('version="1.12.1"', text)
        self.assertIn('node_cpu_seconds_total{', text)
        self.assertIn('node_memory_MemTotal_bytes ', text)
        uid = pwd.getpwnam('node_exporter').pw_uid
        self.assertNotEqual(uid, 0)
        pid = json.loads((MANAGER / 'state.json').read_text())['pid']
        status = Path(f'/proc/{pid}/status').read_text()
        self.assertIn(f'Uid:\t{uid}\t{uid}\t{uid}\t{uid}', status)
        self.assertEqual(FILES[0].stat().st_mode & 0o777, 0o755)
        self.assertEqual(FILES[1].stat().st_mode & 0o777, 0o644)
        subprocess.run(['systemd-analyze', 'verify', str(FILES[1])], check=True)

    def test_reinstall_preserves_custom_address_and_comments(self):
        self.install('--listen-address', '127.0.0.1:19100')
        with FILES[2].open('a') as config:
            config.write('# administrator comment\nOTHER_SETTING=kept\n')
        FILES[2].chmod(0o600)
        self.install()
        self.assertIn('LISTEN_ADDRESS=127.0.0.1:19100', FILES[2].read_text())
        self.assertIn('# administrator comment', FILES[2].read_text())
        self.assertIn('OTHER_SETTING=kept', FILES[2].read_text())
        self.assertEqual(FILES[2].stat().st_mode & 0o777, 0o600)
        self.assertIn('version="1.12.1"', self.metrics(19100))

    def test_upgrade_keeps_legacy_service_name_and_old_binary(self):
        old_binary = Path('/usr/bin/node_exporter')
        old_binary.write_text('#!/bin/sh\necho legacy-binary\n')
        old_binary.chmod(0o755)
        FILES[1].write_text('[Service]\nUser=root\nExecStart=/usr/bin/node_exporter\n')
        self.install()
        self.assertIn('User=node_exporter', FILES[1].read_text())
        self.assertIn('ExecStart=/usr/local/bin/node_exporter', FILES[1].read_text())
        self.assertIn('legacy-binary', old_binary.read_text())
        self.assertIn('version="1.12.1"', self.metrics())
        old_binary.unlink()

    def test_checksum_failure_preserves_running_installation(self):
        self.install()
        before = self.snapshot()
        state_before = (MANAGER / 'state.json').read_text()
        result = self.install(success=False, extra_env={'TEST_CORRUPT_ARCHIVE': '1'})
        self.assertIn('SHA-256 verification failed', result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual((MANAGER / 'state.json').read_text(), state_before)
        self.assertIn('version="1.12.1"', self.metrics())

    def test_download_failure_does_not_install_any_files(self):
        self.install(success=False, extra_env={'TEST_DOWNLOAD_FAILURE': '1'})
        self.assertTrue(all(not path.exists() for path in FILES))

    def test_failed_restart_restores_files_config_and_running_service(self):
        self.install('--listen-address', '127.0.0.1:19100')
        before = self.snapshot()
        (MANAGER / 'fail-next-start').touch()
        self.install('--listen-address', '127.0.0.1:19101', success=False)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(json.loads((MANAGER / 'state.json').read_text())['enabled'])
        self.assertIn('version="1.12.1"', self.metrics(19100))

    def test_failed_fresh_start_removes_new_installation(self):
        MANAGER.mkdir(exist_ok=True)
        (MANAGER / 'fail-next-start').touch()
        self.install(success=False)
        self.assertTrue(all(not path.exists() for path in FILES))
        state = json.loads((MANAGER / 'state.json').read_text())
        self.assertFalse(state['enabled'])
        self.assertIsNone(state['pid'])

    def test_invalid_arguments_do_not_install_files(self):
        for args in [('--version', '../latest'), ('--listen-address', '127.0.0.1:0'),
                     ('--listen-address', '999.0.0.1:9100'), ('--listen-address', '127.0.0.1:9100 --bad'),
                     ('--listen-address', ''), ('--unknown',)]:
            with self.subTest(args=args):
                self.install(*args, success=False)
                self.assertTrue(all(not path.exists() for path in FILES))

    def test_sourcing_does_not_exit_or_change_shell_options(self):
        result = subprocess.run(['bash', '-c', f'before=$-; source {SCRIPT}; result=$?; '
                                 'test "$result" -ne 0 && test "$before" = "$-" && echo survived'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('survived', result.stdout)

    def test_non_root_install_fails_before_changes(self):
        user = pwd.getpwnam('nobody')
        result = subprocess.run(['bash', SCRIPT], user=user.pw_uid, group=user.pw_gid,
                                extra_groups=[], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('sudo bash', result.stderr)
        self.assertTrue(all(not path.exists() for path in FILES))

if __name__ == '__main__':
    unittest.main()
