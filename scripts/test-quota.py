#!/usr/bin/env python3
"""Exercise real hook/status-line/app processes without scheduling a real wake or sleep."""
import concurrent.futures
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/AgentLidClosed.app').resolve()
with tempfile.TemporaryDirectory(prefix='agent-lid-quota-') as temp:
    state = pathlib.Path(temp)
    env = dict(os.environ, AGENT_LID_DRY_RUN='1', AGENT_LID_FAKE_LID='closed', AGENT_LID_STATE_DIR=temp)
    hook = app / 'Contents/Helpers/agent-lid-hook'
    record_path = state / 'sessions/quota-test.json'

    def run(args, payload):
        result = subprocess.run([str(hook)] + args, input=json.dumps(payload),
                                text=True, env=env, capture_output=True, check=True)
        return result.stdout

    def event(name, **fields):
        assert not run([], dict(hook_event_name=name, session_id='quota-test', cwd=temp, **fields))

    def statusline(reset, percentage=100, original=None):
        args = ['statusline']
        if original is not None:
            args += ['--original-statusline', json.dumps(original)]
        return run(args, {'session_id': 'quota-test', 'rate_limits': {
            'five_hour': {'used_percentage': percentage, 'resets_at': reset}}})

    def update_record(**fields):
        record = json.loads(record_path.read_text())
        record.update(fields)
        scratch = record_path.with_suffix('.test-temp')
        scratch.write_text(json.dumps(record))
        scratch.replace(record_path)

    event('UserPromptSubmit')
    original = {'type': 'command', 'command': "python3 -c 'import json,sys; print(json.load(sys.stdin)[\"session_id\"])'", 'padding': 2}
    assert statusline(time.time() + 600, original=original) == 'quota-test\n', 'delegate original stdin/stdout'
    assert not statusline(time.time() + 600, original={'type': 'command', 'command': ''}), 'preserve empty display'
    before = json.loads(record_path.read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        work = [pool.submit(statusline, time.time() + 600) for _ in range(12)]
        work += [pool.submit(event, 'PostToolUse', tool_name='Read') for _ in range(12)]
        for task in work:
            task.result()
    record = json.loads(record_path.read_text())
    assert record['pid'] == before['pid'] and record['quotaUsage']['five_hour']['used_percentage'] == 100
    event('StopFailure', error='rate_limit')
    assert json.loads(record_path.read_text())['quotaResetAt'] > time.time()
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
        log = wait_for('[dry run] wake helper set ')
        assert not (state / 'holding').exists(), 'sleep while quota blocked'
        event('Notification', notification_type='quota_auto_resume_disabled')
        log = wait_for('Usage wake cleared', len(log))
        # A reset within two minutes needs a hold, without waiting for the hardware alarm.
        statusline(time.time() + 60)
        event('StopFailure', error='rate_limit')
        log = wait_for('Keeping Mac awake: usage resets shortly', len(log))
        wait_for('[dry run] display brightness 0%')
        # Simulate a wall-clock jump past reset with 1 s of grace remaining.
        update_record(quotaWaitSince=time.time() - 600, quotaResetAt=time.time() - 299)
        log = wait_for('[dry run] sleep now', len(log))
        # A new quota block schedules again; normal continuation clears the alarm.
        statusline(time.time() + 600)
        event('StopFailure', error='rate_limit')
        log = wait_for('[dry run] wake helper set ', len(log))
        continued_after = len(log)
        event('Notification', notification_type='quota_auto_resume_fired')
        log = wait_for('Usage wake cleared', continued_after)
        log = wait_for('Keeping Mac awake: an agent is working', continued_after)
        event('Stop')
        log = wait_for('[dry run] sleep now', len(log))
        # Quit clears an outstanding future wake too.
        statusline(time.time() + 600)
        event('StopFailure', error='rate_limit')
        log = wait_for('[dry run] wake helper set ', len(log))
    finally:
        process.terminate()
        process.wait(timeout=10)
    assert '[dry run] wake helper clear' in (state / 'AgentLidClosed.log').read_text()[len(log):]
    print('PASS quota: capture/delegate → schedule → cancel → warm-up → bounded sleep → native continuation → quit cleanup')

    for flags in [('-autoEnabled', 'NO', '-wakeForQuotaReset', 'YES'),
                  ('-autoEnabled', 'YES', '-wakeForQuotaReset', 'NO')]:
        (state / 'AgentLidClosed.log').unlink()
        process = subprocess.Popen([str(app / 'Contents/MacOS/AgentLidClosed'), *flags],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            log = wait_for('Usage wake cleared')
            assert 'wake helper set' not in log and not (state / 'holding').exists()
        finally:
            process.terminate()
            process.wait(timeout=10)
    print('PASS quota: Automatic Mode off and wake toggle off both suppress alarms and holds')

    helper = app / 'Contents/Helpers/agent-lid-wake'
    for args, code in [(['clear', 'extra'], 64), (['shutdown'], 64), (['clear'], 77),
                       (['set', str(int(time.time()) + 600)], 77)]:
        result = subprocess.run([str(helper), *args], env=env, capture_output=True)
        assert result.returncode == code, 'helper must validate operations and require root even in a dry-run environment'
    print('PASS wake helper: invalid operations rejected; environment cannot bypass root requirement')
