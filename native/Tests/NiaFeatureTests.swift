// SPDX-License-Identifier: MPL-2.0
import AppKit
import Foundation

enum NiaL10n { static func string(_ key: String) -> String { key } }

final class FontFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let fixture = URL(fileURLWithPath: "/tmp/nia-font-fixtures")
            .appendingPathComponent(url.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(url.lastPathComponent)
        do {
            let data = try Data(contentsOf: fixture)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct NiaFeatureTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }
    @MainActor static func fails(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) } catch { checks += 1 }
    }
    static func release(_ tag: String, preview: Bool = false, draft: Bool = false, arch: String = "arm64",
                        digest: String? = "sha256:" + String(repeating: "a", count: 64), host: String = "github.com") -> NiaRelease {
        let filename = "nia_-\(tag)-macos-\(arch).zip"
        return NiaRelease(tag_name: tag, html_url: URL(string: "https://github.com/vicktor/nia_/releases/tag/\(tag)")!,
            body: nil, draft: draft, prerelease: preview,
            assets: [.init(name: filename, browser_download_url: URL(string: "https://\(host)/vicktor/nia_/releases/download/\(tag)/\(filename)")!, size: 100, digest: digest, state: "uploaded")])
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        check(NiaVersion("v0.10.0")! > NiaVersion("0.9.9")!, "Numeric version ordering")
        check(NiaVersion("1.0.0")! > NiaVersion("1.0.0-rc.1")!, "Stable supersedes prerelease")
        check(NiaVersion("1.0.0-beta.10")! > NiaVersion("1.0.0-beta.2")!, "Numeric prerelease ordering")
        check(NiaVersion("1.0.0+build.2") == NiaVersion("1.0.0+build.1"), "Build metadata does not force upgrades")
        for bad in ["1.0", "01.0.0", "-1.0.0", "1.0.0-01", "1.0.0-a..b", "v1.2.3/../../x"] {
            check(NiaVersion(bad) == nil, "Reject invalid version \(bad)")
        }
        let releases = [release("v0.8.0", preview: true), release("v0.7.9"), release("v9.0.0", draft: true)]
        let stable = try NiaUpdateCandidate.select(releases, current: "0.7.6", previews: false, architecture: "arm64")
        let preview = try NiaUpdateCandidate.select(releases, current: "0.7.6", previews: true, architecture: "arm64")
        check(stable?.version == "0.7.9", "Stable channel ignores preview and draft")
        check(preview?.version == "0.8.0", "Preview channel offers newest release")
        let old = try NiaUpdateCandidate.select([release("v0.6.4", preview: true)], current: "0.7.6", previews: true)
        check(old == nil, "Never downgrade a local newer build")
        for bad in [release("v1.0.0", arch: "x86_64"), release("v1.0.0", digest: nil), release("v1.0.0", host: "example.com")] {
            fails("Reject unverified or wrong-architecture download") {
                _ = try NiaUpdateCandidate.select([bad], current: "0.7.6", previews: true, architecture: "arm64")
            }
        }
        check(!NiaDownloadPolicy.allows(URL(string: "https://github.com.evil.test/a")!), "Exact redirect hosts")
        check(!NiaDownloadPolicy.allows(URL(string: "http://github.com/a")!), "No TLS downgrade")
        check(!NiaDownloadPolicy.allows(URL(string: "https://secret@github.com/a")!), "No URL credentials")
        check(NiaDownloadPolicy.allows(URL(string: "https://release-assets.githubusercontent.com/a")!), "GitHub asset redirect supported")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nia-feature-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let digestFile = root.appendingPathComponent("digest")
        try Data("abc".utf8).write(to: digestFile)
        let digest = try NiaFileDigest.sha256(digestFile)
        check(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 checks actual downloaded bytes")

        func fixture() throws -> NiaUpdateJob {
            let parent = root.appendingPathComponent(UUID().uuidString)
            let job = NiaUpdateJob(directory: parent.appendingPathComponent(".nia-update-test"),
                destination: parent.appendingPathComponent("nia_.app"), fromVersion: "1.0.0", toVersion: "1.1.0", parentPID: getpid())
            try FileManager.default.createDirectory(at: job.destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: job.source, withIntermediateDirectories: true)
            try Data("1.0.0".utf8).write(to: job.destination.appendingPathComponent("version"))
            try Data("1.1.0".utf8).write(to: job.source.appendingPathComponent("version"))
            return job
        }
        func version(_ url: URL) throws -> String { try String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8) }
        func validate(_ url: URL, _ expected: String) throws {
            guard try version(url) == expected else { throw NiaUpdateError.changed }
        }
        let running = try fixture()
        fails("Never exchange a running bundle") {
            try NiaUpdateInstallation.install(running, isRunning: { true }, validate: validate) { _ in preconditionFailure("must not launch") }
        }
        let runningVersion = try version(running.destination)
        check(runningVersion == "1.0.0", "Running app remains untouched")
        let rollback = try fixture()
        fails("Launch failure must roll back") {
            try NiaUpdateInstallation.install(rollback, isRunning: { false }, validate: validate) { _ in throw NiaUpdateError.install }
        }
        let rolledBackVersion = try version(rollback.destination)
        check(rolledBackVersion == "1.0.0", "Old bundle restored after launch failure")
        let success = try fixture()
        try NiaUpdateInstallation.install(success, isRunning: { false }, validate: validate) { _ in }
        let newVersion = try version(success.destination), backupVersion = try version(success.source)
        check(newVersion == "1.1.0" && backupVersion == "1.0.0", "Atomic swap preserves old bundle until successful startup")
        let changed = try fixture()
        try Data("2.0.0".utf8).write(to: changed.destination.appendingPathComponent("version"))
        fails("Concurrent installation must not be overwritten") {
            try NiaUpdateInstallation.install(changed, isRunning: { false }, validate: validate) { _ in }
        }

        let settings = root.appendingPathComponent("Claude config/settings.json")
        let directory = root.appendingPathComponent("usage with ' quotes")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = ["model": "preserved", "permissions": ["allow": ["Read"]],
            "statusLine": ["type": "command", "command": "printf '%s' \"existing status\"", "padding": 2]]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)
        try NiaClaudeConnection.connect(settings: settings, directory: directory, helper: URL(fileURLWithPath: "/usr/bin/true"))
        check(NiaClaudeConnection.isConnected(settings: settings, directory: directory), "Claude bridge connected")
        let connected = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        check(connected["model"] as? String == "preserved", "Preserve unrelated Claude preferences")
        check((connected["statusLine"] as? [String: Any])?["padding"] as? Int == 2, "Preserve status line presentation")
        try NiaClaudeConnection.disconnect(settings: settings, directory: directory)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! NSDictionary
        check(restored == original as NSDictionary, "Disconnect restores original status line without losing other settings")
        try NiaClaudeConnection.connect(settings: settings, directory: directory, helper: URL(fileURLWithPath: "/usr/bin/true"))
        var edited = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        edited["statusLine"] = ["type": "command", "command": "user changed it"]
        let editedData = try JSONSerialization.data(withJSONObject: edited)
        try editedData.write(to: settings)
        fails("Disconnect must not overwrite a user's newer change") { try NiaClaudeConnection.disconnect(settings: settings, directory: directory) }
        let unchanged = try Data(contentsOf: settings)
        check(unchanged == editedData, "New user settings remain byte-for-byte intact")

        let now = Date(), future = now.addingTimeInterval(3600).timeIntervalSince1970
        let quota = NiaUsageSnapshot.codex(limits: ["rateLimits": ["primary": ["usedPercent": 20.0, "windowDurationMins": 300],
            "secondary": ["usedPercent": 42.0, "windowDurationMins": 10080, "resetsAt": future]]],
            usage: ["summary": ["lifetimeTokens": 12345]])
        check(quota.weekly?.usedPercent == 42, "Weekly bucket distinguished from five-hour quota")
        check(quota.tokens == 12345, "Account token total remains separate")
        let absent = NiaUsageSnapshot.codex(limits: [:], usage: nil)
        check(absent.weekly == nil && absent.tokens == nil, "Missing usage is not zero")
        let claude = try NiaUsageSnapshot.claude(JSONSerialization.data(withJSONObject: ["updated_at": now.timeIntervalSince1970,
            "rate_limits": ["seven_day": ["used_percentage": 80.5, "resets_at": future]], "input_tokens": 100, "output_tokens": 25]))
        check(claude.weekly?.usedPercent == 80.5 && claude.tokens == 125, "Claude status line quotas and session tokens")
        let expired = try NiaUsageSnapshot.claude(JSONSerialization.data(withJSONObject: ["updated_at": now.timeIntervalSince1970 - 3600,
            "rate_limits": ["seven_day": ["used_percentage": 100, "resets_at": now.timeIntervalSince1970 - 1]]]))
        check(expired.weekly == nil && expired.stale, "Expired quota is unavailable, not still exhausted")

        if CommandLine.arguments.contains("--font-download") {
            let catalog = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("native/Resources/FontCatalog.json")
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FontFixtureProtocol.self]
            let library = NiaFontLibrary(catalogURL: catalog, directory: root.appendingPathComponent("downloaded-fonts"),
                                        http: NiaHTTP(session: URLSession(configuration: config)))
            let name = await library.download(library.catalog.first!)
            check(name == "JetBrainsMono-Regular", "New download selects the regular named instance")
            check(library.installed.contains { $0.name == name }, "Picker refreshes after a download even when the system font list was already cached")
        }
        if CommandLine.arguments.contains("--fonts") {
            let catalog = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("native/Resources/FontCatalog.json")
            let fixtureRoot = URL(fileURLWithPath: "/tmp/nia-font-fixtures").resolvingSymlinksInPath()
            let library = NiaFontLibrary(catalogURL: catalog, directory: fixtureRoot)
            check(library.catalog.count == 5 && library.downloaded.count == 5, "All five verified font families register for this process")
            for font in library.catalog {
                let name = library.downloaded[font.id]!
                check(name.contains("Regular"), "Select the regular named instance, not a thin variable default")
                check(library.installed.contains { $0.name == name }, "Downloaded font appears in the font picker")
                check(library.installed.first { $0.name == name }?.title == "\(font.name) Regular", "Variable-font labels identify the selected instance, not the file's default weight")
            }
        }
        print("\(checks) update, installation, font and usage checks passed")
    }
}
