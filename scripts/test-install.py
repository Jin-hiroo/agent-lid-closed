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
