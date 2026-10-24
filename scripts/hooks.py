#!/usr/bin/env python3
"""Adds or removes Agent Lid Closed hooks, preserving other settings.

    hooks.py install <settings.json|hooks.json> <hook path> [claude|codex]
    hooks.py uninstall <settings.json|hooks.json>

Other settings and hooks are left as they are. The file is backed up to settings.json.bak first.
"""
import json
import os
import shutil
import shlex
import sys
import tempfile

MARKS = ("claude-lid-hook", "agent-lid-hook")
# Event -> matcher. Tool events match every tool; the others take no matcher.
CLAUDE_EVENTS = {
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
CODEX_EVENTS = dict.fromkeys([
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PermissionRequest", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact",
    "Stop", "Interrupt",
])


def unwrap_statusline(settings):
    """Recover the exact previous object from our wrapper, including display options."""
    status = settings.get("statusLine")
    if not isinstance(status, dict) or not isinstance(status.get("command"), str):
        return
    try:
        args = shlex.split(status["command"])
        if len(args) < 2 or os.path.basename(args[0]) != "agent-lid-hook" or args[1] != "statusline":
            return
        if len(args) == 2:
            del settings["statusLine"]
        elif len(args) == 4 and args[2] == "--original-statusline":
            settings["statusLine"] = json.loads(args[3])
    except (ValueError, TypeError):
        # A manually edited command is the user's to keep.
        return


def strip(settings):
    unwrap_statusline(settings)
    hooks = settings.get("hooks") or {}
    for event in list(hooks):
        kept = []
        for group in hooks[event]:
            entries = [h for h in group.get("hooks", [])
                       if not any(mark in h.get("command", "") for mark in MARKS)]
            if entries:
                kept.append({**group, "hooks": entries})
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if "hooks" in settings and not hooks:
        del settings["hooks"]


def validate(settings):
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        raise ValueError("Expected a JSON object containing a hooks object")
    for groups in settings.get("hooks", {}).values():
        if not isinstance(groups, list):
            raise ValueError("Hook events must contain arrays of matcher groups")
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("Each matcher group must contain a hooks array")
            for handler in group["hooks"]:
                if not isinstance(handler, dict) or not isinstance(handler.get("command", ""), str):
                    raise ValueError("Expected hook handler objects with string commands")
    status = settings.get("statusLine")
    if status is not None and (not isinstance(status, dict) or status.get("type") != "command" or
                               not isinstance(status.get("command"), str)):
        raise ValueError("Expected a command statusLine; existing settings were preserved")


def install(settings, command, provider="claude"):
    strip(settings)
    if provider == "claude":
        original = settings.get("statusLine")
        if original is not None and (not isinstance(original, dict) or
                                     original.get("type") != "command" or
                                     not isinstance(original.get("command"), str)):
            raise ValueError("Cannot wrap an unsupported Claude statusLine; existing settings were preserved")
        wrapper = command + " statusline"
        if "statusLine" in settings:
            wrapper += " --original-statusline " + shlex.quote(json.dumps(original, ensure_ascii=False))
        settings["statusLine"] = {**(original or {}), "type": "command", "command": wrapper}
    hooks = settings.setdefault("hooks", {})
    events = CODEX_EVENTS if provider == "codex" else CLAUDE_EVENTS
    for event, matcher in events.items():
        group = {"matcher": matcher} if matcher else {}
        timeout = 3 if provider == "codex" and event in ("SessionEnd", "Interrupt") else 5
        group["hooks"] = [{"type": "command", "command": command, "timeout": timeout}]
        hooks.setdefault(event, []).append(group)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("install", "uninstall"):
        sys.exit(__doc__)
    if sys.argv[1] == "install" and (len(sys.argv) not in (4, 5) or
                                     (len(sys.argv) == 5 and sys.argv[4] not in ("claude", "codex"))):
        sys.exit(__doc__)
    path = os.path.realpath(sys.argv[2])  # write through a symlinked settings.json
    settings = {}
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)
        validate(settings)
        shutil.copy2(path, path + ".bak")
    if sys.argv[1] == "install":
        provider = sys.argv[4] if len(sys.argv) == 5 else "claude"
        command = shlex.quote(sys.argv[3])
        if provider == "codex":
            command += " --provider codex"
        install(settings, command, provider)
    else:
        strip(settings)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".agent-lid-", dir=os.path.dirname(path) or ".")
    try:
        if os.path.exists(path):
            os.fchmod(fd, os.stat(path).st_mode & 0o777)
        with os.fdopen(fd, "w") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


if __name__ == "__main__":
    main()
