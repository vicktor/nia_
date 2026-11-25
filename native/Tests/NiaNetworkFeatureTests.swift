// SPDX-License-Identifier: MPL-2.0
import Foundation

@main struct NiaNetworkFeatureTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--github") {
            let service = NiaUpdateService()
            guard let candidate = try await service.candidate(current: "0.0.0", previews: true) else {
                fatalError("Expected a public release fixture")
            }
            let prepared = try await service.prepare(candidate)
            defer { try? FileManager.default.removeItem(at: prepared.directory) }
            try NiaUpdateInstallation.validateBundle(prepared.application, version: candidate.version)
            print("GitHub: fetched releases, verified SHA-256, safely extracted and validated \(candidate.version). No installation performed.")
        }
        if CommandLine.arguments.contains("--codex") {
            let snapshot = try await Task.detached { try NiaCodexUsage.read(customPath: "") }.value
            print("Codex: \(snapshot.windows.count) quota windows; weekly data: \(snapshot.weekly != nil); token total: \(snapshot.tokens != nil). No model request sent.")
        }
        if CommandLine.arguments.contains("--claude") {
            let snapshot = try await Task.detached { try NiaClaudeUsage.read(customPath: "") }.value
            print("Claude: weekly usage \(snapshot.weekly?.usedPercent.description ?? "unavailable")%; model windows: \(snapshot.windows.filter { $0.scope != nil }.count). No model request sent.")
        }
    }
}
