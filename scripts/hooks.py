#!/usr/bin/env python3
"""Adds or removes Agent Lid Closed hooks, preserving other settings.

    hooks.py install <settings.json|hooks.json> <hook path> [claude|codex] [--manifest FILE]
    hooks.py uninstall <settings.json|hooks.json> [--manifest FILE]
    hooks.py plan --manifest FILE [--claude-config-dir DIR]... [--no-claude] [--no-codex] [--codex]
    hooks.py targets --manifest FILE

Other settings and hooks are left as they are. The file is backed up to settings.json.bak first.
The manifest lists every file that has the hooks, so the app and the uninstaller can find them.
`plan` prints those files as JSON: tools that are installed, files that already have the hooks,
and folders named on the command line. `targets` prints, one per line, the files the uninstaller
removes hooks from. Paths must be absolute and fit on one line; others are skipped with a warning.
"""
import argparse
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


def write_json(path, value, mode=None):
    """Replace a file atomically, keeping its permissions."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".agent-lid-", dir=os.path.dirname(path) or ".")
    try:
        if os.path.exists(path):
            os.fchmod(fd, os.stat(path).st_mode & 0o777)
        elif mode is not None:
            os.fchmod(fd, mode)
        with os.fdopen(fd, "w") as f:
            json.dump(value, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def read_manifest(path):
    try:
        with open(path) as f:
            value = json.load(f)
    except (OSError, ValueError):
        return {"claude": [], "codex": []}
    targets = {"claude": [], "codex": []}
    for provider in targets:
        paths = value.get(provider) if isinstance(value, dict) else None
        if isinstance(paths, list):
            targets[provider] = [p for p in paths if isinstance(p, str)]
    return targets


def record(manifest, provider, path, installed):
    """Add or remove one file in the manifest."""
    if manifest is None:
        return
    targets = read_manifest(manifest)
    for name in targets:
        targets[name] = [p for p in targets[name] if p != path]
    if installed:
        targets[provider].append(path)
    write_json(manifest, targets, 0o644)


def has_hooks(path):
    try:
        with open(path) as f:
            settings = json.load(f)
    except (OSError, ValueError):
        return False
    groups = settings.get("hooks") if isinstance(settings, dict) else None
    if not isinstance(groups, dict):
        return False
    return any(isinstance(handler, dict) and any(mark in str(handler.get("command", "")) for mark in MARKS)
               for event in groups.values() if isinstance(event, list)
               for group in event if isinstance(group, dict)
               for handler in group.get("hooks", []) if isinstance(group.get("hooks"), list))


def usable(path):
    """The path, normalized, if it is absolute and on one line; otherwise None.

    A relative path would resolve against the source folder, and a newline would split it in two
    where the shell scripts read one path per line."""
    path = os.path.expanduser(path or "")
    if not os.path.isabs(path) or "\n" in path:
        if path:
            print(f"warning: skipping {path!r}; use an absolute path", file=sys.stderr)
        return None
    return os.path.normpath(path)


def unique(paths):
    result = []
    for path in filter(None, map(usable, paths)):
        if path not in result:
            result.append(path)
    return result


def plan(manifest, claude_dirs=(), no_claude=False, no_codex=False, force_codex=False, environ=None, which=None):
    """Files to install hooks into: present tools, files that already have them, and named folders."""
    environ = os.environ if environ is None else environ
    which = shutil.which if which is None else which
    home = environ.get("HOME", os.path.expanduser("~"))
    recorded = read_manifest(manifest)

    claude_dir = os.path.join(home, ".claude")
    claude_default = os.path.join(claude_dir, "settings.json")
    claude = []
    if not no_claude:
        if which("claude") or os.path.isdir(claude_dir) or has_hooks(claude_default):
            claude.append(claude_default)
        # The account this shell uses, as earlier versions did.
        shell_dir = usable(environ.get("CLAUDE_CONFIG_DIR"))
        if shell_dir:
            claude.append(os.path.join(shell_dir, "settings.json"))
        claude += [p for p in recorded["claude"] if os.path.exists(p)]
        claude += [os.path.join(d, "settings.json") for d in filter(None, map(usable, claude_dirs))]
    old_codex_default = os.path.join(home, ".codex", "hooks.json")
    codex_default = os.path.join(usable(environ.get("CODEX_HOME")) or os.path.join(home, ".codex"), "hooks.json")
    codex = []
    if not no_codex:
        if (force_codex or which("codex") or os.path.isdir(os.path.dirname(codex_default)) or
                has_hooks(codex_default)):
            codex.append(codex_default)
        # Earlier versions used ~/.codex when CODEX_HOME wasn't set; keep those hooks current.
        if has_hooks(old_codex_default):
            codex.append(old_codex_default)
        codex += [p for p in recorded["codex"] if os.path.exists(p)]
    return {"claude": unique(claude), "codex": unique(codex)}


def mentions_hook(path):
    """Hooks or the status-line wrapper, even in a file that no longer parses."""
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except OSError:
        return False
    return any(mark in text for mark in MARKS)


def targets(manifest, environ=None):
    """Files to remove hooks from: recorded ones, the defaults, and this shell's config folders."""
    environ = os.environ if environ is None else environ
    home = environ.get("HOME", os.path.expanduser("~"))
    recorded = read_manifest(manifest)
    paths = recorded["claude"] + recorded["codex"] + [
        os.path.join(home, ".claude", "settings.json"), os.path.join(home, ".codex", "hooks.json")]
    for name, filename in (("CLAUDE_CONFIG_DIR", "settings.json"), ("CODEX_HOME", "hooks.json")):
        folder = usable(environ.get(name))
        if folder:
            paths.append(os.path.join(folder, filename))
    return [path for path in unique(paths) if mentions_hook(path)]


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "targets":
        parser = argparse.ArgumentParser(prog="hooks.py targets")
        parser.add_argument("--manifest", required=True)
        args = parser.parse_args(sys.argv[2:])
        for path in targets(args.manifest):
            print(path)
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "plan":
        parser = argparse.ArgumentParser(prog="hooks.py plan")
        parser.add_argument("--manifest", required=True)
        parser.add_argument("--claude-config-dir", action="append", default=[])
        parser.add_argument("--no-claude", action="store_true")
        parser.add_argument("--no-codex", action="store_true")
        parser.add_argument("--codex", action="store_true")
        args = parser.parse_args(sys.argv[2:])
        print(json.dumps(plan(args.manifest, args.claude_config_dir, args.no_claude, args.no_codex, args.codex)))
        return
    manifest = None
    arguments = sys.argv[1:]
    if "--manifest" in arguments:
        index = arguments.index("--manifest")
        if index + 1 >= len(arguments):
            sys.exit(__doc__)
        manifest = arguments[index + 1]
        del arguments[index:index + 2]
    if len(arguments) < 2 or arguments[0] not in ("install", "uninstall"):
        sys.exit(__doc__)
    if arguments[0] == "install" and (len(arguments) not in (3, 4) or
                                      (len(arguments) == 4 and arguments[3] not in ("claude", "codex"))):
        sys.exit(__doc__)
    if arguments[0] == "uninstall" and len(arguments) != 2:
        sys.exit(__doc__)
    path = os.path.realpath(arguments[1])  # write through a symlinked settings.json
    settings = {}
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)
        validate(settings)
        shutil.copy2(path, path + ".bak")
    provider = arguments[3] if len(arguments) == 4 else "claude"
    if arguments[0] == "install":
        command = shlex.quote(arguments[2])
        if provider == "codex":
            command += " --provider codex"
        install(settings, command, provider)
    else:
        strip(settings)
    write_json(path, settings)
    # Record the path as given, so a symlinked settings file is found where it was named.
    record(manifest, provider, os.path.abspath(os.path.expanduser(arguments[1])), arguments[0] == "install")


if __name__ == "__main__":
    main()
