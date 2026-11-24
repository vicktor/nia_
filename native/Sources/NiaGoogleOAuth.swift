// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Security
import Network

enum NiaDriveError: String, Error, LocalizedError {
    case configuration = "Esta compilación no incluye la configuración de Google Drive."
    case reconnect = "Vuelve a conectar Google Drive para autorizar el acceso."
    case cancelled = "Se canceló la conexión con Google."
    case timeout = "Se agotó el tiempo para conectar con Google. Inténtalo de nuevo."
    case response = "Google Drive devolvió una respuesta no válida."
    case permission = "Google Drive no permite esta operación. Comprueba la cuenta, los permisos y que la API de Drive esté habilitada."
    case rateLimit = "Google Drive ha limitado las solicitudes. Se reintentará en el siguiente ciclo."
    case conflict = "Hay archivos incompatibles en esta carpeta de Drive. No se han sobrescrito."
    var errorDescription: String? { rawValue }
}

struct NiaGoogleClient: Codable, Sendable {
    let clientID: String
    let clientSecret: String?
    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource:"GoogleOAuthClient",withExtension:"json") else { throw NiaDriveError.configuration }
        return try imported(Data(contentsOf:url))
    }
    static func imported(_ data: Data) throws -> Self {
        guard data.count <= 65536,
              let object = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let installed = object["installed"] as? [String:Any],
              let id = installed["client_id"] as? String, id.hasSuffix(".apps.googleusercontent.com"),
              id.count <= 512, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { throw NiaDriveError.configuration }
        let secret = installed["client_secret"] as? String
        guard secret == nil || (!secret!.isEmpty && secret!.count <= 1024) else { throw NiaDriveError.configuration }
        // Endpoints from imported JSON are intentionally ignored.
        return Self(clientID:id,clientSecret:secret)
    }
}
struct NiaGoogleTokens: Codable, Sendable {
    let access: String
    let refresh: String
    let expires: Date
    let clientID: String
}

enum NiaGoogleKeychain {
    static func save<T: Encodable>(_ value: T, account: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.nia.terminal.google-drive",kSecAttrAccount as String:account]
        let values: [String:Any] = [kSecValueData as String:try JSONEncoder().encode(value),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary,values as CFDictionary)
        if status == errSecItemNotFound {
            let result = SecItemAdd(query.merging(values) { _,new in new } as CFDictionary,nil)
            guard result == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(result)) }
        } else if status != errSecSuccess { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
    }
    static func read<T: Decodable>(_ type: T.Type, account: String) throws -> T {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.nia.terminal.google-drive",kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecItemNotFound { throw NiaDriveError.reconnect }
            throw NSError(domain:NSOSStatusErrorDomain,code:Int(status))
        }
        return try JSONDecoder().decode(type,from:data)
    }
    static func remove(account: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.nia.terminal.google-drive",kSecAttrAccount as String:account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
    }
}

// Never forward Authorization (or token exchange bodies) through HTTP redirects.
private final class NiaGoogleNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class NiaGoogleHTTP: @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration:configuration,delegate:NiaGoogleNoRedirects(),delegateQueue:nil)
    }
    deinit { session.invalidateAndCancel() }
    func data(_ request: URLRequest, limit: Int = 1024 * 1024) async throws -> (Data, Int) {
        let (data,response) = try await response(request,limit:limit)
        return (data,response.statusCode)
    }
    func response(_ request: URLRequest, limit: Int = 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["www.googleapis.com","oauth2.googleapis.com"].contains(url.host ?? "") else { throw NiaDriveError.response }
        let (bytes,response) = try await session.bytes(for:request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= limit else { throw NiaDriveError.response }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw NiaDriveError.response }
            data.append(byte)
        }
        return (data,response)
    }
    static func form(_ values: [String:String]) -> Data {
        let safe = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let text = values.sorted(by:{$0.key < $1.key}).map { key,value in
            "\(key.addingPercentEncoding(withAllowedCharacters:safe)! )=\(value.addingPercentEncoding(withAllowedCharacters:safe)!)"
        }.joined(separator:"&")
        return Data(text.utf8)
    }
}

struct NiaGooglePKCE: Sendable {
    let verifier: String
    let state: String
    init() {
        verifier = Self.random()
        state = Self.random()
    }
    private static func random() -> String { SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) }.base64URL }
    var challenge: String { Data(SHA256.hash(data:Data(verifier.utf8))).base64URL }
    func authorizationURL(clientID: String, redirect: URL) throws -> URL {
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil, redirect.path == "/oauth/callback" else { throw NiaDriveError.response }
        var components = URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = ["client_id":clientID,"redirect_uri":redirect.absoluteString,"response_type":"code",
            "scope":"https://www.googleapis.com/auth/drive.file","access_type":"offline","prompt":"consent select_account",
            "state":state,"code_challenge":challenge,"code_challenge_method":"S256"].map { URLQueryItem(name:$0.key,value:$0.value) }
        guard let url = components.url else { throw NiaDriveError.response }; return url
    }
    func callback(_ target: String) throws -> String? {
        guard target.count <= 16384, target.hasPrefix("/oauth/callback?"),
              let components = URLComponents(string:"http://127.0.0.1" + target), components.path == "/oauth/callback",
              let items = components.queryItems else { return nil }
        func single(_ key: String) -> String? { let matches = items.filter { $0.name == key }; return matches.count == 1 ? matches[0].value : nil }
        guard single("state") == state else { return nil }
        if single("error") != nil { throw NiaDriveError.cancelled }
        guard let code = single("code"), !code.isEmpty, code.count <= 8192 else { throw NiaDriveError.response }
        return code
    }
}
private extension Data { var base64URL: String { base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") } }

/// Receives OAuth only on IPv4 loopback, with a random port and CSRF state.
/// The system browser owns Google's login UI; no embedded sign-in or credentials.
final class NiaGoogleLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label:"dev.nia.google.oauth")
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var completion: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private let pkce: NiaGooglePKCE
    private var connections: [NWConnection] = []
    init(pkce: NiaGooglePKCE) { self.pkce = pkce }
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let result = self.result {
                        if case .failure(let error) = result { continuation.resume(throwing:error) }
                        else { continuation.resume(throwing:NiaDriveError.response) }
                        return
                    }
                    self.ready = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
                        let listener = try NWListener(using:parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                guard let port = listener.port else { self.finish(.failure(NiaDriveError.response)); return }
                                self.ready?.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)/oauth/callback")!); self.ready = nil
                            case .failed(let error): self.finish(.failure(error))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { connection in
                            guard self.connections.count < 16 else { connection.cancel(); return }
                            self.connections.append(connection)
                            connection.start(queue:self.queue)
                            self.receive(connection,data:Data())
                            self.queue.asyncAfter(deadline:.now() + 10) {
                                connection.cancel(); self.connections.removeAll { $0 === connection }
                            }
                        }
                        listener.start(queue:self.queue)
                        self.queue.asyncAfter(deadline:.now() + 180) { [weak self] in self?.finish(.failure(NiaDriveError.timeout)) }
                    } catch { self.finish(.failure(error)) }
                }
            }
        } onCancel: { self.cancel() }
    }
    func code() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with:result) }
                    else { self.completion = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { queue.async { self.finish(.failure(NiaDriveError.cancelled)) } }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:4096) { chunk,_,done,error in
            var all = data; if let chunk { all.append(chunk) }
            guard all.count <= 16384 else { connection.cancel(); self.connections.removeAll { $0 === connection }; return }
            if let text = String(data:all,encoding:.utf8), text.contains("\r\n\r\n") {
                let parts = text.components(separatedBy:"\r\n")[0].split(separator:" ")
                var outcome: Result<String,Error>?
                if parts.count == 3, parts[0] == "GET" {
                    do { if let code = try self.pkce.callback(String(parts[1])) { outcome = .success(code) } }
                    catch { outcome = .failure(error) }
                }
                let valid = outcome != nil
                let body = valid ? "nia_: authorization received. You can return to the app." : "Invalid OAuth callback."
                let reply = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content:Data(reply.utf8),completion:.contentProcessed { _ in
                    connection.cancel(); self.connections.removeAll { $0 === connection }
                    if let outcome { self.finish(outcome) }
                })
            } else if done || error != nil { connection.cancel(); self.connections.removeAll { $0 === connection } }
            else { self.receive(connection,data:all) }
        }
    }
    private func finish(_ value: Result<String,Error>) {
        guard result == nil else { return }; result = value
        if case .failure(let error) = value { ready?.resume(throwing:error) }
        else { ready?.resume(throwing:NiaDriveError.response) }
        ready = nil
        completion?.resume(with:value); completion = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
    }
}

actor NiaGoogleAuthorization {
    static let shared = NiaGoogleAuthorization()
    let http: NiaGoogleHTTP
    private var refreshTask: Task<NiaGoogleTokens,Error>?
    private var generation = UUID()
    init(http: NiaGoogleHTTP = NiaGoogleHTTP()) { self.http = http }
    func token(forceRefresh: Bool = false) async throws -> String {
        let client = try NiaGoogleClient.bundled()
        let tokens = try NiaGoogleKeychain.read(NiaGoogleTokens.self,account:"tokens")
        guard tokens.clientID == client.clientID else { throw NiaDriveError.reconnect }
        if !forceRefresh && tokens.expires.timeIntervalSinceNow > 60 { return tokens.access }
        if let task = refreshTask { return try await task.value.access }
        let expectedGeneration = generation
        let task = Task {
            let updated = try await self.exchange(client:client,values:["grant_type":"refresh_token","refresh_token":tokens.refresh],previousRefresh:tokens.refresh)
            try Task.checkCancellation()
            guard self.generation == expectedGeneration else { throw NiaDriveError.reconnect }
            try NiaGoogleKeychain.save(updated,account:"tokens")
            return updated
        }
        refreshTask = task; defer { if generation == expectedGeneration { refreshTask = nil } }
        let updated = try await task.value
        return updated.access
    }
    func authorize(client: NiaGoogleClient, code: String, verifier: String, redirect: URL) async throws {
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        let expectedGeneration = generation
        let tokens = try await exchange(client:client,values:["grant_type":"authorization_code","code":code,"code_verifier":verifier,"redirect_uri":redirect.absoluteString],previousRefresh:nil)
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw NiaDriveError.cancelled }
        try NiaGoogleKeychain.save(tokens,account:"tokens")
    }
    func disconnect() throws {
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        try NiaGoogleKeychain.remove(account:"tokens")
    }
    func exchange(client: NiaGoogleClient, values: [String:String], previousRefresh: String?) async throws -> NiaGoogleTokens {
        var request = URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        var identity = ["client_id":client.clientID]
        if let secret = client.clientSecret { identity["client_secret"] = secret }
        request.httpBody = NiaGoogleHTTP.form(values.merging(identity) { _,v in v })
        let (data,status) = try await http.data(request,limit:65536)
        guard status == 200 else { if status == 400 || status == 401 { throw NiaDriveError.reconnect }; throw NiaDriveError.response }
        struct Response: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let token_type: String; let scope: String? }
        let response = try JSONDecoder().decode(Response.self,from:data)
        guard response.token_type.lowercased() == "bearer", !response.access_token.isEmpty, response.access_token.count < 16384,
              let refresh = response.refresh_token ?? previousRefresh, !refresh.isEmpty, refresh.count < 16384,
              response.expires_in.isFinite, response.expires_in > 0, response.expires_in <= 86400,
              response.scope == nil || response.scope!.split(separator:" ").contains("https://www.googleapis.com/auth/drive.file") else { throw NiaDriveError.reconnect }
        return NiaGoogleTokens(access:response.access_token,refresh:refresh,expires:Date().addingTimeInterval(response.expires_in),clientID:client.clientID)
    }
}
