// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

enum NiaSyncError: String, Error, LocalizedError {
    case invalid = "Los datos de sincronización no son válidos o están dañados."
    case key = "La clave no corresponde a esta carpeta de sincronización."
    case pending = "Esperando a que iCloud Drive o Google Drive descargue los archivos."
    case busy = "Otra instancia de nia_ está sincronizando. Se reintentará automáticamente."
    case limit = "La sesión supera los límites de esta beta de sincronización."
    case changed = "El historial ha cambiado durante la lectura. Se reintentará."
    var errorDescription: String? { rawValue }
}

struct NiaSyncFile: Codable, Sendable { let path: String; let length: UInt64 }
struct NiaSyncSnapshot: Sendable {
    let metadata: Data
    let transcript: NiaSyncFile?
    let history: NiaSyncFile?
}
struct NiaSyncSummary: Codable, Sendable {
    let title: String
    let cwd: String
    let remote_host: String?
}
struct NiaSyncRevision: Codable, Sendable, Identifiable {
    let version: Int
    let id: String
    let session: String
    let parent: String?
    let device: String
    let deviceName: String
    let created: Date
    let metadata: String
    let transcript: [String]
    let history: [String]
}
struct NiaSyncItem: Sendable, Identifiable {
    let revision: NiaSyncRevision
    let summary: NiaSyncSummary
    let hasConflict: Bool
    var id: String { revision.id }
}
private struct NiaSyncHeader: Codable { let version: Int; let id: String; let check: Data }
private struct NiaSyncLink: Codable {
    var session: String
    var parent: String?
    var signature: String?
    var sourceSignature: String?
    var pending: NiaSyncRevision?
}
private struct NiaSyncState: Codable {
    var device = UUID().uuidString.lowercased()
    var links: [String: NiaSyncLink] = [:]
}

/// Files in this folder are transport, never the application's live database.
/// All content and names (except random IDs and format version) are encrypted.
/// Work runs on a background queue. A local flock serializes separate processes.
final class NiaSyncEngine {
    static let chunkSize = 1024 * 1024
    let folder: URL
    let cache: URL
    private let key: SymmetricKey
    private let addressKey: SymmetricKey
    private let header: NiaSyncHeader
    private let fm = FileManager.default
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder = JSONDecoder()

    static func newKey() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() } }
    private static func parseKey(_ text: String) throws -> SymmetricKey {
        guard let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 32 else { throw NiaSyncError.key }
        return SymmetricKey(data: bytes)
    }
    static func create(folder: URL, key text: String) throws {
        let key = try parseKey(text)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString.lowercased()
        let check = try AES.GCM.seal(Data("nia-sync-v1".utf8), using: key, authenticating: Data("\(id)/header".utf8)).combined!
        let bytes = try JSONEncoder().encode(NiaSyncHeader(version: 1, id: id, check: check))
        // Never replace a space or silently replace its key. Create on one Mac,
        // then join on the other once the provider has delivered space.json.
        try coordinated(folder, writing: true) { url in
            guard !fm.fileExists(atPath: url.appendingPathComponent("space.json").path),
                  !fm.fileExists(atPath: url.appendingPathComponent(".space.json.icloud").path) else { throw NiaSyncError.invalid }
            try bytes.write(to: url.appendingPathComponent("space.json"), options: [.atomic])
        }
    }
    static func validateHeader(_ data: Data, key text: String) throws -> String {
        guard data.count <= 4096 else { throw NiaSyncError.limit }
        let master = try parseKey(text)
        let header = try JSONDecoder().decode(NiaSyncHeader.self,from:data)
        guard header.version == 1, UUID(uuidString:header.id) != nil else { throw NiaSyncError.invalid }
        do {
            let check = try AES.GCM.open(AES.GCM.SealedBox(combined:header.check),using:master,authenticating:Data("\(header.id)/header".utf8))
            guard check == Data("nia-sync-v1".utf8) else { throw NiaSyncError.key }
        } catch { throw NiaSyncError.key }
        return header.id
    }
    init(folder: URL, key text: String, cache: URL) throws {
        self.folder = folder
        self.cache = cache
        let master = try Self.parseKey(text)
        header = try JSONDecoder().decode(NiaSyncHeader.self, from: Self.read(folder.appendingPathComponent("space.json"), max: 4096))
        guard header.version == 1, UUID(uuidString: header.id) != nil else { throw NiaSyncError.invalid }
        do {
            let check = try AES.GCM.open(AES.GCM.SealedBox(combined: header.check), using: master, authenticating: Data("\(header.id)/header".utf8))
            guard check == Data("nia-sync-v1".utf8) else { throw NiaSyncError.key }
        } catch { throw NiaSyncError.key }
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial:master,salt:Data(header.id.utf8),info:Data("nia-sync-v1/encryption".utf8),outputByteCount:32)
        addressKey = HKDF<SHA256>.deriveKey(inputKeyMaterial:master,salt:Data(header.id.utf8),info:Data("nia-sync-v1/addresses".utf8),outputByteCount:32)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var spaceID: String { header.id }
    private var stateURL: URL { cache.appendingPathComponent("\(header.id).json") }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        let fd = Darwin.open(cache.appendingPathComponent("\(header.id).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NiaSyncError.invalid }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NiaSyncError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func state() throws -> NiaSyncState {
        guard fm.fileExists(atPath: stateURL.path) else { return NiaSyncState() }
        return try decoder.decode(NiaSyncState.self, from: Self.read(stateURL, max: 16 * Self.chunkSize))
    }
    private func save(_ value: NiaSyncState) throws {
        try encoder.encode(value).write(to: stateURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    private static func coordinated<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        var failure: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &failure) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &failure) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        }
        if let failure { throw failure }
        guard let result else { throw NiaSyncError.invalid }
        return try result.get()
    }
    private static func read(_ url: URL, max: Int) throws -> Data {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current, values.ubiquitousItemDownloadingStatus != .downloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw NiaSyncError.pending
        }
        return try coordinated(url, writing: false) { path in
            let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else {
                if errno == ENOENT { throw NiaSyncError.pending }
                if errno == ELOOP { throw NiaSyncError.invalid }
                throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= max else { throw NiaSyncError.limit }
            let data = try handle.read(upToCount: max + 1) ?? Data()
            guard data.count <= max else { throw NiaSyncError.limit }
            return data
        }
    }
    private func aad(_ kind: String, _ id: String) -> Data { Data("nia-sync-v1/\(header.id)/\(kind)/\(id)".utf8) }
    private func digest(_ bytes: Data) -> String { HMAC<SHA256>.authenticationCode(for: bytes, using: addressKey).map { String(format: "%02x", $0) }.joined() }
    private func path(_ kind: String, _ id: String) throws -> URL {
        guard kind == "blobs" || kind == "revisions" else { throw NiaSyncError.invalid }
        guard (kind == "blobs" && id.count == 64 && id.allSatisfy({ $0.isHexDigit && $0.isASCII })) || (kind == "revisions" && UUID(uuidString: id) != nil) else { throw NiaSyncError.invalid }
        let dir = folder.appendingPathComponent(kind, isDirectory: true)
        if (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw NiaSyncError.invalid }
        return dir.appendingPathComponent(id + ".bin")
    }
    private func get(_ kind: String, _ id: String, max: Int) throws -> Data {
        let bytes = try Self.read(path(kind,id), max: max + 28)
        return try openCiphertext(bytes,kind:kind,id:id,max:max)
    }
    private func openCiphertext(_ bytes: Data, kind: String, id: String, max: Int) throws -> Data {
        guard bytes.count <= max + 28 else { throw NiaSyncError.limit }
        let data: Data
        do { data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad(kind,id)) }
        catch { throw NiaSyncError.invalid }
        if kind == "blobs", digest(data) != id { throw NiaSyncError.invalid }
        return data
    }
    func validateTransportFile(_ relativePath: String, data: Data) throws {
        let parts = relativePath.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count == 2, parts[1].hasSuffix(".bin") else { throw NiaSyncError.invalid }
        let kind = String(parts[0]), id = String(parts[1].dropLast(4))
        _ = try path(kind,id)
        let plaintext = try openCiphertext(data,kind:kind,id:id,max:kind == "blobs" ? 16 * Self.chunkSize : Self.chunkSize)
        if kind == "revisions" {
            let revision = try decoder.decode(NiaSyncRevision.self,from:plaintext)
            guard revision.version == 1, revision.id == id else { throw NiaSyncError.invalid }
        }
    }
    private func put(_ kind: String, _ id: String, data: Data) throws {
        let url = try path(kind,id)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Verify existing data before reusing it. Never trust a truncated upload.
        if fm.fileExists(atPath: url.path) { guard try get(kind,id,max:data.count) == data else { throw NiaSyncError.invalid }; return }
        let sealed = try AES.GCM.seal(data, using: key, authenticating: aad(kind,id)).combined!
        try Self.coordinated(url, writing: true) { target in
            if fm.fileExists(atPath: target.path) { return }
            try sealed.write(to: target, options: .atomic)
        }
    }
    private func blob(_ data: Data) throws -> String {
        let id = digest(data); try put("blobs",id,data:data); return id
    }
    private func chunks(_ file: NiaSyncFile?, limit: UInt64, appendOnly: Bool = false) throws -> [String] {
        guard let file else { return [] }
        guard file.length <= limit else { throw NiaSyncError.limit }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw NiaSyncError.changed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= file.length else { throw NiaSyncError.changed }
        var remaining = file.length
        var ids: [String] = []
        while remaining > 0 {
            let count = Int(min(UInt64(Self.chunkSize), remaining))
            guard let data = try handle.read(upToCount: count), data.count == count else { throw NiaSyncError.changed }
            ids.append(try blob(data)); remaining -= UInt64(count)
        }
        var after = stat()
        guard fstat(fd,&after) == 0, after.st_size >= file.length else { throw NiaSyncError.changed }
        if !appendOnly && (after.st_size != info.st_size || after.st_mtimespec.tv_sec != info.st_mtimespec.tv_sec || after.st_mtimespec.tv_nsec != info.st_mtimespec.tv_nsec) { throw NiaSyncError.changed }
        return ids
    }
    private func sourceSignature(_ snapshot: NiaSyncSnapshot) throws -> String {
        var stamp = snapshot.metadata
        for file in [snapshot.transcript,snapshot.history] {
            guard let file else { stamp.append(Data("/absent".utf8)); continue }
            var info = stat()
            guard lstat(file.path,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NiaSyncError.changed }
            stamp.append(Data("/\(file.path)/\(file.length)/\(info.st_dev)/\(info.st_ino)/\(info.st_size)/\(info.st_mtimespec.tv_sec)/\(info.st_mtimespec.tv_nsec)".utf8))
        }
        return digest(stamp)
    }
    func synchronize(selected: [String], deviceName: String, export: (String) throws -> NiaSyncSnapshot) throws -> [NiaSyncItem] {
        try locked {
            var state = try state()
            // Commit device identity before any cloud writes (survives crashes).
            try save(state)
            for localID in selected.sorted() {
                var link = state.links[localID] ?? NiaSyncLink(session: UUID().uuidString.lowercased())
                // Persist the exact revision before publishing it, so a crash
                // anywhere around publication retries the same ID and payload.
                if let pending = link.pending {
                    try put("revisions",pending.id,data:encoder.encode(pending))
                    link.parent = pending.id
                    link.signature = digest(Data(([pending.metadata] + pending.transcript + ["history"] + pending.history).joined(separator:"/").utf8))
                    link.pending = nil
                    state.links[localID] = link
                    try save(state)
                }
                let snapshot = try export(localID)
                guard snapshot.metadata.count <= 16 * Self.chunkSize else { throw NiaSyncError.limit }
                let sourceSignature = try sourceSignature(snapshot)
                if link.sourceSignature == sourceSignature, link.signature != nil, link.parent != nil { continue }
                let metadata = try blob(snapshot.metadata)
                let transcript = try chunks(snapshot.transcript, limit: 2 * 1024 * 1024 * 1024, appendOnly: true)
                let history = try chunks(snapshot.history, limit: 64 * 1024 * 1024)
                let signature = digest(Data(([metadata] + transcript + ["history"] + history).joined(separator: "/").utf8))
                link.sourceSignature = sourceSignature
                if link.signature == signature { state.links[localID] = link; try save(state); continue }
                let revision = NiaSyncRevision(version: 1, id: UUID().uuidString.lowercased(), session: link.session, parent: link.parent,
                    device: state.device, deviceName: String(deviceName.prefix(128)), created: Date(), metadata: metadata, transcript: transcript, history: history)
                link.pending = revision
                state.links[localID] = link
                try save(state)
                // Revision is published last: interrupted exports remain invisible.
                try put("revisions",revision.id,data:encoder.encode(revision))
                link.parent = revision.id; link.signature = signature; link.pending = nil
                state.links[localID] = link
                try save(state)
            }
            return try list()
        }
    }
    private func list() throws -> [NiaSyncItem] {
        let directory = folder.appendingPathComponent("revisions", isDirectory: true)
        guard fm.fileExists(atPath: directory.path) else { return [] }
        if (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw NiaSyncError.invalid }
        let files = try Self.coordinated(directory, writing: false) { try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        guard files.count <= 10000 else { throw NiaSyncError.limit }
        var revisions: [NiaSyncRevision] = []
        for file in files {
            // iCloud may expose placeholders; request them without blocking the UI.
            if file.pathExtension == "icloud" {
                let name = String(file.lastPathComponent.dropFirst().dropLast(7))
                try? fm.startDownloadingUbiquitousItem(at: directory.appendingPathComponent(name))
                throw NiaSyncError.pending
            }
            guard file.pathExtension == "bin", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            let revision = try decoder.decode(NiaSyncRevision.self, from: get("revisions",id,max:Self.chunkSize))
            guard revision.version == 1, revision.id == id, UUID(uuidString: revision.session) != nil, UUID(uuidString: revision.device) != nil,
                  revision.parent == nil || UUID(uuidString: revision.parent!) != nil, revision.parent != id,
                  revision.transcript.count <= 2048, revision.history.count <= 64, revision.deviceName.count <= 128,
                  revision.created.timeIntervalSince1970.isFinite else { throw NiaSyncError.invalid }
            revisions.append(revision)
        }
        // Parent links replace only their own branch, never another device's head.
        let byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id,$0.session) })
        let parents = Set(revisions.compactMap { r -> String? in
            guard let parent = r.parent, byID[parent] == r.session else { return nil }
            return parent
        })
        let heads = revisions.filter { !parents.contains($0.id) }
        let counts = Dictionary(grouping: heads, by: \.session).mapValues(\.count)
        return try heads.map { r in
            let summary = try decoder.decode(NiaSyncSummary.self, from: get("blobs",r.metadata,max:16 * Self.chunkSize))
            guard summary.title.count <= 512, summary.cwd.count <= 4096 else { throw NiaSyncError.invalid }
            return NiaSyncItem(revision:r,summary:summary,hasConflict:(counts[r.session] ?? 0) > 1)
        }.sorted { $0.revision.created > $1.revision.created }
    }
    func restore(_ item: NiaSyncItem, importer: (URL, String) throws -> String) throws -> String {
        try locked {
            // Reload the authenticated revision instead of trusting stale UI data.
            let r = try decoder.decode(NiaSyncRevision.self, from: get("revisions",item.id,max:Self.chunkSize))
            guard r.id == item.id, r.transcript.count <= 2048, r.history.count <= 64 else { throw NiaSyncError.invalid }
            let stage = cache.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory:true)
            try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { try? fm.removeItem(at:stage) }
            try get("blobs",r.metadata,max:16 * Self.chunkSize).write(to:stage.appendingPathComponent("metadata.json"))
            func materialize(_ ids: [String], name: String) throws {
                let url = stage.appendingPathComponent(name)
                guard fm.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw NiaSyncError.invalid }
                let output = try FileHandle(forWritingTo:url); defer { try? output.close() }
                for id in ids { try output.write(contentsOf:get("blobs",id,max:Self.chunkSize)) }
                try output.synchronize()
            }
            try materialize(r.transcript,name:"transcript.bin")
            try materialize(r.history,name:"shell_history")
            let id = try importer(stage,r.id)
            var state = try state()
            if state.links[id] == nil { state.links[id] = NiaSyncLink(session:r.session,parent:r.id) }
            try save(state)
            return id
        }
    }
}
