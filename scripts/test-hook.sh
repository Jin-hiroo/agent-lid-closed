#!/bin/bash
# Feeds synthetic Claude and Codex events to agent-lid-hook and checks the sleep decision.
# Uses a temporary state directory; doesn't touch the installed app or your settings.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${AGENT_LID_TEST_BIN:-$(./scripts/build-binaries.sh debug)}"
HOOK="$BIN/agent-lid-hook"
export AGENT_LID_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$AGENT_LID_STATE_DIR"' EXIT

failures=0
send() { # event-json
    echo "$1" | "$HOOK"
}
expect() { # description, regex the status output must match
    local out
    out="$("$HOOK" status)"
    if grep -Eq "$2" <<<"$out"; then
        echo "ok    $1"
    else
        echo "FAIL  $1"
        sed 's/^/        /' <<<"$out"
        failures=$((failures + 1))
    fi
}
event() { # name, extra json fields
    send "{\"hook_event_name\":\"$1\",\"session_id\":\"s1\",\"cwd\":\"/tmp/demo\"${2:+,$2}}"
}

expect "no sessions"                 "sleep allowed$"
event SessionStart '"source":"startup"'
expect "new session is idle"         "waiting for you \(new session\)"
event UserPromptSubmit
expect "prompt keeps Mac awake"      "keep the Mac awake"
event PreToolUse '"tool_name":"Bash"'
event PostToolUse '"tool_name":"Bash"'
expect "tool use keeps Mac awake"    "demo  working"
event PreToolUse '"tool_name":"AskUserQuestion"'
expect "question waits for you"      "waiting for you \(question\)"
expect "question: wait for notify"   "sleep allowed in (8[0-9]|90) s"
event PostToolUse '"tool_name":"AskUserQuestion"'
expect "answer resumes work"         "keep the Mac awake"
event SubagentStart '"agent_id":"a1","agent_type":"general-purpose"'
event Stop '"background_tasks":[]'
expect "running subagent keeps awake" "1 subagent running"
event SubagentStop '"agent_id":"a1","agent_type":"general-purpose"'
expect "turn finished"               "waiting for you \(finished\)"
expect "finished: wait for notify"   "sleep allowed in (8[0-9]|90) s"
event Notification '"notification_type":"idle_prompt","message":"Claude is waiting for your input"'
expect "after notify: short grace"   "sleep allowed in ([0-9]|10) s"
event UserPromptSubmit
event Stop '"background_tasks":[{"id":"b1","type":"shell","status":"running"}]'
expect "background task keeps awake" "background tasks running"
event UserPromptSubmit
event Stop '"background_tasks":[{"id":"b1","type":"shell","status":"completed"}]'
expect "finished task allows sleep"  "waiting for you \(finished\)"
event UserPromptSubmit
event Notification '"notification_type":"permission_prompt"'
expect "permission prompt waits"     "waiting for you \(permission\)"
event Notification '"notification_type":"auth_success"'
expect "other notification ignored"  "waiting for you \(permission\)"
event SessionStart '"source":"compact"'
expect "compaction keeps state"      "waiting for you \(permission\)"
event SessionEnd
expect "session end"                 "No agent sessions"

# A session whose Claude Code process has exited is dropped.
send '{"hook_event_name":"UserPromptSubmit","session_id":"s2"}'
f="$AGENT_LID_STATE_DIR/sessions/s2.json"
/usr/bin/sed -i '' -E 's/"pid":[0-9]+/"pid":99999/' "$f"
expect "dead process ignored"        "process gone"

# Esc doesn't fire a hook; the transcript shows the interrupt.
t="$AGENT_LID_STATE_DIR/t.jsonl"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' >"$t"
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}' >>"$t"
send "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s3\",\"transcript_path\":\"$t\"}"
f="$AGENT_LID_STATE_DIR/sessions/s3.json"
/usr/bin/sed -i '' -E 's/"updatedAt":[0-9.e+]+/"updatedAt":1/' "$f"
expect "Esc interrupt detected"      "interrupted"

# The hook must never write to stdout (it would be added to Claude's context).
out="$(send '{"hook_event_name":"UserPromptSubmit","session_id":"s4"}')"
[ -z "$out" ] && echo "ok    hook prints nothing" || { echo "FAIL  hook printed: $out"; failures=$((failures + 1)); }
out="$(echo 'not json' | "$HOOK"; echo "exit=$?")"
[ "$out" = "exit=0" ] && echo "ok    bad input exits 0" || { echo "FAIL  bad input: $out"; failures=$((failures + 1)); }

# Codex shares the event format, with separate IDs and immediate wait notifications.
for id in s2 s3 s4; do send "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"$id\"}"; done
codex_event() {
    echo "{\"hook_event_name\":\"$1\",\"session_id\":\"s1\",\"cwd\":\"/tmp/codex-project\"${2:+,$2}}" | "$HOOK" --provider codex
}
event UserPromptSubmit
codex_event UserPromptSubmit
expect "Claude session labeled" "Claude · demo  working"
expect "Codex session labeled" "Codex · codex-project  working"
codex_event Stop
expect "Claude still keeps awake after Codex stops" "keep the Mac awake"
event SessionEnd
expect "Codex stop uses short grace" "sleep allowed in ([0-9]|10) s"
codex_event UserPromptSubmit
codex_event PermissionRequest
expect "Codex permission retains hold through auto-approval" "keep the Mac awake"
codex_event PostToolUse
expect "Codex resumes after tool" "keep the Mac awake"
codex_event PreToolUse '"tool_name":"functions.request_user_input"'
expect "Codex question waits" "waiting for you \(question\)"
codex_event PostToolUse
codex_event Interrupt
expect "Codex interrupt waits" "waiting for you \(interrupted\)"
codex_event UserPromptSubmit
codex_event PreCompact
codex_event SessionStart '"source":"compact"'
codex_event PostCompact
expect "Codex compaction stays working" "keep the Mac awake"
codex_event SubagentStart '"agent_id":"child"'
codex_event Stop
expect "Codex subagent keeps awake" "1 subagent running"
codex_event PreToolUse '"agent_id":"child","tool_name":"Bash"'
codex_event PostToolUse '"agent_id":"child","tool_name":"Bash"'
expect "Codex child tools preserve parent waiting state" "1 subagent running"
codex_event SubagentStop '"agent_id":"child"'
expect "Codex subagent done allows sleep" "sleep allowed in ([0-9]|10) s"
codex_event SessionEnd
expect "Codex end cleans namespaced session" "No agent sessions"

# Old JSON records have no provider field; they must still decode as Claude.
event UserPromptSubmit
/usr/bin/python3 - "$AGENT_LID_STATE_DIR/sessions/s1.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f: record = json.load(f)
record.pop('provider', None)
with open(p, 'w') as f: json.dump(record, f)
PY
expect "legacy record stays Claude" "Claude · demo  working"

echo
[ "$failures" -eq 0 ] && echo "All checks passed" || { echo "$failures check(s) failed"; exit 1; }
