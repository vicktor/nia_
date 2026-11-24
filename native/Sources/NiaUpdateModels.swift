// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

struct NiaVersion: Comparable, Sendable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard text.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        let base = text.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)
        let parts = base[0].split(separator: ".")
        let parsed = parts.compactMap { Int($0) }
        guard parsed.count == 3, parts.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }) else { return nil }
        numbers = parsed
        prerelease = base.count == 2 ? base[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard prerelease.allSatisfy({ !$0.isEmpty && ($0.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil || $0 == "0" || !$0.hasPrefix("0")) }) else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = a.allSatisfy(\.isNumber), bn = b.allSatisfy(\.isNumber)
            if an && bn { return a.count == b.count ? a < b : a.count < b.count }
            if an != bn { return an }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum NiaUpdateError: String, Error, LocalizedError {
    case repositoryAccess = "GitHub requiere acceso al repositorio. Activa GitHub CLI en Preferencias → Actualizaciones e inicia sesión con gh auth login."
    case response = "No se pudo consultar GitHub. Inténtalo de nuevo más tarde."
    case rateLimit = "GitHub ha limitado temporalmente las consultas. Inténtalo más tarde."
    case incompatible = "Hay una versión nueva, pero no tiene una descarga verificada para este Mac."
    case invalidDownload = "La descarga no coincide con la publicación de GitHub."
    case invalidBundle = "La aplicación descargada no supera la verificación."
    case permissions = "No se puede escribir en la carpeta de la aplicación. Descarga la versión desde GitHub para instalarla manualmente."
    case running = "Cierra las otras instancias de esta misma copia de nia_ antes de instalar."
    case changed = "La aplicación instalada ha cambiado. Vuelve a buscar actualizaciones."
    case install = "No se pudo instalar la actualización. Se ha conservado la versión anterior."
    case timeout = "nia_ no se cerró a tiempo. La actualización no se ha instalado."
    case history = "No se pudo guardar toda la salida pendiente. La actualización se ha cancelado."
    var errorDescription: String? { rawValue }
}

struct NiaRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        var id: Int64? = nil
        let name: String
        let browser_download_url: URL
        let size: Int64
        let digest: String?
        let state: String
    }
    let tag_name: String
    let html_url: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

struct NiaUpdateCandidate: Sendable {
    var usesGitHubCLI = false
    let release: NiaRelease
    let asset: NiaRelease.Asset
    let sha256: String
    var version: String { String(release.tag_name.drop(while: { $0 == "v" })) }

    static let repository = "https://github.com/vicktor/nia_"
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func select(_ releases: [NiaRelease], current: String, previews: Bool,
                       architecture: String = architecture) throws -> Self? {
        guard let currentVersion = NiaVersion(current) else { throw NiaUpdateError.changed }
        let newer = releases.filter {
            guard !$0.draft, let version = NiaVersion($0.tag_name) else { return false }
            return version > currentVersion && (previews || (!$0.prerelease && version.prerelease.isEmpty))
        }.sorted { NiaVersion($0.tag_name)! > NiaVersion($1.tag_name)! }
        guard let release = newer.first else { return nil }
        let filename = "nia_-\(release.tag_name)-macos-\(architecture).zip"
        guard release.html_url.absoluteString == "\(repository)/releases/tag/\(release.tag_name)",
              let asset = release.assets.first(where: { $0.name == filename && $0.state == "uploaded" }),
              asset.size > 0, asset.size <= 1024 * 1024 * 1024,
              asset.browser_download_url.absoluteString == "\(repository)/releases/download/\(release.tag_name)/\(filename)",
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.dropFirst(7).range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil
        else { throw NiaUpdateError.incompatible }
        return Self(release: release, asset: asset, sha256: String(digest.dropFirst(7)).lowercased())
    }
}

enum NiaFileDigest {
    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// No credentials, shared cookies or arbitrary redirect hosts for downloads.
final class NiaDownloadPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let hosts: Set<String> = ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "raw.githubusercontent.com"]
    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443) && hosts.contains(url.host ?? "")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allows) == true ? request : nil)
    }
}

struct NiaHTTP: Sendable {
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        self.session = session ?? URLSession(configuration: config, delegate: NiaDownloadPolicy(), delegateQueue: nil)
    }
    func request(_ url: URL) throws -> URLRequest {
        guard NiaDownloadPolicy.allows(url) else { throw NiaUpdateError.response }
        var request = URLRequest(url: url)
        request.setValue("nia-macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
    func validate(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, let url = http.url, NiaDownloadPolicy.allows(url) else { throw NiaUpdateError.response }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") { throw NiaUpdateError.rateLimit }
        if [401, 403, 404].contains(http.statusCode) { throw NiaUpdateError.repositoryAccess }
        guard http.statusCode == 200 else { throw NiaUpdateError.response }
        return http
    }
    func data(_ url: URL, limit: Int = 4 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request(url))
        let http = try validate(response)
        guard data.count <= limit else { throw NiaUpdateError.response }
        return (data, http)
    }
    func releases() async throws -> [NiaRelease] {
        var releases: [NiaRelease] = []
        for page in 1...20 {
            let (data, response) = try await data(URL(string: "https://api.github.com/repos/vicktor/nia_/releases?per_page=100&page=\(page)")!)
            releases += try JSONDecoder().decode([NiaRelease].self, from: data)
            if !(response.value(forHTTPHeaderField: "Link") ?? "").contains("rel=\"next\"") { return releases }
        }
        throw NiaUpdateError.response
    }
}
