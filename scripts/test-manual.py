#!/usr/bin/env python3
"""Manual sleep disable: a timed hold ends and returns to agent tracking; an open-ended
hold works with Automatic Mode off. Dry run: no real power changes or preferences writes."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/AgentLidClosed.app').resolve()
hook = app / 'Contents/Helpers/agent-lid-hook'

with tempfile.TemporaryDirectory(prefix='agent-lid-manual-') as temp:
    state = pathlib.Path(temp)
    env = dict(os.environ, AGENT_LID_DRY_RUN='1', AGENT_LID_FAKE_LID='closed', AGENT_LID_STATE_DIR=temp)
    log_path = state / 'AgentLidClosed.log'

    def event(name):
        subprocess.run([str(hook)], input=json.dumps(dict(hook_event_name=name, session_id='manual-test', cwd=temp)),
                       text=True, env=env, capture_output=True, check=True)

    def launch(*flags):
        if log_path.exists():
            log_path.unlink()
        return subprocess.Popen([str(app / 'Contents/MacOS/AgentLidClosed'), '-notifyTimeoutSeconds', '0',
                                 '-sleepGraceSeconds', '0', '-wakeForQuotaReset', 'NO', *flags],
                                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def wait_for(process, message, after=0, timeout=15):
        deadline = time.time() + timeout
        while time.time() < deadline:
            log = log_path.read_text() if log_path.exists() else ''
            if message in log[after:]:
                return log
            if process.poll() is not None:
                raise RuntimeError('App exited: ' + process.stderr.read().decode() + '\n' + log)
            time.sleep(.1)
        raise RuntimeError('Missing ' + message + '\n' + (log_path.read_text() if log_path.exists() else ''))

    def stop(process):
        process.terminate()
        process.wait(timeout=10)

    # 1. A timed hold keeps the Mac awake with no agents, then ends and the closed Mac sleeps.
    process = launch('-autoEnabled', 'YES', '-manualAwakeUntil', str(time.time() + 3))
    try:
        log = wait_for(process, 'Keeping Mac awake: sleep disabled by hand')
        assert (state / 'holding').exists()
        ended = len(log)
        wait_for(process, 'Manual sleep disable timer ended', ended)
        wait_for(process, 'Sleep allowed: no agent sessions', ended)
        wait_for(process, '[dry run] sleep now', ended)
    finally:
        stop(process)
    print('PASS manual: timed hold → ends on time → closed Mac sleeps')

    # 2. A timed hold that ends while an agent works hands over to that agent without releasing.
    event('UserPromptSubmit')
    process = launch('-autoEnabled', 'YES', '-manualAwakeUntil', str(time.time() + 3))
    try:
        log = wait_for(process, 'Keeping Mac awake: sleep disabled by hand')
        log = wait_for(process, 'Manual sleep disable timer ended', len(log))
        log = log[:log.index('Manual sleep disable timer ended')]
        time.sleep(1.5)
        after = log_path.read_text()[len(log):]
        assert 'Sleep allowed' not in after and (state / 'holding').exists(), after
        event('Stop')
        wait_for(process, 'Sleep allowed: all agents are waiting for you', len(log))
    finally:
        stop(process)
    print('PASS manual: timer ends while an agent works → stays awake → sleeps when it waits')

    # 3. Open-ended hold works with Automatic Mode off; quitting releases it.
    process = launch('-autoEnabled', 'NO', '-manualAwakeUntil', ' -1')  # leading space: '-1' alone reads as a flag
    try:
        log = wait_for(process, 'Sleep still disabled by hand until turned off')
        log = wait_for(process, 'Keeping Mac awake: sleep disabled by hand', 0)
        time.sleep(1)
        assert 'Sleep allowed' not in log_path.read_text()
    finally:
        stop(process)
    assert 'Quit: sleep allowed again' in log_path.read_text()
    print('PASS manual: open-ended hold with Automatic Mode off → quit restores sleep')

    # 4. An expired timer from an earlier run is dropped at launch.
    process = launch('-autoEnabled', 'YES', '-manualAwakeUntil', str(time.time() - 60))
    try:
        time.sleep(2)
        log = log_path.read_text()
        assert 'by hand' not in log and not (state / 'holding').exists(), log
    finally:
        stop(process)
    print('PASS manual: an expired timer is ignored at launch')
