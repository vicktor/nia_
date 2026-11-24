// SPDX-License-Identifier: MPL-2.0
import AppKit
import CoreText
import SwiftUI

// Enumerate at startup and after downloads, never on terminal redraws.
// Store the PostScript name, because families may contain proportional variants.
struct NiaFontChoice: Identifiable {
    let name: String
    let title: String
    var id: String { name }
}
enum NiaMonospaceFonts {
    static func installed() -> [NiaFontChoice] {
        // AppKit caches availableFonts and can omit newly registered process
        // fonts. Core Text supplies the live registry, including named instances.
        let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        return names.compactMap { name -> NiaFontChoice? in
            guard let font = NSFont(name: name, size: 13), font.isFixedPitch else { return nil }
            let coreFont = CTFontCreateWithName(name as CFString, 13, nil)
            let title: String
            if CTFontCopyVariationAxes(coreFont) != nil,
               let style = CTFontCopyName(coreFont, kCTFontStyleNameKey) as String? {
                // AppKit's displayName describes the variable file's default
                // weight, even when the PostScript name selects another one.
                title = "\(CTFontCopyFamilyName(coreFont)) \(style)"
            } else { title = font.displayName ?? name }
            return NiaFontChoice(name: name, title: title)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}


struct NiaDownloadableFont: Decodable, Identifiable, Sendable {
    struct File: Decodable, Sendable {
        let name: String
        let url: URL
        let size: Int
        let sha256: String
    }
    let id: String
    let name: String
    let summary: String
    let homepage: URL
    let regularFile: String
    let files: [File]
    var downloadSize: String { ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.size }), countStyle: .file) }

    func verify(at directory: URL) throws {
        for file in files {
            guard file.name == URL(fileURLWithPath: file.name).lastPathComponent,
                  file.url.scheme == "https", file.url.host == "raw.githubusercontent.com",
                  file.url.path.hasPrefix("/google/fonts/"), file.size > 0, file.size < 10 * 1024 * 1024 else {
                throw NiaUpdateError.invalidDownload
            }
            let url = directory.appendingPathComponent(file.name)
            guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
                  (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue == file.size,
                  try NiaFileDigest.sha256(url) == file.sha256 else { throw NiaUpdateError.invalidDownload }
        }
    }

    func regularName(at directory: URL) throws -> String {
        let url = directory.appendingPathComponent(regularFile)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let regular = descriptors.first(where: { CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String == "Regular" }) else {
            throw NiaUpdateError.invalidDownload
        }
        let font = CTFontCreateWithFontDescriptor(regular, 13, nil)
        guard CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) else { throw NiaUpdateError.invalidDownload }
        return CTFontCopyPostScriptName(font) as String
    }
}

@MainActor final class NiaFontLibrary: ObservableObject {
    static let shared = NiaFontLibrary()
    let catalog: [NiaDownloadableFont]
    @Published private(set) var installed: [NiaFontChoice] = []
    @Published private(set) var downloaded: [String: String] = [:]
    @Published private(set) var downloading: String?
    @Published private(set) var errorMessage: String?
    private let directory: URL
    private let http: NiaHTTP

    init(catalogURL: URL? = Bundle.main.url(forResource: "FontCatalog", withExtension: "json"),
         directory: URL? = nil, http: NiaHTTP = NiaHTTP()) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ember-terminal/fonts", isDirectory: true)
        self.http = http
        catalog = catalogURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([NiaDownloadableFont].self, from: $0) } ?? []
        // Register once before rendering a terminal; refresh the picker only
        // when downloads add fonts, never on a screen refresh.
        for font in catalog {
            let location = self.directory.appendingPathComponent(font.id)
            if (try? font.verify(at: location)) != nil { try? register(font, at: location) }
        }
        installed = NiaMonospaceFonts.installed()
    }

    private func register(_ font: NiaDownloadableFont, at directory: URL) throws {
        let regular = try font.regularName(at: directory)
        for file in font.files where file.name.hasSuffix(".ttf") {
            let url = directory.appendingPathComponent(file.name)
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        // A system-installed copy may already provide the same family.
        guard NSFont(name: regular, size: 13) != nil else { throw NiaUpdateError.invalidDownload }
        downloaded[font.id] = regular
    }

    func download(_ font: NiaDownloadableFont) async -> String? {
        guard downloading == nil else { return nil }
        downloading = font.id
        errorMessage = nil
        defer { downloading = nil }
        let staging = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            for file in font.files {
                let (data, _) = try await http.data(file.url, limit: 10 * 1024 * 1024)
                try Task.checkCancellation()
                try data.write(to: staging.appendingPathComponent(file.name), options: .atomic)
            }
            try font.verify(at: staging)
            _ = try font.regularName(at: staging)
            let destination = directory.appendingPathComponent(font.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard downloaded[font.id] == nil else { return downloaded[font.id] }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            try register(font, at: destination)
            installed = NiaMonospaceFonts.installed()
            return downloaded[font.id]
        } catch {
            errorMessage = NiaL10n.string("No se pudo descargar o verificar la fuente. Inténtalo de nuevo.")
            return nil
        }
    }

    func showLicense(_ font: NiaDownloadableFont) {
        NSWorkspace.shared.open(directory.appendingPathComponent(font.id).appendingPathComponent("OFL.txt"))
    }
}

struct NiaFontSettings: View {
    @ObservedObject private var library = NiaFontLibrary.shared
    @AppStorage("nia.fontName") private var fontName = "system"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fuentes para programar").font(.title2.weight(.semibold))
                Text("Descargas opcionales de Google Fonts, con licencia libre. Se guardan para nia_ y no cambian las fuentes del sistema.")
                    .foregroundStyle(.secondary).font(.callout)
                ForEach(library.catalog) { font in
                    GroupBox {
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(font.name).font(.headline)
                                Text(LocalizedStringKey(font.summary)).foregroundStyle(.secondary).font(.caption)
                                Text("0O 1Il  {} []  -> !=  const value = 42;")
                                    .font(library.downloaded[font.id].map { .custom($0, size: 14) } ?? .system(size: 14, design: .monospaced))
                                HStack {
                                    Link("Proyecto", destination: font.homepage)
                                    Text("· \(font.downloadSize)").foregroundStyle(.secondary)
                                    if library.downloaded[font.id] != nil {
                                        Button("Licencia") { library.showLicense(font) }.buttonStyle(.link)
                                    }
                                }.font(.caption)
                            }
                            Spacer(minLength: 0)
                            if library.downloading == font.id {
                                ProgressView().controlSize(.small)
                            } else if let name = library.downloaded[font.id] {
                                Button { fontName = name } label: {
                                    Text(LocalizedStringKey(fontName == name ? "En uso" : "Usar"))
                                }.disabled(fontName == name)
                            } else {
                                Button("Descargar y usar") {
                                    Task { if let name = await library.download(font) { fontName = name } }
                                }.disabled(library.downloading != nil)
                            }
                        }.padding(8)
                    }
                }
                if let error = library.errorMessage { Text(verbatim: error).foregroundStyle(.red) }
                Text("La previsualización usa la fuente del sistema hasta descargar la familia. El terminal mantiene el dibujo por celdas; las ligaduras entre varios caracteres no están activadas.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }
}
