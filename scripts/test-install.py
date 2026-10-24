#!/usr/bin/env python3
"""Check hook merging, quoting, permissions and state aliases using temporary files."""
import importlib.util
import json
import os
import pathlib
import shlex
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


hooks = module('hooks', 'hooks.py')
migration = module('migration', 'migrate-state.py')


class InstallationTests(unittest.TestCase):
    def test_t3_failure_precedes_power_changes_and_app_stop(self):
        source = (ROOT / 'scripts/install.sh').read_text()
        start = source.index('echo "==> Enabling T3 Code usage-reset continuation')
        end = source.index('# Validate/create the aliases')
        self.assertLess(end, source.index('echo "==> Stopping running copies'))
        # This snippet never reaches power or launchctl operations when setup fails.
        snippet = source[start:end].replace('/usr/bin/python3 scripts/configure-t3.py', 'false')
        result = subprocess.run(['/bin/bash', '-c', 'set -e\n' + snippet + '\necho APP_STOP_REACHED'],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('the running app was left in place', result.stderr)
        self.assertNotIn('APP_STOP_REACHED', result.stdout)

    def run_power_setup(self, directory, reject_verification=False):
        """Run the installer's real power setup with sudo simulated, never as root."""
        source = (ROOT / 'scripts/install.sh').read_text()
        start = source.index('echo "==> Installing the root-owned wake helper"')
        end = source.index('echo "==> Stopping running copies')
        setup = source[start:end]
        root = pathlib.Path(directory)
        legacy = root / 'legacy-sudoers'
        legacy.touch()
        # Authenticating for `install` fills the simulated credential cache. Listing
        # any administrator command then succeeds, even without NOPASSWD. Executing
        # the helper after `sudo -k` must rely on the newly installed rule instead.
        harness = r'''
set -euo pipefail
sudo() {
    if [ "$1" = -k ]; then
        rm -f "$TEST_DIR/cached"
        return 0
    fi
    if [ "$1" = install ]; then
        touch "$TEST_DIR/cached"
        if [ "${!#}" = "$SUDOERS" ]; then
            cp "$rule" "$SUDOERS"
        fi
        return 0
    fi
    if [ "$1" = -n ] && [ "$2" = -l ]; then
        test -f "$TEST_DIR/cached"
        return
    fi
    if [ "$1" = -n ] && [ "$2" = "$WAKE_HELPER" ] && [ "$3" = clear ]; then
        if [ -e "$TEST_DIR/cached" ]; then
            echo 'verification incorrectly used cached credentials' >&2
            return 2
        fi
        if [ -f "$SUDOERS" ] && [ "$TEST_REJECT_VERIFICATION" = 0 ]; then
            touch "$TEST_DIR/verified"
            return 0
        fi
        echo 'sudo: a password is required' >&2
        return 1
    fi
    echo 'unexpected sudo command' >&2
    return 64
}
'''
        env = dict(os.environ, TEST_DIR=str(root), SUDOERS=str(root / 'new-sudoers'),
                   LEGACY_SUDOERS=str(legacy), USER_NAME='installer_test',
                   WAKE_HELPER='/Library/PrivilegedHelperTools/local.AgentLidClosed.wake',
                   TEST_REJECT_VERIFICATION='1' if reject_verification else '0')
        return subprocess.run(['/bin/bash', '-c', harness + setup + '\necho APP_STOP_REACHED\n'],
                              env=env, text=True, capture_output=True)

    def test_cached_admin_login_cannot_hide_missing_wake_rule(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.run_power_setup(temp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((pathlib.Path(temp) / 'verified').exists())
            rule = (pathlib.Path(temp) / 'new-sudoers').read_text()
            self.assertIn('NOPASSWD: /usr/bin/pmset -a disablesleep 0, ', rule)
            self.assertIn('/usr/bin/pmset -a disablesleep 1, ', rule)
            self.assertIn('/Library/PrivilegedHelperTools/local.AgentLidClosed.wake', rule)
            self.assertIn('APP_STOP_REACHED', result.stdout)

    def test_password_free_access_failure_leaves_app_running(self):
        with tempfile.TemporaryDirectory() as temp:
            result = self.run_power_setup(temp, reject_verification=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('APP_STOP_REACHED', result.stdout)
            self.assertIn('the running app was left in place', result.stderr)

    def test_statusline_wrap_restore_and_reinstall(self):
        original = {'type': 'command', 'command': 'echo "$MODEL"; cat',
                    'padding': 3, 'refreshInterval': 5, 'hideVimModeIndicator': True}
        settings = {'statusLine': dict(original), 'unrelated': True}
        command = shlex.quote("/new path/'$()`/agent-lid-hook")
        hooks.install(settings, command)
        once = json.loads(json.dumps(settings))
        args = shlex.split(settings['statusLine']['command'])
        self.assertEqual(args[:3], ["/new path/'$()`/agent-lid-hook", 'statusline', '--original-statusline'])
        self.assertEqual(json.loads(args[3]), original)
        self.assertEqual(settings['statusLine']['padding'], 3)
        hooks.install(settings, command)
        self.assertEqual(settings, once, 'must not nest wrappers on reinstall')
        hooks.strip(settings)
        self.assertEqual(settings, {'statusLine': original, 'unrelated': True})

    def test_statusline_without_original_is_removed_on_uninstall(self):
        settings = {}
        hooks.install(settings, '/app/agent-lid-hook')
        hooks.strip(settings)
        self.assertEqual(settings, {})

    def test_manually_replaced_statusline_survives_uninstall(self):
        settings = {}
        hooks.install(settings, '/app/agent-lid-hook')
        replacement = {'type': 'command', 'command': 'echo my-new-status'}
        settings['statusLine'] = replacement
        hooks.strip(settings)
        self.assertEqual(settings, {'statusLine': replacement})

    def test_unsupported_statusline_fails_validation_before_install(self):
        with self.assertRaises(ValueError):
            hooks.validate({'statusLine': 'unsupported'})

    def test_merge_is_idempotent_and_uninstall_preserves_other_hooks(self):
        unrelated = {'type': 'command', 'command': 'echo other'}
        settings = {'theme': 'dark', 'hooks': {
            'Stop': [{'matcher': '.*', 'hooks': [unrelated, {
                'type': 'command', 'command': '/old/claude-lid-hook'}]}]}}
        hooks.install(settings, '/new/agent-lid-hook --provider codex', 'codex')
        hooks.install(settings, '/new/agent-lid-hook --provider codex', 'codex')
        self.assertEqual(settings['hooks']['Stop'][0]['hooks'], [unrelated])
        self.assertEqual(len(settings['hooks']['Stop']), 2)
        self.assertNotIn('Notification', settings['hooks'])
        for event in ('Interrupt', 'SessionEnd'):
            self.assertLessEqual(settings['hooks'][event][0]['hooks'][0]['timeout'], 3)
        hooks.strip(settings)
        self.assertEqual(settings, {'theme': 'dark', 'hooks': {
            'Stop': [{'matcher': '.*', 'hooks': [unrelated]}]}})

    def test_cli_preserves_symlink_mode_backup_and_shell_quoting(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            target, alias = root / 'settings.json', root / 'linked.json'
            target.write_text('{"other":true}')
            target.chmod(0o600)
            alias.symlink_to(target)
            # A quoted shell path must not expand dollars or command substitutions.
            executable = root / "has space '$dollar`echo bad`$(echo bad)/agent-lid-hook"
            subprocess.run(['python3', str(ROOT / 'scripts/hooks.py'), 'install',
                            str(alias), str(executable), 'codex'], check=True)
            settings = json.loads(target.read_text())
            command = settings['hooks']['Stop'][0]['hooks'][0]['command']
            self.assertEqual(shlex.split(command), [str(executable), '--provider', 'codex'])
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertTrue(alias.is_symlink())
            self.assertTrue(settings['other'])
            self.assertEqual(json.loads(pathlib.Path(str(target) + '.bak').read_text()), {'other': True})

    def test_upgrade_keeps_live_state_and_lock_inode(self):
        with tempfile.TemporaryDirectory() as temp:
            legacy, current = pathlib.Path(temp) / 'old', pathlib.Path(temp) / 'new'
            legacy.mkdir()
            (legacy / '.lock').touch()
            inode = (legacy / '.lock').stat().st_ino
            migration.migrate(legacy, current)
            migration.migrate(legacy, current)
            (legacy / 'new-event.json').write_text('event')
            self.assertEqual((current / 'new-event.json').read_text(), 'event')
            self.assertEqual((current / '.lock').stat().st_ino, inode)

    def test_fresh_install_keeps_legacy_alias(self):
        with tempfile.TemporaryDirectory() as temp:
            legacy, current = pathlib.Path(temp) / 'old', pathlib.Path(temp) / 'new'
            migration.migrate(legacy, current)
            migration.migrate(legacy, current)
            self.assertEqual(legacy.resolve(), current.resolve())

    def test_separate_state_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            legacy, current = pathlib.Path(temp) / 'old', pathlib.Path(temp) / 'new'
            legacy.mkdir()
            current.mkdir()
            with self.assertRaises(RuntimeError):
                migration.migrate(legacy, current)


if __name__ == '__main__':
    unittest.main()
