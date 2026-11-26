// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

// All Google requests are intercepted; only the OAuth loopback test uses a
// real socket, bound to 127.0.0.1. No account, Keychain entry or live file is used.
private final class GoogleFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (URLRequest) throws -> (Int,[String:String],Data) = { _ in fatalError("unconfigured fixture") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code,headers,data) = try Self.handler(request)
            let response = HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:headers)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
private func body(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data(), bytes = [UInt8](repeating:0,count:8192)
    while true {
        let count = stream.read(&bytes,maxLength:bytes.count)
        if count <= 0 { break }; result.append(contentsOf:bytes.prefix(count))
    }
    return result
}
private actor RefreshRecorder {
    var flags: [Bool] = []
    func record(_ flag: Bool) { flags.append(flag) }
}
private final class FakeDrive {
    var records: [String:[String:Any]] = [:]
    var payloads: [String:Data] = [:]
    var pending: [String:[String:Any]] = [:]
    var sequence = 0, uploads = 0, downloads = 0
    var loseNextUpload = false, corruptDownload: String?, hostileLocation = false
    var revisionMIME: String?
    var uploadOrder: [String] = []
    func reply(_ object: Any, code: Int = 200) throws -> (Int,[String:String],Data) {
        (code,[:],try JSONSerialization.data(withJSONObject:object))
    }
    func respond(_ request: URLRequest) throws -> (Int,[String:String],Data) {
        precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-token")
        let url = request.url!, path = url.path, method = request.httpMethod ?? "GET"
        let q = Dictionary(uniqueKeysWithValues:(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).map { ($0.name,$0.value ?? "") })
        if path.hasSuffix("/generateIds") { sequence += 1; return try reply(["ids":["file_\(sequence)"]]) }
        if path == "/upload/drive/v3/files" {
            if method == "POST" {
                let metadata = try JSONSerialization.jsonObject(with:body(request)) as! [String:Any]
                let id = metadata["id"] as! String
                if records[id] != nil { return try reply([:],code:409) }
                pending[id] = metadata
                return (200,["Location":hostileLocation ? "https://untrusted.invalid/steal" : "https://www.googleapis.com/upload/drive/v3/files?upload_id=\(id)"],Data())
            }
            let id = q["upload_id"]!, data = body(request)
            var metadata = pending.removeValue(forKey:id)!
            metadata["size"] = String(data.count); metadata["md5Checksum"] = NiaGoogleDriveAPI.checksum(data)
            // Real Drive reports the JSON space header as application/json,
            // even when a previous client requested application/octet-stream.
            if metadata["name"] as? String == "space.json" { metadata["mimeType"] = "application/json" }
            if (metadata["name"] as? String)?.hasPrefix("revision-") == true, let revisionMIME {
                metadata["mimeType"] = revisionMIME
            }
            records[id] = metadata; payloads[id] = data; uploads += 1
            uploadOrder.append(metadata["name"] as! String)
            if loseNextUpload { loseNextUpload = false; throw URLError(.networkConnectionLost) }
            return try reply(metadata)
        }
        if path == "/drive/v3/files" {
            if method == "POST" {
                let metadata = try JSONSerialization.jsonObject(with:body(request)) as! [String:Any]
                let id = metadata["id"] as! String
                if records[id] != nil { return try reply([:],code:409) }
                records[id] = metadata; return try reply(metadata)
            }
            let query = q["q"] ?? ""
            let files = records.values.filter {
                if query.contains(" in parents") {
                    return ($0["parents"] as? [String] ?? []).contains { query.contains("'\($0)' in parents") }
                }
                return $0["mimeType"] as? String == NiaDriveFile.folderMIME
            }
            return try reply(["files":Array(files)])
        }
        let id = url.lastPathComponent
        guard let metadata = records[id] else { return try reply([:],code:404) }
        if q["alt"] == "media" {
            downloads += 1; var data = payloads[id]!
            if corruptDownload == id { data[0] ^= 1 }
            return (200,[:],data)
        }
        return try reply(metadata)
    }
}
@main struct NiaGoogleDriveTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value,message); checks += 1 }
    static func rejected(_ message: String, _ body: () async throws -> Void) async {
        do { try await body(); fatalError(message) } catch { checks += 1 }
    }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleFixtureProtocol.self]
        let http = NiaGoogleHTTP(configuration:configuration)
        let client = try NiaGoogleClient.imported(Data(#"{"installed":{"client_id":"fixture.apps.googleusercontent.com","client_secret":"fixture-only","token_uri":"https://untrusted.invalid"}}"#.utf8))
        check(client.clientID == "fixture.apps.googleusercontent.com","desktop client accepted")
        await rejected("web clients rejected") { _ = try NiaGoogleClient.imported(Data(#"{"web":{"client_id":"fixture.apps.googleusercontent.com"}}"#.utf8)) }
        let pkce = NiaGooglePKCE()
        let redirect = URL(string:"http://127.0.0.1:45678/oauth/callback")!
        let auth = try pkce.authorizationURL(clientID:client.clientID,redirect:redirect)
        let values = Dictionary(uniqueKeysWithValues:URLComponents(url:auth,resolvingAgainstBaseURL:false)!.queryItems!.map { ($0.name,$0.value!) })
        check(auth.host == "accounts.google.com" && values["code_challenge_method"] == "S256","external Google endpoint with PKCE")
        check(pkce.verifier.count == 43 && pkce.challenge != pkce.verifier && pkce.state != pkce.verifier,"independent random verifier/state")
        check(values["scope"] == "https://www.googleapis.com/auth/drive.file","limited file scope only")
        check(try pkce.callback("/oauth/callback?state=wrong&code=bad") == nil,"wrong state ignored")
        check(try pkce.callback("/oauth/callback?state=\(pkce.state)&state=\(pkce.state)&code=bad") == nil,"duplicate state ignored")
        check(try pkce.callback("/oauth/callback?state=\(pkce.state)&code=a%2Bb") == "a+b","code decoded exactly")
        await rejected("user denial handled") { _ = try pkce.callback("/oauth/callback?state=\(pkce.state)&error=access_denied") }
        await rejected("duplicate code rejected") { _ = try pkce.callback("/oauth/callback?state=\(pkce.state)&code=a&code=b") }
        await rejected("non-loopback redirect rejected") { _ = try pkce.authorizationURL(clientID:client.clientID,redirect:URL(string:"http://example.com:1234/oauth/callback")!) }
        check(String(decoding:NiaGoogleHTTP.form(["value":"a+b& c"]),as:UTF8.self) == "value=a%2Bb%26%20c","form encoding protects token characters")
        let receiver = NiaGoogleLoopback(pkce:pkce)
        let local = try await receiver.start()
        let (_,invalid) = try await URLSession.shared.data(from:URL(string:local.absoluteString + "?state=wrong&code=bad")!)
        check((invalid as? HTTPURLResponse)?.statusCode == 400,"loopback refuses wrong state without ending login")
        let (_,valid) = try await URLSession.shared.data(from:URL(string:local.absoluteString + "?state=\(pkce.state)&code=fixture-code")!)
        check((valid as? HTTPURLResponse)?.statusCode == 200,"loopback receives valid callback")
        check(try await receiver.code() == "fixture-code","callback delivered even before waiter")
        let cancelled = NiaGoogleLoopback(pkce:pkce); cancelled.cancel()
        await rejected("cancel before listener start completes") { _ = try await cancelled.start() }
        let cancelledWait = NiaGoogleLoopback(pkce:pkce); _ = try await cancelledWait.start(); cancelledWait.cancel()
        await rejected("cancel waiting for callback completes") { _ = try await cancelledWait.code() }
        GoogleFixtureProtocol.handler = { request in
            check(request.url!.host == "oauth2.googleapis.com","JSON endpoint ignored")
            check(String(decoding:body(request),as:UTF8.self).contains("code_verifier=fixture"),"PKCE sent in token exchange")
            return (200,[:],Data(#"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/drive.file"}"#.utf8))
        }
        let authorization = NiaGoogleAuthorization(http:http)
        let tokens = try await authorization.exchange(client:client,values:["code_verifier":"fixture"],previousRefresh:nil)
        check(tokens.refresh == "fixture-refresh" && tokens.expires > Date(),"token exchange decoded without writing Keychain")
        GoogleFixtureProtocol.handler = { _ in (200,[:],Data(#"{"access_token":"fixture-access","expires_in":3600,"token_type":"Bearer"}"#.utf8)) }
        check(try await authorization.exchange(client:client,values:[:],previousRefresh:"existing").refresh == "existing","refresh responses may omit refresh token")
        await rejected("first authorization needs refresh token") { _ = try await authorization.exchange(client:client,values:[:],previousRefresh:nil) }
        let recorder = RefreshRecorder()
        var calls = 0
        let api = NiaGoogleDriveAPI(http:http,token:{ force in await recorder.record(force); return "fixture-token" })
        GoogleFixtureProtocol.handler = { _ in calls += 1; return (calls == 1 ? 401 : 200,[:],Data(#"{"ids":["generated"]}"#.utf8)) }
        let generated = try await api.generateID()
        check(await recorder.flags == [false,true] && generated == "generated","401 refreshes exactly once")
        GoogleFixtureProtocol.handler = { _ in (401,[:],Data()) }
        await rejected("repeated 401 terminates") { _ = try await api.generateID() }
        GoogleFixtureProtocol.handler = { _ in (200,[:],Data(repeating:1,count:9)) }
        await rejected("stream enforces byte limit") { _ = try await http.data(URLRequest(url:URL(string:"https://www.googleapis.com/test")!),limit:8) }
        GoogleFixtureProtocol.handler = { _ in fatalError("untrusted request must never reach transport") }
        await rejected("bearer cannot reach untrusted host") { _ = try await http.data(URLRequest(url:URL(string:"https://untrusted.invalid")!)) }
        let fake = FakeDrive()
        GoogleFixtureProtocol.handler = fake.respond
        let folder = try await api.createSpace(id:"space_id",name:"Fixture space")
        _ = try await api.createSpace(id:folder.id,name:folder.name)
        check(fake.records.count == 1,"folder creation retry is idempotent")
        check(try await api.spaces().count == 1,"created spaces listed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nia-drive-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let mirrorA = root.appendingPathComponent("a"), mirrorB = root.appendingPathComponent("b")
        let cacheA = root.appendingPathComponent("cache-a"), cacheB = root.appendingPathComponent("cache-b")
        let key = NiaSyncEngine.newKey()
        let a = try NiaGoogleDriveTransport(api:api,folderID:folder.id,mirror:mirrorA)
        let b = try NiaGoogleDriveTransport(api:api,folderID:folder.id,mirror:mirrorB)
        try NiaSyncEngine.create(folder:mirrorA,key:key)
        // Match the app: connect creates only the header; the next Sync first
        // pulls that same folder, then exports the user's selected sessions.
        try await a.push(key:key,cache:cacheA)
        let headerID = fake.records.first { $0.value["name"] as? String == "space.json" }!.key
        check(fake.records[headerID]?["mimeType"] as? String == "application/json","Drive classifies the header as JSON")
        try await a.pull(key:key,cache:cacheA)
        check(fake.downloads == 1,"first sync accepts the header created during connection")
        let engineA = try NiaSyncEngine(folder:mirrorA,key:key,cache:cacheA)
        let transcript = root.appendingPathComponent("transcript")
        let log = Data("\u{1b}[31mPRIVATE-FIXTURE\u{1b}[0m\r\n".utf8); try log.write(to:transcript)
        let snapshot = NiaSyncSnapshot(metadata:Data(#"{"title":"PRIVATE-FIXTURE","cwd":"/tmp/fixture","remote_host":null}"#.utf8),transcript:NiaSyncFile(path:transcript.path,length:UInt64(log.count)),history:nil)
        let first = try engineA.synchronize(selected:["local-a"],deviceName:"Fixture Mac A") { _ in snapshot }
        // A real encrypted revision was classified as audio by Drive. Upload
        // succeeds, then the next inventory used to block both Macs entirely.
        fake.revisionMIME = "audio/mpeg"
        fake.loseNextUpload = true
        await rejected("lost upload reply reported") { try await a.locked { try await a.push(key:key,cache:cacheA) } }
        try await a.locked { try await a.push(key:key,cache:cacheA) }
        check(fake.records.values.filter { $0["name"] as? String == "space.json" }.count == 1,"retry after lost reply never duplicates header")
        check(Set(fake.records.values.compactMap { $0["name"] as? String }).count == fake.records.count,"retry after lost block reply never duplicates a file")
        check(fake.uploadOrder.last!.hasPrefix("revision-"),"checkpoint uploaded after blocks")
        check(fake.payloads.values.allSatisfy { $0.range(of:Data("PRIVATE-FIXTURE".utf8)) == nil },"no plaintext reaches Drive")
        do { try await a.pull(key:key,cache:cacheA) }
        catch { fatalError("Sync after Drive classifies ciphertext as audio must succeed: \(error.localizedDescription)") }
        check(true,"uploading Mac can sync again after Drive classifies a revision as audio")
        let wrong = try NiaGoogleDriveTransport(api:api,folderID:folder.id,mirror:root.appendingPathComponent("wrong"))
        await rejected("wrong key rejected before writing mirror") { try await wrong.pull(key:NiaSyncEngine.newKey(),cache:cacheB) }
        check(!FileManager.default.fileExists(atPath:wrong.mirror.appendingPathComponent("space.json").path),"wrong key leaves no header")
        try await b.pull(key:key,cache:cacheB)
        let engineB = try NiaSyncEngine(folder:mirrorB,key:key,cache:cacheB)
        let received = try engineB.synchronize(selected:[],deviceName:"Fixture Mac B") { _ in fatalError() }
        check(received.count == 1 && received[0].id == first[0].id,"independent mirror receives checkpoint")
        _ = try engineB.restore(received[0]) { stage,_ in
            check(try Data(contentsOf:stage.appendingPathComponent("transcript.bin")) == log,"Drive roundtrip preserves exact ANSI")
            return "local-b"
        }
        let previousUploads = fake.uploads, previousDownloads = fake.downloads
        try await a.push(key:key,cache:cacheA); try await b.pull(key:key,cache:cacheB)
        check(fake.uploads == previousUploads,"unchanged mirror uploads nothing")
        check(fake.downloads == previousDownloads + 2,"unchanged pulls download only space headers")
        fake.records[headerID]!["mimeType"] = "application/octet-stream"
        try await b.pull(key:key,cache:cacheB)
        check(true,"older binary MIME space headers remain readable")
        fake.records[headerID]!["mimeType"] = NiaDriveFile.folderMIME
        await rejected("a folder named space.json is not a sync header") { try await b.pull(key:key,cache:cacheB) }
        fake.records[headerID]!["mimeType"] = "application/json"
        try await a.locked { await rejected("transport serializes multiple instances") { try await a.locked {} } }
        check(NiaGoogleDriveTransport.localPath("blob-../../secret.bin") == nil && NiaGoogleDriveTransport.localPath("revision-../../secret.bin") == nil,"remote names cannot traverse paths")
        // Simultaneous continuations keep both branches across independent mirrors.
        _ = try engineA.synchronize(selected:["local-a"],deviceName:"Fixture Mac A") { _ in NiaSyncSnapshot(metadata:Data(#"{"title":"Branch A","cwd":"/tmp/fixture","remote_host":null}"#.utf8),transcript:nil,history:nil) }
        _ = try engineB.synchronize(selected:["local-b"],deviceName:"Fixture Mac B") { _ in NiaSyncSnapshot(metadata:Data(#"{"title":"Branch B","cwd":"/tmp/fixture","remote_host":null}"#.utf8),transcript:nil,history:nil) }
        try await a.push(key:key,cache:cacheA); try await b.push(key:key,cache:cacheB); try await b.pull(key:key,cache:cacheB)
        let branches = try engineB.synchronize(selected:[],deviceName:"Fixture Mac B") { _ in fatalError() }
        check(branches.count == 2 && branches.allSatisfy(\.hasConflict),"Drive preserves simultaneous branches")
        let blobID = fake.records.first { ($0.value["name"] as? String)?.hasPrefix("blob-") == true }!.key
        let uploadsBeforeClassification = fake.uploads
        for (index,mimeType) in ["audio/mpeg","image/png","application/pdf","text/plain","application/json"].enumerated() {
            fake.records[blobID]!["mimeType"] = mimeType
            let fresh = try NiaGoogleDriveTransport(api:api,folderID:folder.id,mirror:root.appendingPathComponent("classified-\(index)"))
            let cache = root.appendingPathComponent("cache-classified-\(index)")
            try await fresh.pull(key:key,cache:cache)
            let engine = try NiaSyncEngine(folder:fresh.mirror,key:key,cache:cache)
            let catalog = try engine.synchronize(selected:[],deviceName:"New Mac") { _ in fatalError() }
            check(catalog.count == 2,"a fresh Mac receives both branches despite inferred \(mimeType) metadata")
            try await fresh.push(key:key,cache:cache)
        }
        check(fake.uploads == uploadsBeforeClassification,"reading inferred MIME types does not rewrite cloud files")
        for mimeType in [NiaDriveFile.folderMIME,"application/vnd.google-apps.shortcut","application/vnd.google-apps.document"] {
            fake.records[blobID]!["mimeType"] = mimeType
            await rejected("Google-native objects are rejected even with binary size and checksum") { try await b.pull(key:key,cache:cacheB) }
        }
        fake.records[blobID]!["mimeType"] = "audio/mpeg"
        fake.corruptDownload = blobID
        let tampered = try NiaGoogleDriveTransport(api:api,folderID:folder.id,mirror:root.appendingPathComponent("tampered"))
        await rejected("corrupt download fails") { try await tampered.pull(key:key,cache:root.appendingPathComponent("cache-tampered")) }
        fake.corruptDownload = nil
        // A malicious replacement with a matching provider checksum still fails GCM.
        var poisoned = fake.payloads[blobID]!; poisoned[0] ^= 1
        fake.payloads[blobID] = poisoned; fake.records[blobID]!["md5Checksum"] = NiaGoogleDriveAPI.checksum(poisoned)
        await rejected("provider checksum cannot bypass authentication") { try await tampered.pull(key:key,cache:root.appendingPathComponent("cache-tampered")) }
        fake.hostileLocation = true
        await rejected("resumable upload cannot leak bearer to another host") { try await api.upload(id:"hostile",name:"fixture",parent:folder.id,data:Data()) }
        // Pagination must reject loops instead of hanging or silently truncating.
        GoogleFixtureProtocol.handler = { _ in (200,[:],Data(#"{"files":[],"nextPageToken":"loop"}"#.utf8)) }
        await rejected("pagination loop rejected") { _ = try await api.spaces() }
        GoogleFixtureProtocol.handler = { _ in (403,[:],Data(#"{"error":{"errors":[{"reason":"rateLimitExceeded"}]}}"#.utf8)) }
        do { _ = try await api.spaces(); fatalError("quota should fail") } catch NiaDriveError.rateLimit { checks += 1 }
        print("Google Drive: \(checks) checks passed (OAuth, loopback, encrypted two-device transport, retries, authentication, branches).")
    }
}
