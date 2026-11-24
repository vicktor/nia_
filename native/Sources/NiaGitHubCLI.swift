// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

// Delegate private-repository authentication to gh itself. Never ask gh for
// its token or copy credentials into nia_. A job can be cancelled during I/O.
final class NiaGitHubCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    private func run(arguments: [String], output: URL, timeout: TimeInterval, limit: Int64) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", home.appendingPathComponent(".local/bin/gh").path]
        guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw NiaUpdateError.repositoryAccess }
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw NiaUpdateError.response }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_HOST"] = "github.com"
        process.environment = environment
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        self.process = process
        do { try process.run(); lock.unlock() }
        catch { lock.unlock(); throw error }
        let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let killJob = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminate)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2, execute: killJob)
        defer { terminate.cancel(); killJob.cancel() }
        process.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; self.process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw NiaUpdateError.repositoryAccess }
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        guard let size, size.int64Value > 0, size.int64Value <= limit else { throw NiaUpdateError.invalidDownload }
    }

    func execute(arguments: [String], output: URL, timeout: TimeInterval = 30, limit: Int64 = 4 * 1024 * 1024) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached { try self.run(arguments: arguments, output: output, timeout: timeout, limit: limit) }.value
        } onCancel: { self.cancel() }
    }
}

enum NiaGitHubCLI {
    static func releases() async throws -> [NiaRelease] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("nia-github-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        var releases: [NiaRelease] = []
        for page in 1...20 {
            try await NiaGitHubCommand().execute(arguments: ["api", "--hostname", "github.com",
                "repos/vicktor/nia_/releases?per_page=100&page=\(page)"], output: output)
            let batch = try JSONDecoder().decode([NiaRelease].self, from: Data(contentsOf: output))
            releases += batch
            if batch.count < 100 { return releases }
        }
        throw NiaUpdateError.response
    }
    static func download(_ asset: NiaRelease.Asset, to output: URL) async throws {
        guard let id = asset.id, id > 0 else { throw NiaUpdateError.incompatible }
        try await NiaGitHubCommand().execute(arguments: ["api", "--hostname", "github.com",
            "-H", "Accept: application/octet-stream", "repos/vicktor/nia_/releases/assets/\(id)"],
            output: output, timeout: 600, limit: asset.size)
    }
}
