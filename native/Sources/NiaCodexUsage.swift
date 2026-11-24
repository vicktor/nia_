// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

enum NiaCodexUsage {
    static func executable(custom: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = custom.isEmpty ? [home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home.appendingPathComponent(".cargo/bin/codex").path] : [custom]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    // Short-lived, read-only app-server connection. No thread/turn is created,
    // no model is invoked, and nia_ never reads or stores Codex credentials.
    static func read(customPath: String) throws -> NiaUsageSnapshot {
        guard let executable = executable(custom: customPath) else { throw NiaUsageError.codexMissing }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        let killTimeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + 17, execute: killTimeout)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Keep the hard deadline armed until our child is reaped.
            process.waitUntilExit()
            timeout.cancel()
            killTimeout.cancel()
            try? output.fileHandleForReading.close()
        }
        var buffer = Data()
        var total = 0
        func send(_ object: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object)
            bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes)
        }
        func response(_ id: Int) throws -> [String: Any] {
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if object["id"] as? Int == id {
                        guard let result = object["result"] as? [String: Any] else { throw NiaUsageError.codexFailed }
                        return result
                    }
                } else {
                    let data = output.fileHandleForReading.availableData
                    guard !data.isEmpty else { throw NiaUsageError.codexFailed }
                    total += data.count
                    guard total < 4 * 1024 * 1024 else { throw NiaUsageError.codexFailed }
                    buffer.append(data)
                }
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "nia_usage", "version": "1.0"],
                  "capabilities": ["explicitGatewayOauth": true]]])
        _ = try response(1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
        let limits = try response(2)
        try send(["id": 3, "method": "account/usage/read", "params": [:]])
        let usage = try? response(3) // Older Codex versions may not expose tokens.
        return NiaUsageSnapshot.codex(limits: limits, usage: usage)
    }
}
