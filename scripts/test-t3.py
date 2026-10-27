#!/usr/bin/env python3
"""T3 bridge tests use isolated WAL databases and never start or message an agent."""
import base64
import datetime
import hashlib
import importlib.util
import json
import os
import pathlib
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = sys.argv.pop(1)
APP = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else ROOT / 'build/AgentLidClosed.app').resolve()
NOW = time.time()


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

SELECTION = {'instanceId': 'claudeAgent', 'model': 'claude-opus-5-5', 'options': [{'id': 'effort', 'value': 'xhigh'}]}
WEBSOCKET_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class FakeT3Server(threading.Thread):
    """Just enough of T3's WebSocket RPC to answer dispatchCommand requests."""

    def __init__(self, exit_for):
        super().__init__(daemon=True)
        self.exit_for = exit_for
        self.listener = socket.create_server(('127.0.0.1', 0))
        self.port = self.listener.getsockname()[1]
        self.upgrades = []
        self.requests = []

    def run(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(connection,), daemon=True).start()

    def close(self):
        self.listener.close()

    @staticmethod
    def read_exactly(connection, buffer, count):
        while len(buffer) < count:
            chunk = connection.recv(65536)
            if not chunk:
                raise EOFError
            buffer += chunk
        return buffer[:count], buffer[count:]

    def serve(self, connection):
        with connection:
            try:
                data = b''
                while b'\r\n\r\n' not in data:
                    chunk = connection.recv(65536)
                    if not chunk:
                        return
                    data += chunk
                head, buffer = data.split(b'\r\n\r\n', 1)
                lines = head.decode().split('\r\n')
                headers = {name.strip().lower(): value.strip() for name, value in
                           (line.split(':', 1) for line in lines[1:] if ':' in line)}
                self.upgrades.append((lines[0], headers))
                accept = base64.b64encode(hashlib.sha1((headers['sec-websocket-key'] + WEBSOCKET_GUID).encode()).digest())
                connection.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                                   b'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
                while True:
                    header, buffer = self.read_exactly(connection, buffer, 2)
                    opcode, length = header[0] & 0x0F, header[1] & 0x7F
                    if length == 126:
                        extended, buffer = self.read_exactly(connection, buffer, 2)
                        length = int.from_bytes(extended, 'big')
                    elif length == 127:
                        extended, buffer = self.read_exactly(connection, buffer, 8)
                        length = int.from_bytes(extended, 'big')
                    mask, buffer = self.read_exactly(connection, buffer, 4) if header[1] & 0x80 else (b'\0' * 4, buffer)
                    payload, buffer = self.read_exactly(connection, buffer, length)
                    payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
                    if opcode == 8:
                        return
                    if opcode != 1:
                        continue
                    request = json.loads(payload)
                    if request.get('_tag') == 'Ping':
                        reply = b'{"_tag":"Pong"}'
                    else:
                        self.requests.append(request)
                        reply = json.dumps({'_tag': 'Exit', 'requestId': request['id'],
                                            'exit': self.exit_for(request['payload'])}).encode()
                    size = len(reply)
                    prefix = bytes([0x81, size]) if size < 126 else bytes([0x81, 126]) + size.to_bytes(2, 'big')
                    connection.sendall(prefix + reply)
            except (EOFError, OSError):
                return


class T3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='agent-lid-t3-')
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name)
        self.instances = {}
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
          CREATE TABLE orchestration_v2_projection_provider_sessions
            (provider_session_id TEXT PRIMARY KEY, provider_instance_id TEXT, updated_at TEXT, payload_json TEXT);
          CREATE TABLE orchestration_v2_projection_provider_session_bindings
            (thread_id TEXT, provider_session_id TEXT);
          CREATE TABLE orchestration_v2_projection_turn_items
            (turn_item_id TEXT PRIMARY KEY, thread_id TEXT, run_id TEXT, node_id TEXT,
             type TEXT, status TEXT, updated_at TEXT, ordinal INTEGER, payload_json TEXT);
          CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, workspace_root TEXT);
          INSERT INTO projection_projects VALUES ('project', '/tmp/t3-project');
        ''')
        self.thread('codex', 'codex')

    def write_runtime(self):
        (self.path / 'server-runtime.json').write_text(json.dumps(self.runtime))

    def thread(self, key, driver, status='running', reset=None, auto=True, instance=None, **metadata):
        instance = instance or 'instance-' + driver
        self.instances[key] = instance
        recovery = dict(runId='run-' + key, resetAt=iso(reset), autoResume=auto) if reset else None
        payload = dict(limitRecovery=recovery, settledOverride=None)
        payload.update(metadata)
        self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_threads VALUES (?,?,?,NULL,NULL,?)',
                        (key, 'project', instance, json.dumps(payload)))
        self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_provider_threads VALUES (?,?,?)',
                        ('pt-' + key, driver, json.dumps({'nativeThreadRef': {'nativeId': 'native-' + key}})))
        self.run_record(key, status=status)
        if reset:
            self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                            ('error-' + key, key, 'run-' + key, 'root', 'error', 'failed', iso(NOW - 30), 1,
                             json.dumps({'failure': {'class': 'usage_limit', 'resetAt': iso(reset)}})))

    def run_record(self, key='codex', status='running', ordinal=1, run_id=None, completed=None, started=True,
                   started_at=None):
        run_id = run_id or 'run-' + key
        terminal = status in ['failed', 'completed', 'cancelled', 'interrupted', 'rolled_back']
        payload = dict(rootNodeId='root', startedAt=iso(started_at or NOW - 40) if started else None)
        self.db.execute('INSERT OR REPLACE INTO orchestration_v2_projection_runs VALUES (?,?,?,?,?,?,?,?,?)',
                        (run_id, key, ordinal, self.instances[key],
                         'pt-' + key, status, iso(NOW - 50),
                         iso(completed if completed is not None else NOW - 30) if terminal else None,
                         json.dumps(payload)))

    def read(self, now=NOW, hook_pid=None, hook_quota=False):
        self.db.commit()
        env = dict(os.environ)
        if hook_pid is not None:
            env['AGENT_LID_TEST_HOOK_PID'] = str(hook_pid)
        if hook_quota:
            env['AGENT_LID_TEST_HOOK_QUOTA'] = '1'
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

    def test_t3_ownership_survives_retirement_but_independent_terminals_remain(self):
        for column in ['archived_at', 'deleted_at']:
            self.thread('codex', 'codex')
            self.db.execute(f'UPDATE orchestration_v2_projection_threads SET {column}=?', (iso(NOW),))
            self.assertEqual(self.read()['owned'], ['codex:native-codex'])
            self.assertEqual(self.read(hook_pid=os.getpid())['mergedIDs'], [])
            self.assertEqual(self.read(hook_pid=os.getppid())['mergedIDs'], ['codex:native-codex'])
        self.thread('codex', 'codex')
        self.run_record(status='completed', completed=NOW - 600)
        self.assertEqual(self.read()['owned'], ['codex:native-codex'])
        self.assertEqual(self.read(hook_pid=os.getpid())['mergedIDs'], [])

    def test_settled_and_opted_out_t3_hooks_cannot_schedule_terminal_wakes(self):
        for recovery in [None, dict(runId='run-codex', resetAt=iso(NOW + 1800), autoResume=False)]:
            self.blocked()
            self.metadata(limitRecovery=recovery)
            result = self.read(hook_pid=os.getpid(), hook_quota=True)
            self.assertEqual(result['mergedIDs'], [])
            self.assertIsNone(result['mergedWakeAt'])
            self.assertFalse(result['mergedKeepAwake'])
        self.blocked()
        self.metadata(settledOverride='settled')
        result = self.read(hook_pid=os.getpid(), hook_quota=True)
        self.assertEqual(result['records'], [])
        self.assertEqual(result['mergedIDs'], [])
        self.assertIsNone(result['mergedWakeAt'])
        self.assertIsNotNone(self.read(hook_pid=os.getppid(), hook_quota=True)['mergedWakeAt'])

    def test_nested_delegates_under_retired_ancestor_do_not_schedule(self):
        self.thread('root', 'claudeAgent', status='completed', settledOverride='settled')
        self.thread('parent', 'claudeAgent', status='completed',
                    lineage=dict(relationshipToParent='subagent', parentThreadId='root'))
        self.thread('codex', 'codex', status='failed', reset=NOW + 1800,
                    lineage=dict(relationshipToParent='subagent', parentThreadId='parent'))
        result = self.read(hook_pid=os.getpid(), hook_quota=True)
        self.assertNotIn('t3:codex', result['mergedIDs'])
        self.assertIsNone(result['mergedWakeAt'])
        self.assertNotIn('t3:parent', result['mergedIDs'])
        # A fork is an independent task, rather than a retired parent's delegate.
        self.metadata(lineage=dict(relationshipToParent='fork', parentThreadId='root'))
        self.assertIsNotNone(self.read()['wakeAt'])

    def test_reopened_delegate_and_running_grandchild_remain_visible(self):
        self.thread('root', 'claudeAgent', status='completed', settledOverride='settled')
        self.thread('parent', 'claudeAgent', status='completed',
                    lineage=dict(relationshipToParent='subagent', parentThreadId='root'))
        self.thread('codex', 'codex', status='failed', reset=NOW + 1800,
                    settledOverride='active', lineage=dict(relationshipToParent='subagent', parentThreadId='parent'))
        self.assertIsNotNone(self.read()['wakeAt'])
        self.metadata(settledOverride=None)
        self.assertIsNone(self.read()['wakeAt'])
        self.run_record(run_id='actually-working', ordinal=2)
        self.assertTrue(self.read()['keepAwake'])
        self.assertIn('t3:codex', self.read()['mergedIDs'])

    def test_null_and_cyclic_retired_lineages_do_not_hide_unrelated_work(self):
        self.db.execute('INSERT INTO orchestration_v2_projection_threads VALUES (NULL,?,?,NULL,NULL,?)',
                        ('project', 'instance-codex', json.dumps({'settledOverride': 'settled'})))
        self.thread('first', 'claudeAgent', status='completed', settledOverride='settled',
                    lineage=dict(relationshipToParent='subagent', parentThreadId='second'))
        self.thread('second', 'claudeAgent', status='failed', reset=NOW + 1800,
                    lineage=dict(relationshipToParent='subagent', parentThreadId='first'))
        self.blocked()
        result = self.read()
        self.assertIsNotNone(result['wakeAt'])
        self.assertEqual([r['id'] for r in result['records']], ['t3:codex'])

    def test_two_claude_accounts_and_codex_keep_distinct_identity_and_limits(self):
        (self.path / 'settings.json').write_text(json.dumps({'providerInstances': {
            'claudeAgent': {'driver': 'claudeAgent'},
            'claudeAgent_second': {'driver': 'claudeAgent', 'displayName': 'Claude - Second'},
            'instance-codex': {'driver': 'codex', 'displayName': 'ChatGPT - Personal'}}}))
        self.thread('main', 'claudeAgent', status='failed', reset=NOW + 1800, instance='claudeAgent')
        self.thread('second', 'claudeAgent', status='running', instance='claudeAgent_second')
        result = self.read()
        self.assertTrue(result['keepAwake'])
        by_id = {r['id']: r for r in result['records']}
        self.assertEqual(by_id['t3:main']['accountName'], 'Claude')
        self.assertEqual(by_id['t3:second']['accountName'], 'Claude - Second')
        self.assertEqual(by_id['t3:codex']['accountName'], 'Codex (ChatGPT - Personal)')
        self.assertEqual(result['resetAccount'], 'Claude')
        self.thread('second', 'claudeAgent', status='failed', reset=NOW + 900, instance='claudeAgent_second')
        self.assertEqual(self.read()['resetAccount'], 'Claude - Second')
        self.db.execute("UPDATE orchestration_v2_projection_threads SET payload_json=json_set(payload_json,'$.settledOverride','settled') WHERE thread_id='second'")
        self.assertEqual(self.read()['resetAccount'], 'Claude')

    def test_session_errors_are_scoped_to_the_failed_runs_account(self):
        self.blocked()
        self.db.execute("UPDATE orchestration_v2_projection_turn_items SET payload_json=json_set(payload_json,'$.failure.message','quota')")
        self.db.execute('INSERT INTO orchestration_v2_projection_provider_sessions VALUES (?,?,?,?)',
                        ('other-account', 'other-instance', iso(NOW), json.dumps({'lastError': 'authentication'})))
        self.db.execute('INSERT INTO orchestration_v2_projection_provider_session_bindings VALUES (?,?)', ('codex', 'other-account'))
        self.assertIsNotNone(self.read()['wakeAt'])
        self.db.execute('INSERT INTO orchestration_v2_projection_provider_sessions VALUES (?,?,?,?)',
                        ('correct-account', 'instance-codex', iso(NOW), json.dumps({'lastError': 'quota'})))
        self.db.execute('INSERT INTO orchestration_v2_projection_provider_session_bindings VALUES (?,?)', ('codex', 'correct-account'))
        self.assertIsNotNone(self.read()['wakeAt'])
        self.db.execute("UPDATE orchestration_v2_projection_provider_sessions SET payload_json=? WHERE provider_session_id='correct-account'",
                        (json.dumps({'lastError': 'authentication'}),))
        self.assertIsNone(self.read()['wakeAt'])

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
        self.assertEqual(cached(NOW + 61)['owned'], ['codex:native-codex'])
        self.assertEqual(cached(NOW + 61)['mergedIDs'], [])
        (broken / 'server-runtime.json').unlink()
        self.assertEqual(cached(NOW + 20)['records'], [])

    def test_closed_host_and_reused_pid_drop_native_records(self):
        for pid, started in [(2147483647, NOW), (os.getpid(), NOW - 10000)]:
            self.runtime.update(pid=pid, startedAt=iso(started))
            self.write_runtime()
            result = self.read()
            self.assertEqual(result['records'], [])
            self.assertEqual(result['owned'], [])

    def test_activity_read_failure_keeps_native_ownership_and_independent_hooks(self):
        self.db.execute('DROP TABLE orchestration_v2_projection_runs')
        result = self.read()
        self.assertIsNotNone(result['error'])
        self.assertEqual(result['owned'], ['codex:native-codex'])
        self.assertEqual(result['mergedIDs'], [])
        self.assertEqual(self.read(hook_pid=os.getppid())['mergedIDs'], ['codex:native-codex'])

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

    def two_claude_accounts(self):
        (self.path / 'settings.json').write_text(json.dumps({'providerInstances': {
            'claudeAgent': {'driver': 'claudeAgent'},
            'claudeAgent_second': {'driver': 'claudeAgent', 'displayName': 'Claude - Second'},
            'instance-codex': {'driver': 'codex', 'displayName': 'ChatGPT - Personal'}}}))

    def limited_claude(self, key='main', instance='claudeAgent', reset=NOW + 1800, **metadata):
        metadata.setdefault('modelSelection', dict(SELECTION, instanceId=instance))
        self.thread(key, 'claudeAgent', status='failed', reset=reset, instance=instance, **metadata)

    def test_limited_conversation_switches_to_the_other_claude_account(self):
        self.two_claude_accounts()
        self.limited_claude()
        result = self.read()
        [limited] = result['limited']
        self.assertEqual((limited['thread'], limited['run'], limited['account']), ('main', 'run-main', 'claudeAgent'))
        self.assertIs(limited['autoResume'], True)
        self.assertFalse(limited['delegated'])
        self.assertEqual(json.loads(limited['selection']), SELECTION)
        self.assertAlmostEqual(result['limitedUntil']['claudeAgent'], NOW + 1800, delta=.002)
        self.assertEqual([account['id'] for account in result['accounts']],
                         ['claudeAgent', 'claudeAgent_second', 'codex', 'instance-codex'])
        self.assertEqual(result['switches'], ['main:claudeAgent->claudeAgent_second'])

    def test_other_account_stays_limited_until_a_later_run_completes(self):
        self.two_claude_accounts()
        self.limited_claude()
        self.limited_claude('second', instance='claudeAgent_second', reset=NOW + 900)
        result = self.read()
        self.assertEqual(result['switches'], [])
        self.assertAlmostEqual(result['limitedUntil']['claudeAgent_second'], NOW + 900, delta=.002)
        # A run that started before the failure proves nothing.
        self.thread('earlier', 'claudeAgent', status='completed', instance='claudeAgent_second')
        self.assertEqual(self.read()['switches'], [])
        self.run_record('earlier', status='completed', started_at=NOW - 20, completed=NOW - 10)
        result = self.read()
        self.assertNotIn('claudeAgent_second', result['limitedUntil'])
        self.assertEqual(result['switches'], ['main:claudeAgent->claudeAgent_second'])

    def test_switch_respects_manual_change_requests_children_and_other_errors(self):
        self.two_claude_accounts()
        self.limited_claude()
        self.db.execute("UPDATE orchestration_v2_projection_threads SET provider_instance_id='claudeAgent_second'")
        self.assertEqual(self.read()['limited'], [])
        self.limited_claude()
        self.db.execute('INSERT INTO orchestration_v2_projection_runtime_requests VALUES (?,?,?)', ('main', 'pending', iso(NOW)))
        self.assertEqual(self.read()['limited'], [])
        self.db.execute('DELETE FROM orchestration_v2_projection_runtime_requests')
        self.limited_claude(lineage={'relationshipToParent': 'subagent', 'parentThreadId': 'parent'})
        result = self.read()
        self.assertTrue(result['limited'][0]['delegated'])
        self.assertEqual(result['switches'], [])
        self.limited_claude(auto=False)
        result = self.read()
        self.assertIs(result['limited'][0]['autoResume'], False)
        self.assertEqual(result['switches'], [])
        self.limited_claude()
        self.db.execute("UPDATE orchestration_v2_projection_turn_items SET payload_json=json_set(payload_json,'$.failure.class','provider_error')")
        result = self.read()
        self.assertEqual((result['limited'], result['limitedUntil']), ([], {}))

    def test_account_settings_are_read_leniently(self):
        self.maxDiff = None
        settings = {'providerInstances': {
            'claudeAgent': {'driver': 'claudeAgent', 'config': {'customModels': ['custom-a', {'slug': 'b'}, 7]}},
            'claudeAgent_second': {'driver': 'claudeAgent', 'displayName': 'Claude - Second', 'enabled': True,
                                   'config': {'enabled': False}},
            'claudeAgent_third': {'driver': 'claudeAgent', 'displayName': 'Claude - Third'},
            'odd': {'driver': 5, 'enabled': 'yes'}},
            'projectSettingsOverrides': {'project': {'providerInstances': {'claudeAgent_third': {'enabled': False}}},
                                         'broken': 3}}
        (self.path / 'settings.json').write_text(json.dumps(settings))
        self.limited_claude()
        result = self.read()
        self.assertEqual(result['accounts'], [
            {'id': 'claudeAgent', 'driver': 'claudeAgent', 'name': 'Claude', 'enabled': True, 'configured': True,
             'projectEnabled': {}, 'customModels': ['b', 'custom-a']},
            {'id': 'claudeAgent_second', 'driver': 'claudeAgent', 'name': 'Claude - Second', 'enabled': False,
             'configured': True, 'projectEnabled': {}, 'customModels': []},
            {'id': 'claudeAgent_third', 'driver': 'claudeAgent', 'name': 'Claude - Third', 'enabled': True,
             'configured': True, 'projectEnabled': {'project': False}, 'customModels': []},
            {'id': 'codex', 'driver': 'codex', 'name': 'Codex', 'enabled': True, 'configured': False,
             'projectEnabled': {}, 'customModels': []}])
        # The only enabled other account is disabled for this conversation's project.
        self.assertEqual(result['switches'], [])
        settings['projectSettingsOverrides'] = {}
        (self.path / 'settings.json').write_text(json.dumps(settings))
        self.assertEqual(self.read()['switches'], ['main:claudeAgent->claudeAgent_third'])
        settings['autoResumeLimitedThreads'] = False
        (self.path / 'settings.json').write_text(json.dumps(settings))
        result = self.read()
        self.assertTrue(result['continuationDisabled'])
        self.assertEqual(result['switches'], [])

    def test_monitor_keeps_a_just_reset_account_limited_for_the_margin(self):
        self.two_claude_accounts()
        self.limited_claude(reset=NOW + 7200)
        self.limited_claude('second', instance='claudeAgent_second', reset=NOW + 900)
        result = self.read(now=NOW + 930)
        self.assertAlmostEqual(result['limitedUntil']['claudeAgent_second'], NOW + 900, delta=.002)
        self.assertEqual(result['switches'], [])
        self.assertEqual(self.read(now=NOW + 961)['switches'], ['main:claudeAgent->claudeAgent_second'])

    def start_switching_app(self, exit_for, issue_delay=0):
        """Runs the app against a fake T3 server and CLI; returns (server, wait_for, log path, CLI calls)."""
        server = FakeT3Server(exit_for)
        server.start()
        self.addCleanup(server.close)
        home = self.path / 'home'
        (home / 'bin').mkdir(parents=True)
        (home / 'userdata').symlink_to(self.path)
        cli = home / 'bin/t3'
        cli.write_text('#!/bin/sh\necho "$@" >> "$(dirname "$0")/calls.log"\n'
                       'case "$*" in *"session issue"*) sleep %d; '
                       'printf \'{"sessionId":"session-1","token":"secret-token"}\' ;; esac\n' % issue_delay)
        cli.chmod(0o755)
        self.runtime['port'] = server.port
        self.write_runtime()
        self.db.execute("DELETE FROM orchestration_v2_projection_threads WHERE thread_id='codex'")
        self.two_claude_accounts()
        self.limited_claude()
        self.db.commit()
        state = self.path / 'switch-app'
        state.mkdir()
        env = dict(os.environ, AGENT_LID_DRY_RUN='1', AGENT_LID_STATE_DIR=str(state),
                   AGENT_LID_T3_DIR=str(home / 'userdata'))
        process = subprocess.Popen([str(APP / 'Contents/MacOS/AgentLidClosed'),
            '-autoEnabled', 'YES', '-dimDisplay', 'NO', '-wakeForQuotaReset', 'YES', '-switchAccountAtLimit', 'YES',
            '-notifyTimeoutSeconds', '0', '-sleepGraceSeconds', '0'], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        def stop():
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=15)
        self.addCleanup(stop)
        log_path = state / 'AgentLidClosed.log'

        def wait_for(message):
            for _ in range(150):
                log = log_path.read_text() if log_path.exists() else ''
                if message in log:
                    return log
                if process.poll() is not None:
                    self.fail('App exited: ' + process.stderr.read().decode() + '\n' + log)
                time.sleep(.1)
            self.fail('Missing ' + message + '\n' + log)
        return server, wait_for, log_path, home / 'bin/calls.log'

    def test_app_moves_a_limited_conversation_through_t3s_command_api(self):
        server, wait_for, log_path, calls_path = self.start_switching_app(
            lambda payload: {'_tag': 'Success', 'value': {'sequence': 7}})
        log = wait_for('Continued t3-project on Claude - Second')
        self.assertIn('Claude reached its usage limit: moving t3-project to Claude - Second', log)
        [(request_line, headers)] = server.upgrades
        self.assertEqual(request_line, 'GET /ws?orchestrationProtocol=2 HTTP/1.1')
        self.assertEqual(headers['authorization'], 'Bearer secret-token')
        [request] = server.requests
        self.assertEqual(request['tag'], 'orchestration.dispatchCommand')
        command = request['payload']
        self.assertEqual((command['type'], command['threadId'], command['manualContinuationOfRunId']),
                         ('message.dispatch', 'main', 'run-main'))
        self.assertEqual(command['modelSelection'], dict(SELECTION, instanceId='claudeAgent_second'))
        calls = calls_path.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn('auth session issue', calls[0])
        self.assertIn('--scope orchestration:operate', calls[0])
        self.assertIn('--ttl 5m', calls[0])
        self.assertTrue(calls[1].startswith('auth session revoke') and calls[1].endswith('session-1'))
        # Until T3 starts the continued run, the Mac stays awake and nothing is sent twice.
        wait_for('Keeping Mac awake: an agent is working')
        time.sleep(6)
        self.assertEqual(len(server.requests), 1)
        self.assertNotIn('secret-token', log_path.read_text())
        # The continued run also hits its limit. The first account is still limited, so
        # the conversation waits there instead of moving back.
        self.run_record('main', status='failed', ordinal=2, run_id='run-2', completed=time.time())
        self.db.execute("UPDATE orchestration_v2_projection_runs SET provider_instance_id='claudeAgent_second' WHERE run_id='run-2'")
        self.db.execute('INSERT INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?,?,?)',
                        ('error-2', 'main', 'run-2', 'root', 'error', 'failed', iso(time.time()), 2,
                         json.dumps({'failure': {'class': 'usage_limit', 'resetAt': iso(NOW + 3600)}})))
        self.db.execute("UPDATE orchestration_v2_projection_threads SET provider_instance_id='claudeAgent_second', "
                        "payload_json=json_set(payload_json,'$.modelSelection.instanceId','claudeAgent_second')")
        self.db.commit()
        result = self.read()
        self.assertEqual(result['switches'], [])
        self.assertAlmostEqual(result['limitedUntil']['claudeAgent_second'], NOW + 3600, delta=.002)
        time.sleep(6)
        self.assertEqual(len(server.requests), 1)

    def test_app_withdraws_a_switch_snoozed_while_the_credential_is_issued(self):
        server, wait_for, log_path, calls_path = self.start_switching_app(
            lambda payload: {'_tag': 'Success', 'value': {'sequence': 7}}, issue_delay=3)
        wait_for('moving t3-project to Claude - Second')
        self.db.execute("UPDATE orchestration_v2_projection_threads SET payload_json=json_set(payload_json,'$.snoozedUntil',?)",
                        (iso(time.time() + 3600),))
        self.db.commit()
        wait_for("Didn't move t3-project: it changed before the switch was sent")
        self.assertEqual(server.requests, [])
        # The credential was still revoked.
        self.assertTrue(calls_path.read_text().splitlines()[-1].startswith('auth session revoke'))

    def test_app_sends_the_selection_current_at_delivery(self):
        server, wait_for, log_path, _ = self.start_switching_app(
            lambda payload: {'_tag': 'Success', 'value': {'sequence': 7}}, issue_delay=3)
        wait_for('moving t3-project to Claude - Second')
        self.db.execute("UPDATE orchestration_v2_projection_threads SET payload_json="
                        "json_set(payload_json,'$.modelSelection.options[0].value','low')")
        self.db.commit()
        wait_for("Didn't move t3-project: it changed before the switch was sent")
        wait_for('Continued t3-project on Claude - Second')
        [request] = server.requests
        self.assertEqual(request['payload']['modelSelection']['options'], [{'id': 'effort', 'value': 'low'}])

    def test_app_does_not_repeat_a_refused_switch(self):
        server, wait_for, log_path, _ = self.start_switching_app(lambda payload: {'_tag': 'Failure', 'cause': [
            {'_tag': 'Fail', 'error': {'_tag': 'OrchestrationV2DispatchCommandError',
                                       'message': 'This thread can no longer be resumed from that run.'}}]})
        wait_for('T3 refused to move t3-project to Claude - Second: This thread can no longer be resumed from that run.')
        # The hold covered only the delivery; the conversation now waits for its own reset.
        wait_for('Sleep allowed: all agents are waiting for you')
        self.assertIn('Wake scheduled for usage reset', log_path.read_text())
        time.sleep(6)
        self.assertEqual(len(server.requests), 1)

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
