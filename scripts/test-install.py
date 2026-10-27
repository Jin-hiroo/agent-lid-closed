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
t3_setup = module('t3_setup', 'configure-t3.py')


class InstallationTests(unittest.TestCase):
    def test_t3_upgrades_preserve_explicit_recovery_opt_out(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'settings.json'
            original = json.dumps({'autoResumeLimitedThreads': False, 'other': 42})
            path.write_text(original)
            self.assertIsNone(t3_setup.enable_recovery(path, preserve_choice=True))
            self.assertEqual(path.read_text(), original)
            result = subprocess.run(['python3', str(ROOT / 'scripts/configure-t3.py'), '--preserve-choice', str(path)],
                                    capture_output=True, text=True, check=True)
            self.assertIn('preserving your disabled', result.stdout)
            self.assertEqual(path.read_text(), original)
            self.assertTrue(t3_setup.enable_recovery(path))
            self.assertTrue(json.loads(path.read_text())['autoResumeLimitedThreads'])
            self.assertIn('scripts/configure-t3.py --preserve-choice', (ROOT / 'scripts/install.sh').read_text())

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

    def test_plan_adds_hooks_only_for_tools_that_are_present(self):
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            manifest = str(home / 'state/hook-targets.json')
            env = {'HOME': str(home)}

            def plan(found=(), env=env, **options):
                return hooks.plan(manifest, environ=env, which=lambda name: name in found or None, **options)
            self.assertEqual(plan(), {'claude': [], 'codex': []})
            self.assertEqual(plan(found=('codex',)), {'claude': [], 'codex': [str(home / '.codex/hooks.json')]})
            (home / '.claude').mkdir()
            self.assertEqual(plan()['claude'], [str(home / '.claude/settings.json')])
            self.assertEqual(plan(no_claude=True, force_codex=True),
                             {'claude': [], 'codex': [str(home / '.codex/hooks.json')]})
            # The shell's account and named folders are added to the default one.
            work = home / 'work-claude'
            self.assertEqual(plan(env=dict(env, CLAUDE_CONFIG_DIR=str(work)), claude_dirs=[str(home / 'other')])['claude'],
                             [str(home / '.claude/settings.json'), str(work / 'settings.json'),
                              str(home / 'other/settings.json')])
            # Files that already have the hooks keep them current, even if the tool is gone.
            codex = home / 'custom-codex'
            codex.mkdir()
            (codex / 'hooks.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [
                {'type': 'command', 'command': '/old/agent-lid-hook --provider codex'}]}]}}))
            self.assertEqual(plan(env=dict(env, CODEX_HOME=str(codex)))['codex'], [str(codex / 'hooks.json')])
            self.assertEqual(plan(env=dict(env, CODEX_HOME=str(codex)), no_codex=True)['codex'], [])
            # An earlier install in ~/.codex is kept current after CODEX_HOME moves elsewhere.
            (home / '.codex').mkdir()
            (home / '.codex/hooks.json').write_text((codex / 'hooks.json').read_text())
            self.assertEqual(plan(found=('codex',), env=dict(env, CODEX_HOME=str(home / 'new-codex')))['codex'],
                             [str(home / 'new-codex/hooks.json'), str(home / '.codex/hooks.json')])

    def test_plan_skips_relative_empty_and_multiline_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            (home / '.claude').mkdir()
            manifest = home / 'hook-targets.json'
            odd = home / 'a\nb'
            odd.mkdir()
            (odd / 'settings.json').write_text('{}')
            manifest.write_text(json.dumps({'claude': [str(odd / 'settings.json')], 'codex': []}))
            env = {'HOME': str(home), 'CLAUDE_CONFIG_DIR': 'relative', 'CODEX_HOME': 'also-relative'}
            planned = hooks.plan(str(manifest), claude_dirs=['', 'profiles/work', str(home / 'a\nc'), str(home / 'ok')],
                                 environ=env, which=lambda name: name == 'codex')
            self.assertEqual(planned, {'claude': [str(home / '.claude/settings.json'), str(home / 'ok/settings.json')],
                                       'codex': [str(home / '.codex/hooks.json')]})

    def test_uninstall_targets_cover_old_locations_and_unreadable_files(self):
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            marked = {'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': '/x/agent-lid-hook'}]}]}}
            for folder in ('.claude', '.codex', 'work', 'shell', 'clean'):
                (home / folder).mkdir()
            (home / '.claude/settings.json').write_text(json.dumps(marked))
            (home / '.codex/hooks.json').write_text('{"hooks": not json, "agent-lid-hook"')
            (home / 'work/settings.json').write_text(json.dumps(marked))
            (home / 'shell/settings.json').write_text(json.dumps(marked))
            (home / 'clean/settings.json').write_text('{"theme": "dark"}')
            manifest = home / 'hook-targets.json'
            manifest.write_text(json.dumps({'claude': [str(home / 'work/settings.json'), str(home / 'clean/settings.json'),
                                                       'relative/settings.json'], 'codex': []}))
            env = {'HOME': str(home), 'CLAUDE_CONFIG_DIR': str(home / 'shell'), 'CODEX_HOME': str(home / 'gone')}
            self.assertEqual(hooks.targets(str(manifest), environ=env),
                             [str(home / 'work/settings.json'), str(home / '.claude/settings.json'),
                              str(home / '.codex/hooks.json'), str(home / 'shell/settings.json')])

    def test_uninstall_continues_past_a_file_it_cannot_fix(self):
        source = (ROOT / 'scripts/uninstall.sh').read_text()
        snippet = source[source.index('MANIFEST='):source.index('# Clear a "Start at Login"')]
        with tempfile.TemporaryDirectory() as temp:
            home = pathlib.Path(temp)
            marked = {'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': '/x/agent-lid-hook'}]}]}, 'theme': 1}
            (home / '.claude').mkdir()
            (home / '.codex').mkdir()
            (home / '.codex/hooks.json').write_text('{"agent-lid-hook": ')
            (home / '.claude/settings.json').write_text(json.dumps(marked))
            env = {k: v for k, v in os.environ.items() if k not in ('CLAUDE_CONFIG_DIR', 'CODEX_HOME')}
            result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + snippet + 'echo "END $HOOK_FAILED"'],
                                    cwd=ROOT, env=dict(env, HOME=str(home)), text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('END 1', result.stdout)
            self.assertIn("couldn't remove the hooks from " + str(home / '.codex/hooks.json'), result.stderr)
            self.assertEqual(json.loads((home / '.claude/settings.json').read_text()), {'theme': 1})

    def test_bootstrap_failure_keeps_start_at_login_off(self):
        source = (ROOT / 'scripts/install.sh').read_text()
        snippet = source[source.index('DISABLED='):source.index('\necho\necho "Done.')]
        mock = '''
launchctl() {
    echo "$1" >> "$CALLS"
    case "$1" in
        print-disabled) printf '\\t"local.AgentLidClosed" => disabled\\n' ;;
        bootstrap) return 5 ;;
    esac
}
'''
        with tempfile.TemporaryDirectory() as temp:
            calls = pathlib.Path(temp) / 'calls'
            result = subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\nLABEL=local.AgentLidClosed\nAGENT=/x\n'
                                     + mock + snippet + '\necho REACHED'],
                                    env=dict(os.environ, CALLS=str(calls)), text=True, capture_output=True)
            self.assertEqual(result.returncode, 5)
            self.assertNotIn('REACHED', result.stdout)
            self.assertEqual(calls.read_text().split(), ['print-disabled', 'enable', 'bootstrap', 'disable'])

    def test_relative_config_folders_resolve_where_the_installer_runs(self):
        source = (ROOT / 'scripts/install.sh').read_text()
        snippet = source[source.index('PLAN_ARGS=()'):source.index('cd "$(dirname "$0")/.."')]
        with tempfile.TemporaryDirectory() as temp:
            script = 'set -euo pipefail\nusage() { :; }\n' + snippet + 'printf "%s\\n" "${PLAN_ARGS[@]}"'
            result = subprocess.run(['/bin/bash', '-c', script, 'install.sh', '--claude-config-dir', 'work',
                                     '--claude-config-dir', '/abs', '--claude-config-dir', '~/home'],
                                    cwd=temp, text=True, capture_output=True, check=True)
            cwd = os.path.realpath(temp)
            self.assertEqual(result.stdout.split('\n')[:6], ['--claude-config-dir', cwd + '/work', '--claude-config-dir',
                                                             '/abs', '--claude-config-dir', '~/home'])
            result = subprocess.run(['/bin/bash', '-c', script, 'install.sh', '--claude-config-dir', ''],
                                    cwd=temp, text=True, capture_output=True)
            self.assertEqual(result.returncode, 64)

    def test_manifest_records_hook_files_and_plan_reuses_them(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            manifest = root / 'state/hook-targets.json'
            work = root / 'work/settings.json'
            script = str(ROOT / 'scripts/hooks.py')
            subprocess.run(['python3', script, 'install', str(work), '/app/agent-lid-hook', 'claude',
                            '--manifest', str(manifest)], check=True)
            subprocess.run(['python3', script, 'install', str(work), '/app/agent-lid-hook', 'claude',
                            '--manifest', str(manifest)], check=True)
            self.assertEqual(hooks.read_manifest(manifest), {'claude': [str(work)], 'codex': []})
            self.assertTrue(hooks.has_hooks(work))
            # A later install still covers the second account without naming it again.
            planned = hooks.plan(str(manifest), environ={'HOME': str(root / 'home')}, which=lambda name: None)
            self.assertEqual(planned['claude'], [str(work)])
            subprocess.run(['python3', script, 'uninstall', str(work), '--manifest', str(manifest)], check=True)
            self.assertEqual(hooks.read_manifest(manifest), {'claude': [], 'codex': []})
            self.assertFalse(hooks.has_hooks(work))
            manifest.write_text('not json')
            self.assertEqual(hooks.read_manifest(manifest), {'claude': [], 'codex': []})

    def test_installer_options_exit_before_changing_anything(self):
        script = str(ROOT / 'scripts/install.sh')
        result = subprocess.run(['/bin/bash', script, '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('--claude-config-dir', result.stdout)
        result = subprocess.run(['/bin/bash', script, '--unknown'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)
        result = subprocess.run(['/bin/bash', script, '--claude-config-dir'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)
        source = (ROOT / 'scripts/install.sh').read_text()
        self.assertLess(source.index('done\ncd "$(dirname "$0")/.."\n\nLABEL='), source.index('./scripts/build-app.sh'))

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
