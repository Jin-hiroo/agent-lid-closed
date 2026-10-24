#!/usr/bin/env python3
"""Dry-run real app transitions for each provider, without touching the installed app."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/AgentLidClosed.app').resolve()
for provider in ('claude', 'codex'):
    with tempfile.TemporaryDirectory(prefix='agent-lid-display-') as temp:
        state = pathlib.Path(temp)
        env = dict(os.environ, AGENT_LID_DRY_RUN='1', AGENT_LID_FAKE_LID='closed', AGENT_LID_STATE_DIR=temp)
        hook = app / 'Contents/Helpers/agent-lid-hook'
        def event(name):
            subprocess.run([str(hook), '--provider', provider],
                           input=json.dumps({'hook_event_name': name, 'session_id': 'display-test', 'cwd': temp}),
                           text=True, env=env, check=True)
        event('UserPromptSubmit')
        process = subprocess.Popen([str(app / 'Contents/MacOS/AgentLidClosed'),
                                    '-autoEnabled', 'YES', '-dimDisplay', 'YES',
                                    '-notifyTimeoutSeconds', '0', '-sleepGraceSeconds', '0'],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        def wait_for(message):
            for _ in range(100):
                log = (state / 'AgentLidClosed.log').read_text() if (state / 'AgentLidClosed.log').exists() else ''
                if message in log:
                    return
                if process.poll() is not None:
                    raise RuntimeError('App exited; quit other Agent/Claude Lid Closed copies first.\n' + log)
                time.sleep(.1)
            raise RuntimeError('Missing ' + message + '\n' + log)
        try:
            wait_for('[dry run] display brightness 0%')
            event('Stop')
            wait_for('[dry run] sleep now')
            assert (state / 'dimmed-brightness').exists(), 'Keep backlight off during lid-closed sleep'
            (state / 'lid-open').touch()
            wait_for('[dry run] display brightness 50%')
            assert not (state / 'dimmed-brightness').exists()
            print(f'PASS {provider}: working → 0%; waiting → sleep; lid open → restored 50%')
        finally:
            process.terminate()
            process.wait(timeout=10)
