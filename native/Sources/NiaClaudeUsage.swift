// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

enum NiaClaudeUsage {
    static func executable(custom: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = custom.isEmpty ? [home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] : [custom]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    // One read-only SDK control request, without initialize, a user message or
    // a model turn. Claude owns authentication; nia_ never reads its credentials.
    // skip_behaviors prevents local transcript analysis. Customizations and tools
    // are disabled, and no conversation is persisted in the temporary directory.
    static func read(customPath: String, timeout seconds: TimeInterval = 15) throws -> NiaUsageSnapshot {
        guard let executable = executable(custom: customPath) else { throw NiaUsageError.claudeMissing }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nia-usage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = ["--print", "--safe-mode", "--no-session-persistence", "--strict-mcp-config",
            "--tools", "", "--no-chrome", "--settings", "{\"disableAllHooks\":true}",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let killTimeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 2, execute: killTimeout)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            timeout.cancel()
            killTimeout.cancel()
            try? output.fileHandleForReading.close()
        }
        let requestID = UUID().uuidString
        var request = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": requestID,
            "request": ["subtype": "get_usage", "skip_behaviors": true]])
        request.append(10)
        try input.fileHandleForWriting.write(contentsOf: request)
        var buffer = Data(), total = 0
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["type"] as? String == "control_response",
                      let response = object["response"] as? [String: Any],
                      response["request_id"] as? String == requestID else { continue }
                guard response["subtype"] as? String == "success",
                      let usage = response["response"] as? [String: Any] else { throw NiaUsageError.claudeFailed }
                return try NiaUsageSnapshot.claudeAccount(usage)
            }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw NiaUsageError.claudeFailed }
            total += data.count
            guard total < 4 * 1024 * 1024 else { throw NiaUsageError.claudeFailed }
            buffer.append(data)
        }
    }
}
