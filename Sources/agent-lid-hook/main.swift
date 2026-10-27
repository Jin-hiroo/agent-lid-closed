// Claude Code and Codex run this on hook events (payload JSON on stdin) to record what each
// session is doing. Event mode must stay fast and print nothing to stdout (stdout of some events is
// added to Claude's context) and always exit 0 so it can never block Claude.
//
//   agent-lid-hook [--provider claude|codex]   handle one event from stdin (default: Claude)
//   agent-lid-hook status                     show all sessions and the sleep decision
//   agent-lid-hook statusline                 capture quota data and delegate status display

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
    CodexQuotaMonitor().refresh(store: SessionStore(), now: now, isAlive: ProcessLookup.isAlive)
    let t3 = T3Monitor.read(now: now)
    if let error = t3.error { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
    let evaluation = Evaluator.evaluate(t3.merging(SessionStore().loadAll()), now: now, settings: .load(from: defaults),
                                        isAlive: ProcessLookup.isAlive, isInterrupted: Transcript.endsWithInterrupt)
    if evaluation.sessions.isEmpty { print("No agent sessions") }
    for session in evaluation.sessions {
        let minutes = Int(now - session.since.timeIntervalSince1970) / 60
        print("\(session.accountName) · \(session.project)  \(session.label)  (\(minutes) min)  \(session.id)")
    }
    for id in evaluation.deadSessionIDs { print("\(id)  process gone") }
    if evaluation.keepAwake {
        print("=> keep the Mac awake")
    } else {
        let wait = Int(max(0, evaluation.sleepAllowedAt - now).rounded(.up))
        print(wait == 0 ? "=> sleep allowed" : "=> sleep allowed in \(wait) s")
    }
}

/// Capture only quota fields, then replay the unchanged payload to the user's status line.
func handleStatusLine(original: String?) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if let input = try? JSONDecoder().decode(QuotaStatusInput.self, from: data) {
        try? input.save(to: SessionStore(), now: Date().timeIntervalSince1970)
    }
    if let original {
        guard let object = original.data(using: .utf8),
              let config = (try? JSONSerialization.jsonObject(with: object)) as? [String: Any],
              let command = config["command"] as? String, !command.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            // A status-line command is allowed not to read stdin.
            signal(SIGPIPE, SIG_IGN)
            try? pipe.fileHandleForWriting.write(contentsOf: data)
            try? pipe.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            FileHandle.standardError.write(Data("agent-lid-hook statusline: \(error)\n".utf8))
        }
    } else if let input = try? JSONDecoder().decode(QuotaStatusInput.self, from: data),
              let reset = input.usage?.blockingReset(after: Date().timeIntervalSince1970) {
        let time = Date(timeIntervalSince1970: reset).formatted(date: .omitted, time: .shortened)
        print("Claude usage limit · resets \(time)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args {
case []:
    handleHook(provider: .claude)
case ["status"]:
    printStatus()
case ["statusline"]:
    handleStatusLine(original: nil)
default:
    if args.count == 3, args[0] == "statusline", args[1] == "--original-statusline" {
        handleStatusLine(original: args[2])
    } else if args.count == 2, args[0] == "--provider", let provider = AgentProvider(rawValue: args[1]) {
        handleHook(provider: provider)
    } else {
        FileHandle.standardError.write(Data("usage: agent-lid-hook [status | statusline | --provider claude|codex]\n".utf8))
        exit(64)
    }
}
