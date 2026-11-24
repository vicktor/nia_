// SPDX-License-Identifier: MPL-2.0
import AppKit
import Darwin
import ImageIO
import SwiftUI

enum NiaProjectIconSearch {
    struct Limits {
        var entries = 1024
        var directories = 48
        var seconds: Double = 0.2
        var fileBytes = 1024 * 1024
        var decodes = 8
    }
    struct Match {
        let image: CGImage
        let file: URL
    }
    private static let extensions = ["png", "ico", "svg", "webp", "jpg", "jpeg", "gif", "icns", "tiff"]
    private static let skipped = Set(["node_modules", "vendor", "target", "build", "dist", "venv", "env",
                                      "pods", "carthage", "deriveddata", "__pycache__"])
    private static let preferredDirectories = ["public", "static", "assets", "src", "app", "images", "web"]

    static func isGeneralDirectory(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        let roots = Set(["/", "/Users", "/Users/Shared", "/Volumes", "/System", "/Library", "/Applications",
                         "/private", "/private/tmp", "/private/var", "/tmp", "/var", "/usr", "/bin", "/sbin", "/opt"])
        let userRoots = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Library", "Applications", "Sites"]
        return roots.contains(path) || path == homePath || userRoots.contains { path == homePath + "/" + $0 }
    }

    // Blocking filesystem and image work belongs exclusively on the loader's
    // bounded utility queue, never on the main actor or the terminal poll loop.
    static func find(in path: String, limits: Limits = Limits()) -> Match? {
        precondition(!Thread.isMainThread)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        func inTime() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
        let requested = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard !isGeneralDirectory(requested) else { return nil }
        let root = requested.resolvingSymlinksInPath().standardizedFileURL
        guard !isGeneralDirectory(root), inTime(), limits.directories > 0,
              !["app", "bundle", "framework"].contains(root.pathExtension.lowercased()) else { return nil }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return nil }
        var volume = statfs()
        guard fstatfs(rootFD, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else { close(rootFD); return nil }
        var queue: [(fd: Int32, url: URL, depth: Int)] = [(rootFD, root, 0)]
        var cursor = 0, entries = 0, decodes = 0
        defer { for entry in queue.dropFirst(cursor) { close(entry.fd) } }

        while cursor < queue.count && inTime() {
            let item = queue[cursor]
            cursor += 1
            guard let directory = fdopendir(item.fd) else { close(item.fd); continue }
            defer { closedir(directory) }

            func load(_ name: String) -> Match? {
                guard inTime(), decodes < limits.decodes else { return nil }
                var info = stat()
                guard fstatat(item.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG, info.st_flags & UInt32(SF_DATALESS) == 0,
                      info.st_size > 0, info.st_size <= limits.fileBytes else { return nil }
                let fd = openat(item.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { return nil }
                defer { close(fd) }
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_flags & UInt32(SF_DATALESS) == 0, info.st_size > 0,
                      info.st_size <= limits.fileBytes else { return nil }
                var data = Data(count: Int(info.st_size))
                let complete = data.withUnsafeMutableBytes { buffer -> Bool in
                    var offset = 0
                    while offset < buffer.count && inTime() {
                        let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), min(65536, buffer.count - offset))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { return false }
                        offset += count
                    }
                    return offset == buffer.count
                }
                guard complete, inTime() else { return nil }
                decodes += 1
                guard let image = decode(data, extension: (name as NSString).pathExtension.lowercased(), deadline: deadline) else { return nil }
                return Match(image: image, file: item.url.appendingPathComponent(name))
            }

            // Exact names are cheap to probe even in a directory containing
            // thousands of files. Do not enumerate that directory first.
            let exactNames = extensions.map { "favicon.\($0)" }
            for name in exactNames { if let match = load(name) { return match } }
            var candidates: [String] = [], children: [String] = []
            while entries < limits.entries && inTime(), let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard name != ".", name != ".." else { continue }
                entries += 1
                guard !name.hasPrefix(".") else { continue }
                let lower = name.lowercased()
                let stem = (lower as NSString).deletingPathExtension
                if (stem == "favicon" || stem.hasPrefix("favicon-") || stem.hasPrefix("favicon_")),
                   extensions.contains((lower as NSString).pathExtension), !exactNames.contains(name) {
                    candidates.append(name)
                }
                if item.depth < 2, !skipped.contains(lower),
                   !["app", "bundle", "framework"].contains((lower as NSString).pathExtension) {
                    var info = stat()
                    if fstatat(item.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                       info.st_mode & S_IFMT == S_IFDIR, info.st_flags & UInt32(SF_DATALESS) == 0 {
                        children.append(name)
                    }
                }
            }
            for name in candidates.sorted() { if let match = load(name) { return match } }
            children.sort {
                let a = preferredDirectories.firstIndex(of: $0.lowercased()) ?? preferredDirectories.count
                let b = preferredDirectories.firstIndex(of: $1.lowercased()) ?? preferredDirectories.count
                return a == b ? $0 < $1 : a < b
            }
            for name in children where queue.count < limits.directories && inTime() {
                let fd = openat(item.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 { queue.append((fd, item.url.appendingPathComponent(name), item.depth + 1)) }
            }
        }
        return nil
    }

    private static func decode(_ data: Data, extension ext: String, deadline: Double) -> CGImage? {
        if ext == "svg" {
            guard data.count <= 256 * 1024, NiaProjectSVGValidator.accepts(data, deadline: deadline),
                  let image = NSImage(data: data) else { return nil }
            var rect = NSRect(x: 0, y: 0, width: 32, height: 32)
            image.size = rect.size
            // Materialize the vector on the worker, not during SwiftUI drawing.
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

// Favicons are local, self-contained images. Do not let an SVG resolve files,
// external entities or URLs, and bound its complexity before AppKit renders it.
private final class NiaProjectSVGValidator: NSObject, XMLParserDelegate {
    private static let urls = try! NSRegularExpression(pattern: #"url\s*\(([^)]*)\)"#, options: .caseInsensitive)
    var valid = true
    var elements = 0
    let deadline: Double
    init(deadline: Double) { self.deadline = deadline }
    static func accepts(_ data: Data, deadline: Double) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?.lowercased(),
              !text.contains("<!doctype"), !text.contains("<!entity") else { return false }
        let parser = XMLParser(data: data), delegate = NiaProjectSVGValidator(deadline: deadline)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        return parser.parse() && delegate.valid && delegate.elements > 0
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        elements += 1
        let name = elementName.lowercased()
        var allowed = elements <= 2048 && ProcessInfo.processInfo.systemUptime < deadline
            && (elements != 1 || name == "svg") && !["image", "script", "foreignobject", "style"].contains(name)
        for (key, value) in attributes {
            if key.lowercased() == "xml:base" { allowed = false }
            if key.lowercased().hasSuffix("href") || key.lowercased() == "src" {
                allowed = allowed && value.hasPrefix("#")
            }
            if value.contains("\\") || value.lowercased().contains("@import") { allowed = false }
            for match in Self.urls.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                if let range = Range(match.range(at: 1), in: value) {
                    allowed = allowed && value[range].trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'")).hasPrefix("#")
                }
            }
        }
        if !allowed { valid = false; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        valid = false
        parser.abortParsing()
    }
}

@MainActor
final class NiaProjectIconLoader {
    static let shared = NiaProjectIconLoader()
    private struct Cached { let image: CGImage?; let expires: Date; var used: Date }
    private var cache: [String: Cached] = [:]
    private var pending: [String: Task<CGImage?, Never>] = [:]
    private let queue: OperationQueue
    private let search: @Sendable (String) -> CGImage?

    init(search: @escaping @Sendable (String) -> CGImage? = { NiaProjectIconSearch.find(in: $0)?.image }) {
        self.search = search
        queue = OperationQueue()
        queue.name = "dev.nia.terminal.project-icons"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
    }

    func image(for path: String) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        // Keep even path canonicalization off the UI thread.
        let key = path
        if var cached = cache[key], cached.expires > Date() {
            cached.used = Date(); cache[key] = cached
            return cached.image
        }
        if let task = pending[key] { return await task.value }
        // Bound outstanding work even if many windows open different projects.
        guard pending.count < 64 else { return nil }
        let queue = queue, search = search
        let task = Task<CGImage?, Never> {
            await withCheckedContinuation { continuation in
                queue.addOperation { continuation.resume(returning: search(key)) }
            }
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        cache[key] = Cached(image: image, expires: Date().addingTimeInterval(image == nil ? 60 : 300), used: Date())
        if cache.count > 128, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key { cache[oldest] = nil }
        return image
    }
}

struct NiaSessionIcon: View {
    let directory: String?
    let fallback: String
    let color: Color
    @State private var image: CGImage?
    @State private var loadedDirectory: String?

    var body: some View {
        Group {
            if let image, loadedDirectory == directory {
                Image(decorative: image, scale: 2).resizable().scaledToFit()
            } else {
                Image(systemName: fallback).foregroundStyle(color)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        .task(id: directory) {
            image = nil
            loadedDirectory = nil
            guard let directory else { return }
            let result = await NiaProjectIconLoader.shared.image(for: directory)
            guard !Task.isCancelled else { return }
            loadedDirectory = directory
            image = result
        }
    }
}
