#!/usr/bin/env python3
"""Adds or removes the claude-lid-hook entries in a Claude Code settings.json.

    hooks.py install <settings.json> <hook command>
    hooks.py uninstall <settings.json>

Other settings and hooks are left as they are. The file is backed up to settings.json.bak first.
"""
import json
import os
import shutil
import sys

MARK = "claude-lid-hook"
# Event -> matcher. Tool events match every tool; the others take no matcher.
EVENTS = {
    "SessionStart": None,
    "UserPromptSubmit": None,
    "PreToolUse": "*",
    "PostToolUse": "*",
    "PostToolUseFailure": "*",
    "Notification": None,
    "Elicitation": None,
    "ElicitationResult": None,
    "SubagentStart": None,
    "SubagentStop": None,
    "Stop": None,
    "StopFailure": None,
    "SessionEnd": None,
}


def strip(settings):
    hooks = settings.get("hooks") or {}
    for event in list(hooks):
        kept = []
        for group in hooks[event]:
            entries = [h for h in group.get("hooks", []) if MARK not in h.get("command", "")]
            if entries:
                kept.append({**group, "hooks": entries})
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if "hooks" in settings and not hooks:
        del settings["hooks"]


def install(settings, command):
    strip(settings)
    hooks = settings.setdefault("hooks", {})
    for event, matcher in EVENTS.items():
        group = {"matcher": matcher} if matcher else {}
        group["hooks"] = [{"type": "command", "command": command, "timeout": 5}]
        hooks.setdefault(event, []).append(group)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("install", "uninstall"):
        sys.exit(__doc__)
    path = os.path.realpath(sys.argv[2])  # write through a symlinked settings.json
    settings = {}
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)
        shutil.copy2(path, path + ".bak")
    if sys.argv[1] == "install":
        install(settings, json.dumps(sys.argv[3]))  # quoted, in case the path has spaces
    else:
        strip(settings)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    temp = path + ".tmp"
    with open(temp, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(temp, path)


if __name__ == "__main__":
    main()
