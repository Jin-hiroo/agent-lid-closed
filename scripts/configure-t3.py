#!/usr/bin/env python3
"""Enable T3's native usage-limit recovery; its running server watches this file."""
import json
import os
import pathlib
import stat
import sys
import tempfile


def enable_recovery(path):
    # Resolve a supported settings symlink rather than replacing the link.
    path = pathlib.Path(path).resolve()
    if not path.exists():
        return False
    for _ in range(5):
        original = path.read_bytes()
        settings = json.loads(original)
        if not isinstance(settings, dict):
            raise ValueError('T3 settings must be a JSON object')
        if settings.get('autoResumeLimitedThreads') is True:
            return True
        settings['autoResumeLimitedThreads'] = True
        mode = stat.S_IMODE(path.stat().st_mode)
        fd, temporary = tempfile.mkstemp(prefix='.agent-lid-recovery-', dir=path.parent)
        try:
            os.fchmod(fd, mode)
            with os.fdopen(fd, 'w') as output:
                json.dump(settings, output, indent=2, ensure_ascii=False)
                output.write('\n')
            # T3's own CLI uses this same reread-before-rename protocol to merge
            # with the live server. Retry instead of overwriting concurrent edits.
            if path.read_bytes() != original:
                continue
            os.replace(temporary, path)
            return True
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    raise RuntimeError('T3 settings changed repeatedly; retry setup')


if __name__ == '__main__':
    try:
        configured = enable_recovery(sys.argv[1] if len(sys.argv) > 1 else
                                     pathlib.Path.home() / '.t3/userdata/settings.json')
        print('T3 Code: native auto-resume after usage resets enabled.' if configured else
              'T3 Code settings not found; no T3 configuration changed.')
    except (OSError, ValueError, RuntimeError) as error:
        # JSON errors can include fragments of settings; never print their text.
        print(f'Could not configure T3 recovery ({type(error).__name__}).', file=sys.stderr)
        sys.exit(1)
