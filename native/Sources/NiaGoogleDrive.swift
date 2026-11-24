// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

struct NiaDriveFile: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let md5Checksum: String?
    let parents: [String]?
    let appProperties: [String:String]?
    let trashed: Bool?
    static let folderMIME = "application/vnd.google-apps.folder"
}

final class NiaGoogleDriveAPI: Sendable {
    private let http: NiaGoogleHTTP
    private let token: @Sendable (Bool) async throws -> String
    static let fields = "id,name,mimeType,size,md5Checksum,parents,appProperties,trashed"
    init(http: NiaGoogleHTTP = NiaGoogleHTTP(), token: @escaping @Sendable (Bool) async throws -> String = { try await NiaGoogleAuthorization.shared.token(forceRefresh:$0) }) {
        self.http = http; self.token = token
    }
    static func validID(_ id: String) -> Bool { !id.isEmpty && id.count <= 200 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
    private func url(_ path: String, _ query: [String:String] = [:]) -> URL {
        var parts = URLComponents(string:"https://www.googleapis.com" + path)!
        parts.queryItems = query.map { URLQueryItem(name:$0.key,value:$0.value) }
        return parts.url!
    }
    private func call(_ original: URLRequest, limit: Int = 2 * 1024 * 1024, conflict: Bool = false) async throws -> (Data,HTTPURLResponse) {
        for retry in 0...1 {
            var request = original
            request.setValue("Bearer " + (try await token(retry == 1)),forHTTPHeaderField:"Authorization")
            let (data,response) = try await http.response(request,limit:limit)
            if response.statusCode == 401 && retry == 0 { continue }
            if (200...299).contains(response.statusCode) || (conflict && response.statusCode == 409) { return (data,response) }
            if response.statusCode == 401 { throw NiaDriveError.reconnect }
            if response.statusCode == 429 { throw NiaDriveError.rateLimit }
            if response.statusCode == 403 {
                struct Failure: Decodable { struct Detail: Decodable { struct Reason: Decodable { let reason:String }; let errors:[Reason]? }; let error:Detail }
                let reasons = (try? JSONDecoder().decode(Failure.self,from:data))?.error.errors?.map(\.reason) ?? []
                if reasons.contains(where: { ["rateLimitExceeded","userRateLimitExceeded"].contains($0) }) { throw NiaDriveError.rateLimit }
                throw NiaDriveError.permission
            }
            if response.statusCode == 404 { throw NiaDriveError.permission }
            throw NiaDriveError.response
        }
        throw NiaDriveError.reconnect
    }
    func files(query: String, limit: Int = 20000) async throws -> [NiaDriveFile] {
        struct Page: Decodable { let files:[NiaDriveFile]; let nextPageToken:String?; let incompleteSearch:Bool? }
        var files: [NiaDriveFile] = [], page: String?, seen = Set<String>(), seenIDs = Set<String>()
        repeat {
            var q = ["q":query,"spaces":"drive","pageSize":"1000","fields":"nextPageToken,incompleteSearch,files(\(Self.fields))"]
            if let page { q["pageToken"] = page }
            let (data,_) = try await call(URLRequest(url:url("/drive/v3/files",q)))
            let response = try JSONDecoder().decode(Page.self,from:data)
            guard response.incompleteSearch != true else { throw NiaDriveError.response }
            for file in response.files {
                guard Self.validID(file.id), seenIDs.insert(file.id).inserted else { throw NiaDriveError.response }
                files.append(file)
            }
            guard files.count <= limit else { throw NiaSyncError.limit }
            page = response.nextPageToken
            if let page { guard !page.isEmpty, page.count <= 8192, seen.count < 100, seen.insert(page).inserted else { throw NiaDriveError.response } }
        } while page != nil
        return files
    }
    func spaces() async throws -> [NiaDriveFile] {
        try await files(query:"trashed = false and mimeType = '\(NiaDriveFile.folderMIME)' and appProperties has { key='niaSync' and value='1' }",limit:500)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func children(_ parent: String) async throws -> [NiaDriveFile] {
        guard Self.validID(parent) else { throw NiaDriveError.response }
        return try await files(query:"trashed = false and '\(parent)' in parents")
    }
    func metadata(_ id: String) async throws -> NiaDriveFile {
        guard Self.validID(id) else { throw NiaDriveError.response }
        let (data,_) = try await call(URLRequest(url:url("/drive/v3/files/\(id)",["fields":Self.fields])))
        let file = try JSONDecoder().decode(NiaDriveFile.self,from:data)
        guard file.id == id, file.trashed != true else { throw NiaDriveError.response }
        return file
    }
    func generateID() async throws -> String {
        struct IDs: Decodable { let ids:[String] }
        let (data,_) = try await call(URLRequest(url:url("/drive/v3/files/generateIds",["count":"1","space":"drive","type":"files"])))
        let ids = try JSONDecoder().decode(IDs.self,from:data).ids
        guard ids.count == 1, Self.validID(ids[0]) else { throw NiaDriveError.response }
        return ids[0]
    }
    func createSpace(id: String, name: String) async throws -> NiaDriveFile {
        guard Self.validID(id), !name.isEmpty, name.count <= 128 else { throw NiaDriveError.response }
        var request = URLRequest(url:url("/drive/v3/files",["fields":Self.fields]))
        request.httpMethod = "POST"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["id":id,"name":name,"mimeType":NiaDriveFile.folderMIME,"appProperties":["niaSync":"1"]])
        let (_,_) = try await call(request,conflict:true)
        let file = try await metadata(id)
        guard file.mimeType == NiaDriveFile.folderMIME, file.appProperties?["niaSync"] == "1" else { throw NiaDriveError.conflict }
        return file
    }
    static func checksum(_ data: Data) -> String { Insecure.MD5.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    func download(_ file: NiaDriveFile, limit: Int) async throws -> Data {
        guard Self.validID(file.id), let size = file.size.flatMap(Int.init), size >= 0, size <= limit,
              let checksum = file.md5Checksum, checksum.count == 32 else { throw NiaDriveError.response }
        let (data,_) = try await call(URLRequest(url:url("/drive/v3/files/\(file.id)",["alt":"media"])),limit:limit)
        // MD5 is only the provider's transport checksum. Nia Sync separately
        // authenticates plaintext and ciphertext with AES-GCM and keyed SHA-256.
        guard data.count == size, Self.checksum(data) == checksum.lowercased() else { throw NiaDriveError.conflict }
        return data
    }
    func upload(id: String, name: String, parent: String, data: Data) async throws {
        guard Self.validID(id), Self.validID(parent), data.count <= 16 * 1024 * 1024 + 28 else { throw NiaDriveError.response }
        let mimeType = name == "space.json" ? "application/json" : "application/octet-stream"
        var request = URLRequest(url:url("/upload/drive/v3/files",["uploadType":"resumable","fields":Self.fields]))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8",forHTTPHeaderField:"Content-Type")
        request.setValue(mimeType,forHTTPHeaderField:"X-Upload-Content-Type")
        request.setValue(String(data.count),forHTTPHeaderField:"X-Upload-Content-Length")
        request.httpBody = try JSONSerialization.data(withJSONObject:["id":id,"name":name,"parents":[parent],"mimeType":mimeType])
        let (_,response) = try await call(request,conflict:true)
        if response.statusCode != 409 {
            guard let location = response.value(forHTTPHeaderField:"Location"), let destination = URL(string:location),
                  destination.scheme == "https", destination.host == "www.googleapis.com", destination.user == nil,
                  destination.password == nil, destination.port == nil || destination.port == 443,
                  destination.path == "/upload/drive/v3/files" else { throw NiaDriveError.response }
            var upload = URLRequest(url:destination); upload.httpMethod = "PUT"; upload.httpBody = data
            upload.setValue(mimeType,forHTTPHeaderField:"Content-Type")
            upload.setValue(String(data.count),forHTTPHeaderField:"Content-Length")
            let (_,_) = try await call(upload,conflict:true)
        }
        // Reusing a preallocated ID survives success followed by a lost reply.
        let stored = try await metadata(id)
        guard stored.name == name, stored.parents?.contains(parent) == true,
              stored.size.flatMap(Int.init) == data.count, stored.md5Checksum == Self.checksum(data) else { throw NiaDriveError.conflict }
    }
}

/// An encrypted local mirror lets both transports share the same checkpoint
/// engine. Drive file names are strictly mapped, never interpreted as paths.
final class NiaGoogleDriveTransport {
    let api: NiaGoogleDriveAPI
    let folderID: String
    let mirror: URL
    private let fm = FileManager.default
    init(api: NiaGoogleDriveAPI = NiaGoogleDriveAPI(), folderID: String, mirror: URL) throws {
        guard NiaGoogleDriveAPI.validID(folderID) else { throw NiaDriveError.response }
        self.api = api; self.folderID = folderID; self.mirror = mirror
        try fm.createDirectory(at:mirror,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    }
    func locked<T>(_ body: () async throws -> T) async throws -> T {
        let fd = Darwin.open(mirror.appendingPathComponent("transport.lock").path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw NiaSyncError.invalid }; defer { Darwin.close(fd) }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { throw NiaSyncError.busy }
        defer { flock(fd,LOCK_UN) }
        return try await body()
    }
    static func localPath(_ name: String) -> String? {
        if name == "space.json" { return name }
        guard name.hasSuffix(".bin") else { return nil }
        if name.hasPrefix("blob-") {
            let id = String(name.dropFirst(5).dropLast(4))
            guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return "blobs/\(id).bin"
        }
        if name.hasPrefix("revision-") {
            let id = String(name.dropFirst(9).dropLast(4))
            guard id.count == 36, UUID(uuidString:id) != nil else { return nil }
            return "revisions/\(id).bin"
        }
        return nil
    }
    static func limit(_ name: String) -> Int { name == "space.json" ? 4096 : (name.hasPrefix("revision-") ? 1024 * 1024 + 28 : 16 * 1024 * 1024 + 28) }
    private func destination(_ path: String) throws -> URL {
        let result = mirror.appendingPathComponent(path)
        for target in [mirror,result.deletingLastPathComponent(),result] {
            if (try? target.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw NiaSyncError.invalid }
        }
        return result
    }
    private func read(_ path: String, limit: Int) throws -> Data {
        let url = try destination(path)
        let fd = Darwin.open(url.path,O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw NiaSyncError.invalid }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true); defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else { throw NiaSyncError.limit }
        let data = try handle.read(upToCount:limit + 1) ?? Data()
        guard data.count <= limit else { throw NiaSyncError.limit }
        return data
    }
    private func write(_ data: Data, path: String) throws {
        let url = try destination(path)
        try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:url,options:.atomic)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private func inventory() async throws -> [String:NiaDriveFile] {
        let root = try await api.metadata(folderID)
        guard root.mimeType == NiaDriveFile.folderMIME, root.appProperties?["niaSync"] == "1" else { throw NiaDriveError.permission }
        let files = try await api.children(folderID)
        var byName: [String:NiaDriveFile] = [:]
        var bytes: UInt64 = 0
        for file in files.sorted(by:{$0.id < $1.id}) where Self.localPath(file.name) != nil {
            // The header is JSON. Drive can classify an existing header as
            // application/json even when an older client sent a binary type.
            // Content is still bounded, checksummed and authenticated on pull.
            let supportedType = file.mimeType == "application/octet-stream"
                || (file.name == "space.json" && file.mimeType == "application/json")
            guard supportedType, file.parents?.contains(folderID) == true,
                  let size = file.size.flatMap(UInt64.init), size <= Self.limit(file.name) else { throw NiaDriveError.conflict }
            bytes += size; guard bytes <= 4 * 1024 * 1024 * 1024 else { throw NiaSyncError.limit }
            if let previous = byName[file.name], file.name == "space.json", previous.md5Checksum != file.md5Checksum { throw NiaDriveError.conflict }
            // Two devices may encrypt an identical content-addressed block with
            // different nonces. A deterministic choice is authenticated below.
            if byName[file.name] == nil { byName[file.name] = file }
        }
        return byName
    }
    func pull(key: String, cache: URL) async throws {
        let files = try await inventory()
        guard let header = files["space.json"] else { throw NiaSyncError.pending }
        let headerData = try await api.download(header,limit:4096)
        let spaceID = try NiaSyncEngine.validateHeader(headerData,key:key)
        if fm.fileExists(atPath:mirror.appendingPathComponent("space.json").path) {
            let existing = try read("space.json",limit:4096)
            guard try NiaSyncEngine.validateHeader(existing,key:key) == spaceID else { throw NiaDriveError.conflict }
        } else { try write(headerData,path:"space.json") }
        let engine = try NiaSyncEngine(folder:mirror,key:key,cache:cache)
        var index: [String:String] = [:]
        if fm.fileExists(atPath:mirror.appendingPathComponent("download-index.json").path) {
            index = try JSONDecoder().decode([String:String].self,from:read("download-index.json",limit:8 * 1024 * 1024))
        }
        for name in files.keys.sorted() where name != "space.json" {
            let file = files[name]!, path = Self.localPath(name)!
            let stamp = file.id + "/" + (file.md5Checksum ?? "")
            if index[name] == stamp, fm.fileExists(atPath:mirror.appendingPathComponent(path).path) { continue }
            let data = try await api.download(file,limit:Self.limit(name))
            try engine.validateTransportFile(path,data:data)
            try write(data,path:path)
            index[name] = stamp
            try write(JSONEncoder().encode(index),path:"download-index.json")
        }
    }
    func push(key: String, cache: URL) async throws {
        let files = try await inventory()
        let engine = try NiaSyncEngine(folder:mirror,key:key,cache:cache)
        let header = try read("space.json",limit:4096)
        if let remote = files["space.json"] {
            let data = try await api.download(remote,limit:4096)
            guard try NiaSyncEngine.validateHeader(data,key:key) == engine.spaceID else { throw NiaDriveError.conflict }
        }
        var journal: [String:String] = [:]
        if fm.fileExists(atPath:mirror.appendingPathComponent("upload-journal.json").path) {
            journal = try JSONDecoder().decode([String:String].self,from:read("upload-journal.json",limit:8 * 1024 * 1024))
        }
        var names = ["space.json"]
        for (dir,prefix) in [("blobs","blob-"),("revisions","revision-")] {
            let folder = try destination(dir)
            if fm.fileExists(atPath:folder.path) {
                let children = try fm.contentsOfDirectory(atPath:folder.path)
                guard children.count <= 20000 else { throw NiaSyncError.limit }
                for name in children.sorted() where Self.localPath(prefix + name) != nil { names.append(prefix + name) }
            }
        }
        // Blobs precede revisions; the new checkpoint never advertises blocks
        // this client has not successfully sent to Google yet.
        for name in names {
            if files[name] != nil { continue }
            let path = Self.localPath(name)!
            let data = name == "space.json" ? header : try read(path,limit:Self.limit(name))
            if name != "space.json" { try engine.validateTransportFile(path,data:data) }
            let id: String
            if let previous = journal[name] { id = previous }
            else { id = try await api.generateID(); journal[name] = id; try write(JSONEncoder().encode(journal),path:"upload-journal.json") }
            try await api.upload(id:id,name:name,parent:folderID,data:data)
        }
    }
}
