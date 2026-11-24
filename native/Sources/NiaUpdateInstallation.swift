// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

struct NiaUpdateJob: Codable, Sendable {
    let directory: URL
    let destination: URL
    let fromVersion: String
    let toVersion: String
    let parentPID: Int32
    var source: URL { directory.appendingPathComponent("nia_.app") }
    var resultURL: URL { directory.appendingPathComponent("result.json") }
    var manifestURL: URL { directory.appendingPathComponent("job.json") }

    func validatePaths() throws {
        guard destination.isFileURL, directory.isFileURL,
              destination.pathExtension == "app",
              directory.lastPathComponent.hasPrefix(".nia-update-"),
              directory.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL,
              directory.resolvingSymlinksInPath() == directory.standardizedFileURL,
              destination.resolvingSymlinksInPath() == destination.standardizedFileURL,
              source.resolvingSymlinksInPath() == source.standardizedFileURL,
              let from = NiaVersion(fromVersion), let to = NiaVersion(toVersion), to > from,
              parentPID > 0 else { throw NiaUpdateError.install }
    }
}

struct NiaUpdateResult: Codable {
    let success: Bool
    let message: String?
}

enum NiaUpdateInstallation {
    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NiaUpdateError.invalidBundle }
    }

    static func validateBundle(_ app: URL, version: String) throws {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "dev.nia.terminal",
              plist["CFBundleExecutable"] as? String == "nia",
              plist["CFBundleShortVersionString"] as? String == version,
              let minimum = plist["LSMinimumSystemVersion"] as? String else { throw NiaUpdateError.invalidBundle }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        guard (1...3).contains(parts.count), parts.count == minimum.split(separator: ".").count,
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0)) else { throw NiaUpdateError.invalidBundle }
        let executable = app.appendingPathComponent("Contents/MacOS/nia")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              executable.resolvingSymlinksInPath() == executable.standardizedFileURL else { throw NiaUpdateError.invalidBundle }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/bin/lipo", ["-verify_arch", NiaUpdateCandidate.architecture, executable.path])
    }

    static func exchange(_ source: URL, _ destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw NiaUpdateError.install }
    }

    // Keep the old bundle at job.source until the updated application starts.
    // A failed launch swaps it back. No window or process is forcibly closed.
    static func install(_ job: NiaUpdateJob, isRunning: () -> Bool,
                        validate: (URL, String) throws -> Void = validateBundle,
                        launch: (URL) throws -> Void) throws {
        try job.validatePaths()
        let lock = job.destination.deletingLastPathComponent().appendingPathComponent(".nia-update-install.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw NiaUpdateError.permissions }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NiaUpdateError.running }
        defer { flock(fd, LOCK_UN) }
        guard !isRunning() else { throw NiaUpdateError.running }
        try validate(job.destination, job.fromVersion)
        try validate(job.source, job.toVersion)
        guard !isRunning() else { throw NiaUpdateError.running }
        try exchange(job.source, job.destination)
        do { try launch(job.destination) }
        catch {
            try exchange(job.source, job.destination)
            throw NiaUpdateError.install
        }
    }
}
