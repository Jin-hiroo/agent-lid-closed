import Foundation

/// Sends commands through T3's own WebSocket API, the way its app does. Each delivery
/// gets a five-minute credential scoped to orchestration from T3's CLI and revokes it
/// afterwards; nothing is stored. T3 deduplicates command IDs, so redelivery is safe.
enum T3Commands {
    enum Outcome: Sendable, Equatable {
        case accepted
        /// T3 refused the command. The same command ID will be refused again.
        case rejected(String)
        /// Not delivered. Retrying with the same command ID is safe.
        case failed(String)
        /// Not sent: no longer wanted when the credential was ready.
        case withdrawn
    }

    private struct Runtime: Decodable { var port: Int }
    private struct Issued: Decodable { var sessionId: String; var token: String }

    /// Returns an outcome for every command ID. `confirm` runs once the connection is
    /// ready, just before sending, and returns the IDs still wanted unchanged, so a
    /// change made meanwhile withdraws a command.
    static func dispatch(_ commands: [(id: String, json: Data)], directory: URL,
                         confirm: @Sendable () async -> Set<String>) async -> [String: Outcome] {
        func all(_ outcome: Outcome) -> [String: Outcome] {
            Dictionary(commands.map { ($0.id, outcome) }, uniquingKeysWith: { first, _ in first })
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("server-runtime.json")),
              let runtime = try? JSONDecoder().decode(Runtime.self, from: data),
              (1...65535).contains(runtime.port),
              let url = URL(string: "ws://127.0.0.1:\(runtime.port)/ws?orchestrationProtocol=2") else {
            return all(.failed("T3 Code isn't running"))
        }
        let base = directory.deletingLastPathComponent()
        let cli = base.appendingPathComponent("bin/t3")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            return all(.failed("T3's t3 command is missing; open T3 Code once to reinstall it"))
        }
        guard let output = await run(cli, ["auth", "session", "issue", "--base-dir", base.path,
                                           "--scope", "orchestration:read", "--scope", "orchestration:operate",
                                           "--ttl", "5m", "--label", "Agent Lid Closed", "--json"]),
              let issued = try? JSONDecoder().decode(Issued.self, from: output) else {
            // The output contains the credential: never log it.
            return all(.failed("T3 didn't issue a command credential"))
        }
        let outcomes = await send(commands, to: url, token: issued.token, confirm: confirm)
        _ = await run(cli, ["auth", "session", "revoke", "--base-dir", base.path, issued.sessionId])
        return outcomes
    }

    private static func send(_ commands: [(id: String, json: Data)], to url: URL, token: String,
                             confirm: @Sendable () async -> Set<String>) async -> [String: Outcome] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: request)
        socket.resume()
        // A stalled server ends the receive loop below.
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }

        func message(_ received: URLSessionWebSocketTask.Message) -> [[String: Any]] {
            let data: Data
            switch received {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: return []
            }
            let decoded = try? JSONSerialization.jsonObject(with: data)
            return (decoded as? [[String: Any]]) ?? [(decoded as? [String: Any])].compactMap { $0 }
        }

        var pending: [String: String] = [:]  // RPC request ID: command ID
        var outcomes: [String: Outcome] = [:]
        do {
            // A Pong proves the handshake finished, so the confirmation covers
            // everything but the send itself.
            try await socket.send(.string(#"{"_tag":"Ping"}"#))
            waiting: while true {
                for reply in message(try await socket.receive()) {
                    if reply["_tag"] as? String == "Pong" { break waiting }
                }
            }
            let wanted = await confirm()
            for command in commands where !wanted.contains(command.id) { outcomes[command.id] = .withdrawn }
            for (index, command) in commands.enumerated() where wanted.contains(command.id) {
                let requestID = String(index + 1)
                let payload = try JSONSerialization.jsonObject(with: command.json)
                let message: [String: Any] = ["_tag": "Request", "id": requestID,
                                              "tag": "orchestration.dispatchCommand",
                                              "payload": payload, "headers": [Any]()]
                try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)))
                pending[requestID] = command.id
            }
            while !pending.isEmpty {
                for message in message(try await socket.receive()) {
                    switch message["_tag"] as? String {
                    case "Exit":
                        guard let requestID = message["requestId"] as? String,
                              let commandID = pending.removeValue(forKey: requestID) else { continue }
                        outcomes[commandID] = outcome(of: message["exit"] as? [String: Any])
                    case "Ping":
                        try await socket.send(.string(#"{"_tag":"Pong"}"#))
                    case "Defect", "ClientProtocolError":
                        for commandID in pending.values { outcomes[commandID] = .failed("T3 closed the connection") }
                        pending.removeAll()
                    default:
                        continue
                    }
                }
            }
        } catch {
            for commandID in pending.values { outcomes[commandID] = .failed("Couldn't reach T3 Code") }
        }
        socket.cancel(with: .normalClosure, reason: nil)
        for command in commands where outcomes[command.id] == nil {
            outcomes[command.id] = .failed("Couldn't reach T3 Code")
        }
        return outcomes
    }

    private static func outcome(of exit: [String: Any]?) -> Outcome {
        switch exit?["_tag"] as? String {
        case "Success":
            return .accepted
        case "Failure":
            let causes = exit?["cause"] as? [[String: Any]] ?? []
            if let failure = causes.first(where: { $0["_tag"] as? String == "Fail" })?["error"] as? [String: Any] {
                return .rejected(failure["message"] as? String ?? failure["_tag"] as? String ?? "refused")
            }
            // An interrupted request was not processed.
            if causes.contains(where: { $0["_tag"] as? String == "Interrupt" }) { return .failed("T3 interrupted the request") }
            return .rejected("T3 couldn't process the command")
        default:
            return .failed("T3 sent an unexpected reply")
        }
    }

    /// Runs a command and returns its standard output, or nil on failure or after 20 s.
    private static func run(_ executable: URL, _ arguments: [String]) async -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let reader = output.fileHandleForReading
        return await withCheckedContinuation { continuation in
            let completion = Completion(continuation, reader: reader)
            process.terminationHandler = { completion.exited($0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                completion.fail()
                return
            }
            // Drain while it runs so a full pipe can't block it. Nothing blocks on the
            // pipe, so a process that ignores SIGTERM, or a child holding it, ends at the deadline.
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { completion.endOfOutput() } else { completion.append(chunk) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                completion.fail()
            }
        }
    }

    /// Resumes once: with the output after a clean exit, or with nil. Then stops reading.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private let reader: FileHandle
        private var continuation: CheckedContinuation<Data?, Never>?
        private var status: Int32?
        private var output = Data()
        private var ended = false

        init(_ continuation: CheckedContinuation<Data?, Never>, reader: FileHandle) {
            self.continuation = continuation
            self.reader = reader
        }

        func exited(_ status: Int32) {
            lock.withLock {
                self.status = status
                if status != 0 { finish(nil) } else { finishIfComplete() }
            }
        }

        func append(_ chunk: Data) {
            lock.withLock { output.append(chunk) }
        }

        func endOfOutput() {
            lock.withLock {
                ended = true
                finishIfComplete()
            }
        }

        func fail() {
            lock.withLock { finish(nil) }
        }

        private func finishIfComplete() {
            guard ended, status == 0 else { return }
            finish(output)
        }

        private func finish(_ value: Data?) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
            reader.readabilityHandler = nil
            try? reader.close()
        }
    }
}
