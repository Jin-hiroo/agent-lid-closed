// Claude Code runs this on every hook event (payload JSON on stdin) to record what each
// session is doing. It must stay fast, print nothing to stdout (stdout of some events is
// added to Claude's context) and always exit 0 so it can never block Claude.
//
//   claude-lid-hook          handle one hook event from stdin
//   claude-lid-hook status   show the recorded sessions and the current sleep decision

import Foundation
import LidCore

func handleHook() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = try? JSONDecoder().decode(HookInput.self, from: data), !input.sessionID.isEmpty else { return }
    let action = HookLogic.action(for: input)
    guard action != .ignore else { return }
    let store = SessionStore()
    do {
        try store.withLock {
            try HookLogic.apply(action, input: input, owner: ProcessLookup.hookOwner(), store: store,
                                now: Date().timeIntervalSince1970)
        }
    } catch {
        FileHandle.standardError.write(Data("claude-lid-hook: \(error)\n".utf8))
    }
}

func printStatus() {
    let now = Date().timeIntervalSince1970
    let defaults = UserDefaults(suiteName: Paths.bundleID) ?? .standard
    let evaluation = Evaluator.evaluate(SessionStore().loadAll(), now: now, settings: .load(from: defaults),
                                        isAlive: ProcessLookup.isAlive, isInterrupted: Transcript.endsWithInterrupt)
    if evaluation.sessions.isEmpty { print("No Claude Code sessions") }
    for session in evaluation.sessions {
        let minutes = Int(now - session.since.timeIntervalSince1970) / 60
        print("\(session.project)  \(session.label)  (\(minutes) min)  \(session.id)")
    }
    for id in evaluation.deadSessionIDs { print("\(id)  process gone") }
    if evaluation.keepAwake {
        print("=> keep the Mac awake")
    } else {
        let wait = Int(max(0, evaluation.sleepAllowedAt - now).rounded(.up))
        print(wait == 0 ? "=> sleep allowed" : "=> sleep allowed in \(wait) s")
    }
}

switch CommandLine.arguments.dropFirst().first {
case nil:
    handleHook()
case "status":
    printStatus()
default:
    FileHandle.standardError.write(Data("usage: claude-lid-hook [status]\n".utf8))
    exit(64)
}
