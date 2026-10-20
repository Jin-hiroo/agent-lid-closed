#!/usr/bin/env python3
"""Move legacy state and leave an alias for hooks cached by existing Claude sessions."""
import pathlib
import sys


def migrate(legacy, current):
    legacy, current = pathlib.Path(legacy), pathlib.Path(current)
    current.parent.mkdir(parents=True, exist_ok=True)
    if legacy.exists() and current.exists():
        if legacy.resolve() != current.resolve():
            raise RuntimeError(f"Both {legacy} and {current} exist with separate state; merge them before upgrading")
        return
    if legacy.is_symlink() or current.is_symlink():
        raise RuntimeError("Unexpected dangling state symlink")
    # Never move a live directory: cached hooks can keep writing under the old
    # path, using the same files and lock inode as the renamed app.
    if legacy.exists():
        current.symlink_to(legacy, target_is_directory=True)
    else:
        current.mkdir(parents=True, exist_ok=True)
        legacy.symlink_to(current, target_is_directory=True)


if __name__ == "__main__":
    migrate(*sys.argv[1:])
