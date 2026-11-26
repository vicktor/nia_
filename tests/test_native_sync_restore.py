#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Exercise the real restore coordinator and encrypted engine in isolation.

Only configuration, local catalog and the Rust import boundary are substituted;
no user preferences, accounts, Keychain entries, PTYs or sessions are accessed.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
import AppKit
import SwiftUI

enum NiaL10n { static func string(_ key: String) -> String { key } }
struct ImportFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
final class ImportStore: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String:String] = [:]
    private var calls = 0
    private var broken = true
    private var offMain = true
    func repair() { lock.lock(); defer { lock.unlock() }; broken = false }
    func stats() -> (Int, Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (records.count,calls,offMain)
    }
    func request(_ request: [String:String]) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        calls += 1; offMain = offMain && !Thread.isMainThread
        precondition(request["operation"] == "import")
        let revision = request["revision"]!, stage = URL(fileURLWithPath:request["stage"]!)
        if let id = records[revision] { return try JSONSerialization.data(withJSONObject:["id":id]) }
        let metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:stage.appendingPathComponent("metadata.json"))) as! [String:Any]
        let title = metadata["title"] as! String
        if title == "A missing folder" && request["directory"] == nil { throw ImportFailure(text:"SYNC_DIRECTORY_REQUIRED") }
        if title == "B failed session" && broken { throw ImportFailure(text:"Fixture import failed") }
        let transcript = try Data(contentsOf:stage.appendingPathComponent("transcript.bin"))
        precondition(transcript == Data("\u{1b}[31m\(title)\u{1b}[0m\r\n".utf8))
        // The real Rust store also returns the existing ID for a repeated revision.
        let id = "local-\(revision)"
        records[revision] = id
        return try JSONSerialization.data(withJSONObject:["id":id])
    }
}
enum NiaSyncBridge {
    static let store = ImportStore()
    static func request(_ values: [String:String]) throws -> Data { try store.request(values) }
}

__ISSUE__

@MainActor final class NiaSync: ObservableObject {
    @Published var busy = false
    @Published var message = ""
    @Published var items: [NiaSyncItem] = []
    @Published var directoryRequest: NiaSyncItem?
    @Published var restoreIssues: [String:NiaSyncRestoreIssue] = [:]
    var selected = Set<String>()
    var refreshes = 0
    var folder: URL
    var key: String
    static var cache = URL(fileURLWithPath:"/unused")
    init(folder: URL, key: String) { self.folder = folder; self.key = key }
    private func configuration() throws -> (URL,String,String?) { (folder,key,nil) }
    func select(_ id: String, _ value: Bool) { if value { selected.insert(id) } }
    func refreshCatalog() { refreshes += 1 }

__RESTORE_METHODS__
}

@main struct RestoreTests {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func finished(_ sync: NiaSync) async throws {
        let deadline = Date(timeIntervalSinceNow:5)
        while sync.busy && Date() < deadline { try await Task.sleep(nanoseconds:5_000_000) }
        check(!sync.busy,"the batch must finish and release the busy state")
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nia-restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at:root) }
        let folder = root.appendingPathComponent("shared"), key = NiaSyncEngine.newKey()
        try NiaSyncEngine.create(folder:folder,key:key)
        let sender = try NiaSyncEngine(folder:folder,key:key,cache:root.appendingPathComponent("sender"))
        let titles = ["A missing folder","B failed session","C left","D right"]
        let catalog = try sender.synchronize(selected:titles,deviceName:"Sender") { title in
            let log = root.appendingPathComponent(title)
            let bytes = Data("\u{1b}[31m\(title)\u{1b}[0m\r\n".utf8)
            try bytes.write(to:log)
            let metadata = try JSONSerialization.data(withJSONObject:["title":title,"cwd":"/fixture","remote_host":NSNull()])
            return NiaSyncSnapshot(metadata:metadata,transcript:NiaSyncFile(path:log.path,length:UInt64(bytes.count)),history:nil)
        }
        NiaSync.cache = root.appendingPathComponent("receiver")
        let sync = NiaSync(folder:folder,key:key)
        sync.items = catalog.sorted { $0.summary.title < $1.summary.title }
        var tabs = ["already-open"]
        let opened: (String) -> Void = { id in
            check(Thread.isMainThread,"tabs must be opened on the main actor")
            if !tabs.contains(id) { tabs.append(id) }
        }
        sync.resumeAll(opened:opened)
        check(sync.busy,"the batch must immediately block concurrent requests")
        sync.resumeAll(opened:opened)
        try await finished(sync)
        check(NiaSyncBridge.store.stats().1 == 4,"a second click while busy must not start another batch")
        check(tabs.count == 3 && tabs.first == "already-open","both valid sessions open and existing tabs remain")
        check(sync.selected.count == 2,"every restored session is selected for subsequent sync")
        check(sync.restoreIssues.count == 2,"each failed session remains individually actionable")
        let missing = sync.items.first { $0.summary.title == "A missing folder" }!
        let failed = sync.items.first { $0.summary.title == "B failed session" }!
        check(sync.restoreIssues[missing.id]?.needsDirectory == true,"a missing project requests its own folder")
        check(sync.restoreIssues[failed.id]?.needsDirectory == false,"other failures do not request a folder")
        check(sync.message.contains("restauradas: 2") && sync.message.contains("Pendientes: 2"),"partial completion reports both counts")
        check(sync.refreshes == 1,"the catalog is refreshed once after a batch")
        check(NiaSyncBridge.store.stats().2,"file restoration and import must stay off the UI thread")

        sync.resume(missing,directory:root,opened:opened)
        try await finished(sync)
        check(sync.restoreIssues[missing.id] == nil && sync.restoreIssues[failed.id] != nil,"folder retry clears only that session's issue")
        NiaSyncBridge.store.repair()
        sync.resumeAll(opened:opened)
        try await finished(sync)
        check(tabs.count == 5 && sync.selected.count == 4,"retrying the batch opens every session without duplicate tabs")
        check(NiaSyncBridge.store.stats().0 == 4,"repeated checkpoints retain their original local IDs")
        check(sync.restoreIssues.isEmpty,"a successful batch leaves no pending issues")
        sync.resumeAll(opened:opened)
        try await finished(sync)
        check(tabs.count == 5 && NiaSyncBridge.store.stats().0 == 4,"repeating restore all remains idempotent")
        let calls = NiaSyncBridge.store.stats().1
        sync.items = []
        sync.resumeAll(opened:opened)
        check(!sync.busy && NiaSyncBridge.store.stats().1 == calls,"an empty catalog is a no-op")
        print("Batch restore passed: partial failures, all tabs, background work, busy guard, retries and existing tabs")
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "Requires AppKit and SwiftUI")
class NativeSyncRestoreTests(unittest.TestCase):
    def test_restore_all_continues_after_individual_failures(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("Swift compiler unavailable")
        source = (ROOT / "native/Sources/NiaSync.swift").read_text()
        issue_start = source.index("struct NiaSyncRestoreIssue {")
        issue = source[issue_start:source.index("\n}", issue_start) + 2]
        start = source.index("    func resume(_ item:")
        methods = source[start:source.index("\n}\n", start)]
        with tempfile.TemporaryDirectory(prefix="nia-sync-restore-tests-") as directory:
            path = Path(directory)
            harness = path / "RestoreTests.swift"
            harness.write_text(HARNESS.replace("__ISSUE__", issue).replace("__RESTORE_METHODS__", methods))
            binary = path / "restore-tests"
            build = subprocess.run([compiler, "-parse-as-library", str(harness),
                                    str(ROOT / "native/Sources/NiaSyncEngine.swift"), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
