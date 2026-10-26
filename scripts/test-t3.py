#!/usr/bin/env python3
"""T3 bridge tests use isolated WAL databases and never start or message an agent."""
import datetime
import importlib.util
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = sys.argv.pop(1)
APP = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else ROOT / 'build/AgentLidClosed.app').resolve()
NOW = time.time()


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


class T3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agent-lid-t3-')
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name)
        self.runtime = dict(pid=os.getpid(), startedAt=iso(NOW))
        self.write_runtime()
        self.db = sqlite3.connect(self.path / 'statev2.sqlite')
        self.addCleanup(self.db.close)
        self.db.executescript('''
          PRAGMA journal_mode=WAL;
          CREATE TABLE orchestration_v2_projection_threads
            (thread_id TEXT PRIMARY KEY, project_id TEXT, provider_instance_id TEXT,
             deleted_at TEXT, archived_at TEXT, payload_json TEXT);
          CREATE TABLE orchestration_v2_projection_runs
            (run_id TEXT PRIMARY KEY, thread_id TEXT, ordinal INTEGER, provider_instance_id TEXT,
             provider_thread_id TEXT, status TEXT, requested_at TEXT, completed_at TEXT, payload_json TEXT);
          CREATE TABLE orchestration_v2_projection_provider_threads
            (provider_thread_id TEXT PRIMARY KEY, driver TEXT, payload_json TEXT);
          CREATE TABLE orchestration_v2_projection_runtime_requests
            (thread_id TEXT, status TEXT, created_at TEXT);
          CREATE TABLE orchestration_v2_projection_turn_items
            (turn_item_id TEXT PRIMARY KEY, thread_id TEXT, run_id TEXT, node_id TEXT,
             type TEXT, status TEXT, updated_at TEXT, ordinal INTEGER, payload_json TEXT);
          CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT);
          INSERT INTO projection_projects VALUES ('project', '/tmp/t3-project');
        ''')
        self.thread('codex', 'codex')

    def write_runtime(self):
        (self.path / 'server-runtime.json').write_text(json.dumps(self.runtime))

    def thread(self, key, driver, status='running', reset=None, auto=True, **metadata):
        instance = 'instance-' + driver
        recovery = dict(runId='run-' + key, resetAt=iso(reset), autoResume=auto) if reset else None
        payload = dict(limitRecovery=recovery, settledOverride=None, **metadata)
        self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_threads VALUES (?,?,?,NULL,NULL,?)',
                        (key, 'project', instance, json.dumps(payload)))
        self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_provider_threads VALUES (?,?,?)',
                        ('pt-' + key, driver, json.dumps({'nativeThreadRef': {'nativeId': 'native-' + key}})))
        self.run_record(key, status=status)
        if reset:
            self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                            ('error-' + key, key, 'run-' + key, 'root', 'error', 'failed', iso(NOW - 30), 1,
                             json.dumps({'failure': {'class': 'usage_limit', 'resetAt': iso(reset)}})))

    def run_record(self, key='codex', status='running', ordinal=1, run_id=None, completed=None, started=True):
        run_id = run_id or 'run-' + key
        terminal = status in ['failed', 'completed', 'cancelled', 'interrupted', 'rolled_back']
        payload = dict(rootNodeId='root', startedAt=iso(NOW - 40) if started else None)
        self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_runs VALUES (?,?,?,?,?,?,?,?,?)',
                        (run_id, key, ordinal, 'instance-' + ('codex' if key == 'codex' else 'claudeAgent'),
                         'pt-' + key, status, iso(NOW - 50),
                         iso(completed if completed is not None else NOW - 30) if terminal else None,
                         json.dumps(payload)))

    def read(self, now=NOW, hook_pid=None):
        self.db.commit()
        env = dict(os.environ)
        if hook_pid is not None:
            env['AGENT_LID_TEST_HOOK_PID'] = str(hook_pid)
        result = subprocess.run([BINARY, str(self.path), str(now)], capture_output=True, text=True, check=True, env=env)
        return json.loads(result.stdout)

    def metadata(self, **fields):
        raw = self.db.execute('SELECT payload_json FROM orchestration_v2_projection_threads WHERE thread_id="codex"').fetchone()[0]
        payload = json.loads(raw)
        payload.update(fields)
        self.db.execute('UPDATE orchestration_v2_projection_threads SET payload_json=? WHERE thread_id="codex"', (json.dumps(payload),))

    def blocked(self):
        self.thread('codex', 'codex', status='failed', reset=NOW + 1800)

    def test_native_work_without_hooks_and_old_hook_suppression(self):
        result = self.read()
        self.assertIsNone(result['error'])
        self.assertTrue(result['keepAwake'])
        self.assertEqual(result['mergedIDs'], ['t3:codex'])
        self.assertEqual(result['records'][0]['provider'], 'codex')

    def test_independent_terminal_hooks_are_not_shadowed_by_t3(self):
        self.assertEqual(self.read(hook_pid=os.getpid())['mergedIDs'], ['t3:codex'])
        self.assertEqual(self.read(hook_pid=os.getppid())['mergedIDs'], ['codex:native-codex', 't3:codex'])

    def test_same_thread_reset_uses_native_arm_and_not_child_process(self):
        self.blocked()
        result = self.read()
        self.assertFalse(result['keepAwake'])
        self.assertAlmostEqual(result['wakeAt'], int(NOW + 1680), delta=1)
        self.assertAlmostEqual(result['resetAt'], NOW + 1800, delta=.002)

    def test_both_providers_use_earliest_reset_and_preserve_other(self):
        self.blocked()
        self.thread('claude', 'claudeAgent', status='failed', reset=NOW + 900)
        self.assertAlmostEqual(self.read()['wakeAt'], int(NOW + 780), delta=1)
        self.run_record('claude', status='completed', ordinal=2, run_id='new-claude', completed=NOW)
        self.assertAlmostEqual(self.read()['wakeAt'], int(NOW + 1680), delta=1)

    def test_one_provider_working_keeps_awake_while_other_blocked(self):
        self.blocked()
        self.thread('claude', 'claudeAgent')
        self.assertTrue(self.read()['keepAwake'])
        self.assertIsNotNone(self.read()['wakeAt'])

    def test_warmup_and_grace_are_bounded(self):
        self.blocked()
        result = self.read(NOW + 1700)
        self.assertIsNone(result['wakeAt'])
        self.assertAlmostEqual(result['holdUntil'], NOW + 2100, delta=.002)
        self.assertIsNone(self.read(NOW + 2101)['holdUntil'])

    def test_weekly_reset_several_days_away(self):
        self.thread('codex', 'codex', status='failed', reset=NOW + 3 * 86400)
        self.assertAlmostEqual(self.read()['wakeAt'], int(NOW + 3 * 86400 - 120), delta=1)

    def test_newer_active_run_clears_old_quota(self):
        self.blocked()
        self.run_record(run_id='new-run', ordinal=2)
        result = self.read()
        self.assertTrue(result['keepAwake'])
        self.assertIsNone(result['resetAt'])

    def test_completed_interrupted_cancelled_runs_clear_old_quota(self):
        self.blocked()
        for status in ['completed', 'interrupted', 'cancelled']:
            self.run_record(run_id='new-run', ordinal=2, status=status, completed=NOW)
            result = self.read()
            self.assertFalse(result['keepAwake'])
            self.assertIsNone(result['resetAt'])

    def test_queued_and_unstarted_cancelled_runs_do_not_hide_failed_run(self):
        self.blocked()
        for status in ['queued', 'cancelled']:
            self.run_record(run_id='not-executed', ordinal=2, status=status, started=False)
            self.assertIsNotNone(self.read()['wakeAt'])

    def test_opt_out_stale_identity_and_provider_switch_cancel_wake(self):
        self.blocked()
        for recovery in [None, {'runId': 'old-run', 'resetAt': iso(NOW + 1800), 'autoResume': True},
                         {'runId': 'run-codex', 'resetAt': iso(NOW + 1900), 'autoResume': True},
                         {'runId': 'run-codex', 'resetAt': iso(NOW + 1800), 'autoResume': False}]:
            self.metadata(limitRecovery=recovery)
            self.assertIsNone(self.read()['wakeAt'])
        self.blocked()
        self.db.execute('UPDATE orchestration_v2_projection_threads SET provider_instance_id="other"')
        self.assertIsNone(self.read()['wakeAt'])

    def test_archived_deleted_settled_and_snoozed_threads(self):
        for column in ['archived_at', 'deleted_at']:
            self.blocked()
            self.db.execute(f'UPDATE orchestration_v2_projection_threads SET {column}=?', (iso(NOW),))
            self.assertIsNone(self.read()['wakeAt'])
        self.blocked()
        self.metadata(settledOverride='settled')
        self.assertIsNone(self.read()['wakeAt'])
        self.blocked()
        self.metadata(snoozedUntil=iso(NOW + 1900))
        self.assertAlmostEqual(self.read()['wakeAt'], int(NOW + 1780), delta=1)
        self.metadata(snoozedUntil=iso(NOW + 1800))
        self.assertIsNotNone(self.read()['wakeAt'])

    def test_delegated_child_of_settled_parent_is_ignored_unless_running(self):
        self.thread('parent', 'claudeAgent', status='completed')
        self.thread('child', 'claudeAgent', status='failed', reset=NOW + 1800,
                    lineage=dict(relationshipToParent='subagent', parentThreadId='parent'))
        self.assertIsNotNone(self.read()['wakeAt'])
        self.db.execute('UPDATE orchestration_v2_projection_threads SET payload_json=json_set(payload_json,'
                        "'$.settledOverride','settled') WHERE thread_id='parent'")
        result = self.read()
        self.assertIsNone(result['wakeAt'])
        self.assertNotIn('t3:child', result['mergedIDs'])
        self.run_record('child', status='running', ordinal=2, run_id='child-2', completed=NOW)
        self.assertIn('t3:child', self.read()['mergedIDs'])

    def test_permission_and_question_requests_allow_sleep(self):
        self.db.execute('INSERT INTO orchestration_v2_projection_runtime_requests VALUES (?,"pending",?)',
                        ('codex', iso(NOW - 2)))
        result = self.read()
        self.assertFalse(result['keepAwake'])
        self.assertAlmostEqual(result['records'][0]['since'], NOW - 2, delta=.002)
        self.blocked()
        self.assertIsNone(self.read()['wakeAt'])

    def test_non_quota_failure_and_subagent_errors_do_not_arm(self):
        self.blocked()
        self.db.execute('UPDATE orchestration_v2_projection_turn_items SET node_id="child"')
        self.assertIsNone(self.read()['wakeAt'])
        self.blocked()
        self.db.execute("UPDATE orchestration_v2_projection_turn_items SET payload_json=json_set(payload_json,'$.failure.class','other')")
        self.assertIsNone(self.read()['wakeAt'])

    def test_secret_request_waits_without_reading_secret_payload(self):
        self.db.execute('INSERT INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                        ('secret', 'codex', 'run-codex', 'root', 'secret_request', 'waiting', iso(NOW - 1), 2, '{}'))
        result = self.read()
        self.assertFalse(result['keepAwake'])
        self.assertAlmostEqual(result['records'][0]['since'], NOW - 1, delta=.002)

    def test_native_background_roster_holds_after_turn_completion(self):
        self.run_record(status='completed', completed=NOW - 300)
        self.db.execute("UPDATE orchestration_v2_projection_provider_threads SET payload_json=json_set(payload_json,'$.pendingBackgroundTasks',json(?),'$.updatedAt',?)",
                        (json.dumps([{'taskId': 'child', 'kind': 'subagent'}]), iso(NOW - 30)))
        result = self.read()
        self.assertTrue(result['keepAwake'])
        self.assertTrue(any(r['state'] == 'background' for r in result['records']))
        self.db.execute("UPDATE orchestration_v2_projection_provider_threads SET payload_json=json_set(payload_json,'$.pendingBackgroundTasks',json('[]'))")
        self.assertFalse(self.read()['keepAwake'])

    def test_background_items_hold_after_old_completed_turn(self):
        self.run_record(status='completed', completed=NOW - 600)
        for kind in ['command_execution', 'dynamic_tool', 'subagent']:
            self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                            ('background', 'codex', 'run-codex', 'child', kind, 'running', iso(NOW - 2), 2, '{}'))
            result = self.read()
            self.assertTrue(result['keepAwake'], kind)
            self.assertTrue(any(r['state'] == 'background' for r in result['records']))
        self.db.execute('UPDATE orchestration_v2_projection_turn_items SET status="completed"')
        self.assertFalse(self.read()['keepAwake'])

    def test_rolled_back_items_and_persistent_monitors_do_not_hold(self):
        self.run_record(status='completed', completed=NOW - 600)
        self.run_record(status='rolled_back', ordinal=0, run_id='rolled-back', completed=NOW - 1000)
        self.db.execute('INSERT INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                        ('old-background', 'codex', 'rolled-back', 'child', 'command_execution', 'running', iso(NOW - 1), 2, '{}'))
        self.db.execute('INSERT INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                        ('monitor', 'codex', 'run-codex', 'child', 'dynamic_tool', 'running', iso(NOW - 1), 3,
                         json.dumps({'input': {'persistent': True}})))
        self.assertFalse(self.read()['keepAwake'])

    def test_native_work_ages_without_real_progress(self):
        self.assertFalse(self.read(NOW + 3600)['keepAwake'])
        self.db.execute('INSERT INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                        ('progress', 'codex', 'run-codex', 'root', 'reasoning', 'running', iso(NOW + 3599), 2, '{}'))
        self.assertTrue(self.read(NOW + 3600)['keepAwake'])

    def test_archived_deleted_and_historical_threads_do_not_hide_terminal_hooks(self):
        for column in ['archived_at', 'deleted_at']:
            self.thread('codex', 'codex')
            self.db.execute(f'UPDATE orchestration_v2_projection_threads SET {column}=?', (iso(NOW),))
            self.assertEqual(self.read()['owned'], [])
        self.thread('codex', 'codex')
        self.run_record(status='completed', completed=NOW - 600)
        self.assertEqual(self.read()['owned'], [])

    def test_transient_read_cache_expires_and_never_hides_host_exit(self):
        broken = self.path / 'broken'
        broken.mkdir()
        (broken / 'server-runtime.json').write_text(json.dumps(self.runtime))
        self.db.commit()

        def cached(at):
            return json.loads(subprocess.check_output([BINARY, str(self.path), str(NOW), str(broken), str(at)], text=True))

        result = cached(NOW + 20)
        self.assertIsNotNone(result['error'])
        self.assertTrue(result['keepAwake'])
        self.assertEqual(result['owned'], ['codex:native-codex'])
        self.assertFalse(cached(NOW + 61)['keepAwake'])
        (broken / 'server-runtime.json').unlink()
        self.assertEqual(cached(NOW + 20)['records'], [])

    def test_closed_host_and_reused_pid_drop_native_records(self):
        for pid, started in [(2147483647, NOW), (os.getpid(), NOW - 10000)]:
            self.runtime.update(pid=pid, startedAt=iso(started))
            self.write_runtime()
            result = self.read()
            self.assertEqual(result['records'], [])
            self.assertEqual(result['owned'], [])

    def test_read_only_failure_falls_back_to_hooks(self):
        self.db.execute('DROP TABLE orchestration_v2_projection_runs')
        result = self.read()
        self.assertIsNotNone(result['error'])
        self.assertEqual(result['owned'], [])
        self.assertEqual(result['mergedIDs'], ['codex:native-codex'])

    def test_database_not_created_and_source_database_not_written(self):
        self.db.commit()
        before = self.db.execute('PRAGMA data_version').fetchone()[0]
        self.read()
        self.assertEqual(self.db.execute('PRAGMA data_version').fetchone()[0], before)
        self.db.commit()
        self.db.close()
        for file in self.path.glob('statev2.sqlite*'):
            file.unlink()
        result = json.loads(subprocess.check_output([BINARY, str(self.path), str(NOW)], text=True))
        self.assertIsNotNone(result['error'])
        self.assertFalse((self.path / 'statev2.sqlite').exists())

    def test_enable_native_setting_preserves_others_and_symlink(self):
        spec = importlib.util.spec_from_file_location('configure_t3', ROOT / 'scripts/configure-t3.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        target = self.path / 'actual.json'
        settings = {'unrelated': {'value': 42}, 'autoResumeLimitedThreads': False}
        target.write_text(json.dumps(settings))
        target.chmod(0o600)
        link = self.path / 'settings.json'
        link.symlink_to(target)
        self.assertTrue(module.enable_recovery(link))
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(target.read_text()), dict(settings, autoResumeLimitedThreads=True))
        self.assertTrue(module.enable_recovery(link))
        self.assertFalse(module.enable_recovery(self.path / 'missing.json'))

    def test_app_tracks_native_work_wait_alarm_and_continuation(self):
        state = self.path / 'power-app'
        state.mkdir()
        env = dict(os.environ, AGENT_LID_DRY_RUN='1', AGENT_LID_FAKE_LID='closed',
                   AGENT_LID_STATE_DIR=str(state), AGENT_LID_T3_DIR=str(self.path))
        self.db.commit()
        process = subprocess.Popen([str(APP / 'Contents/MacOS/AgentLidClosed'),
            '-autoEnabled', 'YES', '-dimDisplay', 'YES', '-wakeForQuotaReset', 'YES',
            '-notifyTimeoutSeconds', '0', '-sleepGraceSeconds', '0'], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        def wait_for(message, after=0):
            self.db.commit()
            for _ in range(120):
                log_path = state / 'AgentLidClosed.log'
                log = log_path.read_text() if log_path.exists() else ''
                if message in log[after:]:
                    return log
                if process.poll() is not None:
                    self.fail('App exited: ' + process.stderr.read().decode() + '\n' + log)
                time.sleep(.1)
            self.fail('Missing ' + message + '\n' + log)

        try:
            log = wait_for('[dry run] display brightness 0%')
            self.blocked()
            log = wait_for('[dry run] sleep now', len(log))
            self.assertIn('[dry run] wake helper set ', log)
            self.assertFalse((state / 'holding').exists())
            # A temporary schema/read error cannot clear the armed future alarm.
            self.db.execute('ALTER TABLE orchestration_v2_projection_runs RENAME TO temporarily_unavailable')
            self.db.commit()
            time.sleep(6)
            after_error = (state / 'AgentLidClosed.log').read_text()
            self.assertNotIn('[dry run] wake helper clear', after_error[len(log):])
            self.db.execute('ALTER TABLE temporarily_unavailable RENAME TO orchestration_v2_projection_runs')
            self.thread('codex', 'codex', status='failed', reset=time.time() + 60)
            log = wait_for('Keeping Mac awake: usage resets shortly', len(log))
            self.assertTrue((state / 'holding').exists())
            (state / 'thermal-serious').touch()
            log = wait_for('[dry run] sleep now', len(log))
            self.assertFalse((state / 'holding').exists())
            self.assertIn('[dry run] wake helper clear', log)
            (state / 'thermal-serious').unlink()
            log = wait_for('Keeping Mac awake: usage resets shortly', len(log))
            self.run_record(run_id='native-resumed-turn', ordinal=2)
            log = wait_for('t3-project working', len(log))
            self.assertTrue((state / 'holding').exists())
            self.run_record(run_id='native-resumed-turn', ordinal=2, status='completed', completed=time.time())
            wait_for('[dry run] sleep now', len(log))
            self.assertFalse((state / 'holding').exists())
            self.assertFalse((state / 'sessions').exists() and list((state / 'sessions').glob('*.json')))
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=15)


unittest.main()
