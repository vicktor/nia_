// SPDX-License-Identifier: MPL-2.0
import Foundation

struct NiaPreparedUpdate: Sendable {
    let directory: URL
    var application: URL { directory.appendingPathComponent("unpacked/nia_.app") }
}

struct NiaUpdateService: Sendable {
    let http: NiaHTTP
    let allowGitHubCLI: Bool
    init(http: NiaHTTP = NiaHTTP(), allowGitHubCLI: Bool = true) {
        self.http = http
        self.allowGitHubCLI = allowGitHubCLI
    }

    func candidate(current: String, previews: Bool) async throws -> NiaUpdateCandidate? {
        do {
            return try NiaUpdateCandidate.select(try await http.releases(), current: current, previews: previews)
        } catch let error as NiaUpdateError where allowGitHubCLI && (error == .repositoryAccess || error == .rateLimit) {
            var candidate = try NiaUpdateCandidate.select(try await NiaGitHubCLI.releases(), current: current, previews: previews)
            candidate?.usesGitHubCLI = true
            return candidate
        }
    }

    func prepare(_ candidate: NiaUpdateCandidate) async throws -> NiaPreparedUpdate {
        let temporary: URL
        if candidate.usesGitHubCLI {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("nia-asset-\(UUID().uuidString).zip")
            do { try await NiaGitHubCLI.download(candidate.asset, to: output) }
            catch { try? FileManager.default.removeItem(at: output); throw error }
            temporary = output
        } else {
            let (file, response) = try await http.session.download(for: http.request(candidate.asset.browser_download_url))
            do { _ = try http.validate(response) }
            catch { try? FileManager.default.removeItem(at: file); throw error }
            temporary = file
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nia-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent("update.zip")
        do {
            try FileManager.default.moveItem(at: temporary, to: archive)
            let prepared = NiaPreparedUpdate(directory: directory)
            try await Task.detached {
                let size = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
                guard size?.int64Value == candidate.asset.size,
                      try NiaFileDigest.sha256(archive) == candidate.sha256 else { throw NiaUpdateError.invalidDownload }
                let output = directory.appendingPathComponent("unpacked")
                let status = archive.path.withCString { zip in
                    output.path.withCString { destination in nia_unpack_update(zip, destination) }
                }
                guard status == 0 else { throw NiaUpdateError.invalidDownload }
                try NiaUpdateInstallation.validateBundle(prepared.application, version: candidate.version)
            }.value
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: archive)
            return prepared
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func stage(_ prepared: NiaPreparedUpdate, destination: URL, from: String, to: String, parentPID: Int32) throws -> NiaUpdateJob {
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: destination.path) else { throw NiaUpdateError.permissions }
        let directory = parent.appendingPathComponent(".nia-update-\(UUID().uuidString)", isDirectory: true)
        let job = NiaUpdateJob(directory: directory, destination: destination, fromVersion: from, toVersion: to, parentPID: parentPID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        do {
            try job.validatePaths()
            try FileManager.default.copyItem(at: prepared.application, to: job.source)
            try NiaUpdateInstallation.validateBundle(job.source, version: to)
            // Run our current, trusted helper from outside the bundle being replaced.
            let helper = destination.appendingPathComponent("Contents/MacOS/nia-update-installer")
            try FileManager.default.copyItem(at: helper, to: directory.appendingPathComponent("installer"))
            try JSONEncoder().encode(job).write(to: job.manifestURL, options: .atomic)
            return job
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
