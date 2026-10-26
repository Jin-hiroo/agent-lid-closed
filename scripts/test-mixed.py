#!/usr/bin/env python3
"""Exercise both providers in one app, with temporary state and no real power changes."""
import datetime
import json
import math
import os
import pathlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/AgentLidClosed.app').resolve()
with tempfile.TemporaryDirectory(prefix='agent-lid-mixed-') as temp:
    state = pathlib.Path(temp)
    transcript = state / 'codex.jsonl'
    transcript.touch()
    env = dict(os.environ, AGENT_LID_DRY_RUN='1', AGENT_LID_FAKE_LID='closed', AGENT_LID_STATE_DIR=temp)
    hook = app / 'Contents/Helpers/agent-lid-hook'

    def event(provider, name, **fields):
        payload = dict(hook_event_name=name, session_id='mixed', cwd='/tmp/' + provider + '-mixed', **fields)
        if provider == 'codex':
            payload.setdefault('turn_id', 'turn-1')
            payload['transcript_path'] = str(transcript)
        result = subprocess.run([str(hook), '--provider', provider], input=json.dumps(payload),
                                text=True, env=env, capture_output=True, check=True)
        assert not result.stdout

    def codex_record(kind, **fields):
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds')
        with transcript.open('a') as out:
            out.write(json.dumps(dict(timestamp=timestamp, type='event_msg', payload=dict(type=kind, **fields))) + '\n')

    def codex_limits(reset):
        codex_record('token_count', rate_limits={'primary': {'used_percent': 100, 'resets_at': reset}})

    def claude_limit(reset):
        subprocess.run([str(hook), 'statusline'], input=json.dumps({'session_id': 'mixed', 'rate_limits': {
            'five_hour': {'used_percentage': 100, 'resets_at': reset}}}),
                       text=True, env=env, capture_output=True, check=True)
        event('claude', 'StopFailure', error='rate_limit')

    event('claude', 'UserPromptSubmit')
    event('codex', 'UserPromptSubmit')
    process = subprocess.Popen([str(app / 'Contents/MacOS/AgentLidClosed'),
                                '-autoEnabled', 'YES', '-dimDisplay', 'YES', '-wakeForQuotaReset', 'YES',
                                '-notifyTimeoutSeconds', '0', '-sleepGraceSeconds', '0'],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def wait_for(message, after=0):
        for _ in range(150):
            log = (state / 'AgentLidClosed.log').read_text() if (state / 'AgentLidClosed.log').exists() else ''
            if message in log[after:]:
                return log
            if process.poll() is not None:
                raise RuntimeError('App exited: ' + process.stderr.read().decode() + '\n' + log)
            time.sleep(.1)
        raise RuntimeError('Missing ' + message + '\n' + log)

    try:
        log = wait_for('[dry run] display brightness 0%')
        offset = len(log)
        event('claude', 'Stop')
        log = wait_for('Claude · claude-mixed waiting', offset)
        assert (state / 'holding').exists() and '[dry run] sleep now' not in log[offset:]
        event('codex', 'Stop')
        log = wait_for('[dry run] sleep now', len(log))
        print('PASS mixed: stopping Claude keeps Codex awake; stopping both allows sleep')

        event('codex', 'UserPromptSubmit')
        log = wait_for('Keeping Mac awake: an agent is working', len(log))
        codex_reset = time.time() + 600
        codex_limits(codex_reset)
        codex_record('error', turn_id='turn-1', codex_error_info='usage_limit_exceeded')
        # A normal Stop hook can follow error bookkeeping; it must not hide the quota failure.
        event('codex', 'Stop')
        log = wait_for('[dry run] wake helper set ' + str(math.floor(codex_reset - 120)), len(log))
        wait_for('Codex · codex-mixed waiting for usage reset')
        claude_reset = time.time() + 360
        claude_limit(claude_reset)
        log = wait_for('[dry run] wake helper set ' + str(math.floor(claude_reset - 120)), len(log))
        event('claude', 'SessionEnd')
        log = wait_for('[dry run] wake helper set ' + str(math.floor(codex_reset - 120)), len(log))
        print('PASS mixed: one alarm follows the earliest reset; ending that session restores the other alarm')

        codex_limits(time.time() + 60)
        log = wait_for('Keeping Mac awake: usage resets shortly', len(log))
        assert (state / 'holding').exists()
        event('claude', 'UserPromptSubmit')
        log = wait_for('Claude · claude-mixed working', len(log))
        offset = len(log)
        event('codex', 'Interrupt')
        log = wait_for('Codex · codex-mixed waiting for you (interrupted)', offset)
        assert (state / 'holding').exists() and '[dry run] sleep now' not in log[offset:]
        event('claude', 'Stop')
        log = wait_for('[dry run] sleep now', len(log))
        print('PASS mixed: cancelling Codex warm-up preserves a working Claude hold')

        event('codex', 'UserPromptSubmit', turn_id='turn-2')
        log = wait_for('Keeping Mac awake: an agent is working', len(log))
        codex_reset = time.time() + 600
        codex_limits(codex_reset)
        codex_record('error', turn_id='turn-2', codex_error_info='usage_limit_exceeded')
        log = wait_for('[dry run] wake helper set ' + str(math.floor(codex_reset - 120)), len(log))
        codex_record('task_started', turn_id='turn-3')
        offset = len(log)
        log = wait_for('Usage wake cleared', offset)
        log = wait_for('Keeping Mac awake: an agent is working', offset)
        assert (state / 'holding').exists()
        event('codex', 'Stop', turn_id='turn-3')
        wait_for('[dry run] sleep now', len(log))
        print('PASS mixed: Codex becoming active clears its alarm and returns to the shared working hold')
    finally:
        process.terminate()
        process.wait(timeout=10)
