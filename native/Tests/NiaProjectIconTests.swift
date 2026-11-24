// SPDX-License-Identifier: MPL-2.0
// swiftc native/Sources/NiaProjectIcon.swift native/Tests/NiaProjectIconTests.swift -o /tmp/nia-project-icon-tests
import AppKit
import ImageIO

private final class IconProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    private var active = 0
    private(set) var maximum = 0
    private(set) var ranOnMain = false
    let image: CGImage
    init(image: CGImage) { self.image = image }
    func search(_ path: String) -> CGImage? {
        lock.lock()
        calls[path, default: 0] += 1
        active += 1; maximum = max(maximum, active)
        ranOnMain = ranOnMain || Thread.isMainThread
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.08)
        lock.lock(); active -= 1; lock.unlock()
        return path == "/missing" ? nil : image
    }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls[path, default: 0] }
    var working: Bool { lock.lock(); defer { lock.unlock() }; return active > 0 }
}

@main
@MainActor
struct NiaProjectIconTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("nia-icon-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = context.makeImage()!
        let pngData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(pngData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        check(CGImageDestinationFinalize(destination), "Generate a real PNG fixture")
        let png = pngData as Data
        func write(_ relative: String, data: Data? = nil) throws -> URL {
            let url = base.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data ?? png).write(to: url)
            return url
        }
        func search(_ directory: URL, limits: NiaProjectIconSearch.Limits = .init()) async -> NiaProjectIconSearch.Match? {
            await Task.detached { NiaProjectIconSearch.find(in: directory.path, limits: limits) }.value
        }
        let project = base.appendingPathComponent("project")
        let nested = try write("project/src/app/favicon.png")
        check(await search(project)?.file == nested, "Discover icons exactly two levels below the project")
        let root = try write("project/favicon.png")
        let first = await search(project)
        check(first?.file == root, "Prefer the project root over nested icons")
        check(first?.image.width == 32 && first?.image.height == 32, "Decode a small thumbnail on the worker")
        try fm.removeItem(at: root)
        try fm.removeItem(at: nested)
        _ = try write("project/src/app/icons/favicon.png")
        check(await search(project) == nil, "Never descend a third level")
        _ = try write("project/node_modules/dependency/favicon.png")
        _ = try write("project/.hidden/favicon.png")
        _ = try write("project/dist/favicon.png")
        check(await search(project) == nil, "Skip dependency, hidden and build directories")
        let outside = try write("outside/favicon.png")
        try fm.createSymbolicLink(at: project.appendingPathComponent("linked"), withDestinationURL: outside.deletingLastPathComponent())
        try fm.createSymbolicLink(at: project.appendingPathComponent("favicon.png"), withDestinationURL: outside)
        check(await search(project) == nil, "Do not follow file or subdirectory symlinks")
        try fm.removeItem(at: project.appendingPathComponent("favicon.png"))
        _ = try write("favicon.png")
        check(await search(project) == nil, "Never search ancestors")
        let suffixed = try write("project/public/favicon-32x32.png")
        check(await search(project)?.file == suffixed, "Support conventional sized favicon names")
        let home = URL(fileURLWithPath: "/Users/example")
        for name in ["", "Documents", "Downloads", "Desktop", "Library", "Pictures", "Music", "Movies", "Applications", "Public"] {
            check(NiaProjectIconSearch.isGeneralDirectory(home.appendingPathComponent(name), home: home), "Skip general home folder \(name)")
        }
        check(!NiaProjectIconSearch.isGeneralDirectory(home.appendingPathComponent("Documents/project"), home: home), "Projects inside Documents are eligible")
        check(NiaProjectIconSearch.isGeneralDirectory(URL(fileURLWithPath: "/")), "Skip the filesystem root")

        _ = try write("invalid/favicon.png", data: Data("not an image".utf8))
        let valid = try write("invalid/public/favicon.png")
        check(await search(base.appendingPathComponent("invalid"))?.file == valid, "A corrupt root icon does not hide a valid nested icon")
        _ = try write("large/favicon.png", data: Data(repeating: 0, count: 1024 * 1024 + 1))
        check(await search(base.appendingPathComponent("large")) == nil, "Skip oversized files before allocating/decoding them")
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><path fill=\"#33aaff\" d=\"M0 0h32v32H0z\"/></svg>".utf8)
        let vector = try write("vector/favicon.svg", data: svg)
        let svgMatch = await search(vector.deletingLastPathComponent())
        check(svgMatch?.file == vector && svgMatch?.image.width == 32, "Rasterize a self-contained SVG off the UI thread")
        _ = try write("external/favicon.svg", data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><use href=\"https://example.invalid/icon.svg#x\"/></svg>".utf8))
        check(await search(base.appendingPathComponent("external")) == nil, "SVG references cannot fetch external content")
        _ = try write("stylesheet/favicon.svg", data: Data("<?xml-stylesheet href=\"https://example.invalid/style.css\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8))
        check(await search(base.appendingPathComponent("stylesheet")) == nil, "SVG processing instructions cannot load stylesheets")
        _ = try write("entity/favicon.svg", data: Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///tmp/example'>]><svg xmlns=\"http://www.w3.org/2000/svg\">&x;</svg>".utf8))
        check(await search(base.appendingPathComponent("entity")) == nil, "Reject SVG external entities")
        var ico = Data([0, 0, 1, 0, 1, 0, 64, 64, 0, 0, 1, 0, 32, 0])
        for value in [UInt32(png.count), UInt32(22)] { var little = value.littleEndian; withUnsafeBytes(of: &little) { ico.append(contentsOf: $0) } }
        let icoURL = try write("windows/favicon.ico", data: ico + png)
        check(await search(icoURL.deletingLastPathComponent())?.file == icoURL, "Decode real ICO favicon data")

        check(await search(project, limits: .init(entries: 0)) == nil, "Honor the entry budget")
        check(await search(project, limits: .init(directories: 1)) == nil, "Honor the directory budget")
        check(await search(project, limits: .init(seconds: 0)) == nil, "Honor an expired search deadline")
        check(await search(vector.deletingLastPathComponent(), limits: .init(decodes: 0)) == nil, "Honor the decode budget")

        let probe = IconProbe(image: image)
        let loader = NiaProjectIconLoader(search: { path in probe.search(path) })
        async let one = loader.image(for: "/project")
        async let two = loader.image(for: "/project")
        let pair = await (one, two)
        check(pair.0 != nil && pair.1 != nil && probe.count("/project") == 1, "Coalesce concurrent requests for the same folder")
        _ = await loader.image(for: "/project")
        check(probe.count("/project") == 1, "Reuse positive cache entries")
        _ = await loader.image(for: "/missing")
        _ = await loader.image(for: "/missing")
        check(probe.count("/missing") == 1, "Cache absent icons as well")
        let jobs = (0..<6).map { index in Task { await loader.image(for: "/parallel-\(index)") } }
        try await Task.sleep(for: .milliseconds(20))
        check(probe.working, "The main actor remains responsive during blocking filesystem work")
        for job in jobs { _ = await job.value }
        check(probe.maximum == 2 && !probe.ranOnMain, "At most two searches run, always outside the main thread")
        let cancelled = Task { await loader.image(for: "/cancelled") }
        cancelled.cancel()
        check(await cancelled.value == nil && probe.count("/cancelled") == 0, "Skip requests cancelled before lookup")
        print("Nia project icons: \(checks) checks passed")
    }
}
