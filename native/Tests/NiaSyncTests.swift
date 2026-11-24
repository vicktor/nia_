// SPDX-License-Identifier: MPL-2.0
import Foundation

@main struct NiaSyncTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nia-sync-tests-\(UUID().uuidString)")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let cloud = root.appendingPathComponent("cloud"), key = NiaSyncEngine.newKey()
        try NiaSyncEngine.create(folder:cloud,key:key)
        let a = try NiaSyncEngine(folder:cloud,key:key,cache:root.appendingPathComponent("mac-a"))
        let b = try NiaSyncEngine(folder:cloud,key:key,cache:root.appendingPathComponent("mac-b"))
        var checks = 0
        func check(_ value: Bool, _ description: String) { precondition(value,description); checks += 1 }
        func rejected(_ description: String, _ body: () throws -> Void) { do { try body(); fatalError(description) } catch { checks += 1 } }
        rejected("wrong key must fail") { _ = try NiaSyncEngine(folder:cloud,key:NiaSyncEngine.newKey(),cache:root.appendingPathComponent("wrong")) }
        rejected("must not replace space") { try NiaSyncEngine.create(folder:cloud,key:key) }
        let metadata = Data(#"{"title":"Private project","cwd":"/tmp/private","remote_host":null}"#.utf8)
        let transcript = root.appendingPathComponent("transcript")
        var log = Data(repeating:65,count:NiaSyncEngine.chunkSize)
        log.append(Data("\u{1b}[31mprivate token red\u{1b}[0m\r\n".utf8))
        try log.write(to:transcript)
        let shell = root.appendingPathComponent("shell")
        try Data("echo private\n".utf8).write(to:shell)
        var snapshot = NiaSyncSnapshot(metadata:metadata,transcript:NiaSyncFile(path:transcript.path,length:UInt64(log.count)),history:NiaSyncFile(path:shell.path,length:13))
        let first = try a.synchronize(selected:["local-a"],deviceName:"Mac A") { _ in snapshot }
        check(first.count == 1,"one exported revision")
        check(first[0].summary.title == "Private project","decrypted title")
        let same = try a.synchronize(selected:["local-a"],deviceName:"Mac A") { _ in snapshot }
        check(same[0].id == first[0].id,"unchanged data creates no new revision")
        let received = try b.synchronize(selected:[],deviceName:"Mac B") { _ in fatalError() }
        check(received[0].id == first[0].id,"second Mac discovers revision")
        let restored = try b.restore(received[0]) { stage,_ in
            check(try Data(contentsOf:stage.appendingPathComponent("transcript.bin")) == log,"exact ANSI preserved")
            check(try Data(contentsOf:stage.appendingPathComponent("shell_history")) == Data("echo private\n".utf8),"shell history preserved")
            return "local-b"
        }
        check(restored == "local-b","local importer used")
        let blobs = cloud.appendingPathComponent("blobs")
        let before = Set(try fm.contentsOfDirectory(atPath:blobs.path))
        log.append(Data("new line\n".utf8)); try log.write(to:transcript)
        snapshot = NiaSyncSnapshot(metadata:metadata,transcript:NiaSyncFile(path:transcript.path,length:UInt64(log.count)),history:snapshot.history)
        let changed = try a.synchronize(selected:["local-a"],deviceName:"Mac A") { _ in snapshot }
        let after = Set(try fm.contentsOfDirectory(atPath:blobs.path))
        check(after.subtracting(before).count == 1,"append uploads only new tail block")
        check(changed.count == 1 && changed[0].revision.parent == first[0].id,"own branch advances")
        let fork = try b.synchronize(selected:["local-b"],deviceName:"Mac B") { _ in NiaSyncSnapshot(metadata:Data(#"{"title":"Parallel B","cwd":"/tmp/private","remote_host":null}"#.utf8),transcript:nil,history:nil) }
        check(fork.count == 2 && fork.allSatisfy(\.hasConflict),"concurrent branches are retained")
        // A checkpoint arriving before a chunk must never call the importer.
        let missing = blobs.appendingPathComponent(changed[0].revision.transcript[0] + ".bin")
        let held = try Data(contentsOf:missing); try fm.removeItem(at:missing)
        var imported = false
        rejected("partial transfer must not import") { _ = try b.restore(changed[0]) { _,_ in imported = true; return "bad" } }
        check(!imported,"import not called for partial data")
        try held.write(to:missing)
        _ = try b.restore(changed[0]) { _,_ in "recovered" }; checks += 1
        var tampered = held; tampered[0] ^= 1; try tampered.write(to:missing)
        rejected("tampering must fail authentication") { _ = try b.restore(changed[0]) { _,_ in imported = true; return "bad" } }
        check(!imported,"corrupt data never reaches importer")
        try held.write(to:missing)
        for dir in [blobs,cloud.appendingPathComponent("revisions")] {
            for file in try fm.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil) {
                let data = try Data(contentsOf:file)
                check(data.range(of:Data("private".utf8)) == nil,"no plaintext data in transport")
            }
        }
        // Restart reads the durable parent link; no duplicate revision on polling.
        let restarted = try NiaSyncEngine(folder:cloud,key:key,cache:root.appendingPathComponent("mac-a"))
        let heads = try restarted.synchronize(selected:["local-a"],deviceName:"Mac A") { _ in snapshot }
        check(heads.count == 2 && heads.contains(where:{$0.id == changed[0].id}),"restart preserves lineage and deduplication")
        // Symlinked payload files cannot cause arbitrary local file reads.
        try fm.removeItem(at:missing)
        try fm.createSymbolicLink(at:missing,withDestinationURL:transcript)
        rejected("symlink payload rejected") { _ = try b.restore(changed[0]) { _,_ in fatalError() } }
        // Crash before/after publication must retry the same pending revision.
        let retryCloud = root.appendingPathComponent("retry-cloud")
        let retryCache = root.appendingPathComponent("retry-cache")
        try NiaSyncEngine.create(folder:retryCloud,key:key)
        let retryEngine = try NiaSyncEngine(folder:retryCloud,key:key,cache:retryCache)
        let revisionDirectory = retryCloud.appendingPathComponent("revisions")
        try Data("simulate unavailable destination".utf8).write(to:revisionDirectory)
        let small = NiaSyncSnapshot(metadata:metadata,transcript:nil,history:nil)
        rejected("publication failure is visible") { _ = try retryEngine.synchronize(selected:["s"],deviceName:"Retry Mac") { _ in small } }
        let stateFile = retryCache.appendingPathComponent(retryEngine.spaceID + ".json")
        let pendingState = try Data(contentsOf:stateFile)
        try fm.removeItem(at:revisionDirectory)
        let retried = try retryEngine.synchronize(selected:["s"],deviceName:"Retry Mac") { _ in small }
        check(retried.count == 1,"pre-publication crash recovers checkpoint")
        // Simulate a crash after the cloud write but before committing local state.
        try pendingState.write(to:stateFile)
        let afterCrash = try retryEngine.synchronize(selected:["s"],deviceName:"Retry Mac") { _ in small }
        check(afterCrash.count == 1 && afterCrash[0].id == retried[0].id,"post-publication crash reuses ID without forks")
        // Two instances sharing a local cache cannot publish simultaneously.
        let competitor = try NiaSyncEngine(folder:cloud,key:key,cache:root.appendingPathComponent("mac-a"))
        var sawLock = false
        _ = try a.synchronize(selected:["lock-check"],deviceName:"Mac A") { _ in
            do { _ = try competitor.synchronize(selected:[],deviceName:"Other instance") { _ in fatalError() } }
            catch NiaSyncError.busy { sawLock = true }
            return NiaSyncSnapshot(metadata:metadata,transcript:nil,history:nil)
        }
        check(sawLock,"independent instances serialize on local advisory lock")
        print("Nia Sync: \(checks) checks passed (two device stores, encryption, conflicts, incremental transfer, retries, privacy).")
    }
}
