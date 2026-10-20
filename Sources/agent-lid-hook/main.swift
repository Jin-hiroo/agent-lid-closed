// Claude Code and Codex run this on hook events (payload JSON on stdin) to record what each
// session is doing. It must stay fast, print nothing to stdout (stdout of some events is
// added to Claude's context) and always exit 0 so it can never block Claude.
//
//   agent-lid-hook [--provider claude|codex]   handle one event from stdin (default: Claude)
//   agent-lid-hook status                     show all sessions and the sleep decision

import Foundation
import LidCore

func handleHook(provider: AgentProvider) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard var input = try? JSONDecoder().decode(HookInput.self, from: data), !input.sessionID.isEmpty else { return }
    input.sessionID = provider.sessionKey(input.sessionID)
    let action = HookLogic.action(for: input, provider: provider)
    guard action != .ignore else { return }
    let store = SessionStore()
    do {
        try store.withLock {
            try HookLogic.apply(action, input: input, owner: ProcessLookup.hookOwner(), store: store,
                                now: Date().timeIntervalSince1970, provider: provider)
        }
    } catch {
        FileHandle.standardError.write(Data("agent-lid-hook: \(error)\n".utf8))
    }
}

func printStatus() {
    let now = Date().timeIntervalSince1970
    let defaults = UserDefaults(suiteName: Paths.bundleID) ?? .standard
    Paths.migratePreferences(to: defaults)
    let evaluation = Evaluator.evaluate(SessionStore().loadAll(), now: now, settings: .load(from: defaults),
                                        isAlive: ProcessLookup.isAlive, isInterrupted: Transcript.endsWithInterrupt)
    if evaluation.sessions.isEmpty { print("No agent sessions") }
    for session in evaluation.sessions {
        let minutes = Int(now - session.since.timeIntervalSince1970) / 60
        print("\(session.provider.name) · \(session.project)  \(session.label)  (\(minutes) min)  \(session.id)")
    }
    for id in evaluation.deadSessionIDs { print("\(id)  process gone") }
    if evaluation.keepAwake {
        print("=> keep the Mac awake")
    } else {
        let wait = Int(max(0, evaluation.sleepAllowedAt - now).rounded(.up))
        print(wait == 0 ? "=> sleep allowed" : "=> sleep allowed in \(wait) s")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args {
case []:
    handleHook(provider: .claude)
case ["status"]:
    printStatus()
default:
    if args.count == 2, args[0] == "--provider", let provider = AgentProvider(rawValue: args[1]) {
        handleHook(provider: provider)
    } else {
        FileHandle.standardError.write(Data("usage: agent-lid-hook [status | --provider claude|codex]\n".utf8))
        exit(64)
    }
}
