// SPDX-License-Identifier: MPL-2.0
import Foundation

struct NiaTerminalLink: Equatable {
    let url: URL
    let firstColumn: Int
    let lastColumn: Int
    var copyText: String { url.isFileURL ? url.path : url.absoluteString }
}

/// Visible-row syntax only. No filesystem access on hover, click hit testing,
/// or the Metal draw path. Existence is checked off the UI thread on activation.
enum NiaTerminalLinkDetector {
    private static let webPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: .caseInsensitive)
    private static let tokenPattern = try! NSRegularExpression(pattern: #"(?:\\[^\r\n]|"[^"\r\n]*"|'[^'\r\n]*'|`[^`\r\n]*`|[^\s\\"'`])+"#)
    private static let locationSuffix = try! NSRegularExpression(pattern: #":\d+(?::\d+)?$"#)
    private static let filenamePattern = try! NSRegularExpression(pattern: #"^[\p{L}\p{N}_@+.-]+\.\p{L}[\p{L}\p{N}]{0,15}$"#)

    static func link(in cells: [TerminalCell], column: Int, workingDirectory: String?,
                     homeDirectory: String = NSHomeDirectory()) -> NiaTerminalLink? {
        guard cells.indices.contains(column), cells.count <= 8192 else { return nil }
        var value = ""
        var columns: [Int] = []
        var lastColumns: [Int] = []
        for (index, cell) in cells.enumerated() where !cell.continuation {
            let glyph = cell.t.isEmpty ? " " : cell.t
            guard columns.count + glyph.utf16.count <= 32768 else { return nil }
            value += glyph
            columns += Array(repeating: index, count: glyph.utf16.count)
            lastColumns += Array(repeating: min(cells.count - 1, index + (cell.wide ? 1 : 0)), count: glyph.utf16.count)
        }
        let ns = value as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        func contains(_ range: NSRange) -> Bool {
            range.length > 0 && range.location >= 0 && NSMaxRange(range) <= columns.count
                && column >= columns[range.location] && column <= lastColumns[NSMaxRange(range) - 1]
        }
        func hit(_ url: URL, _ range: NSRange) -> NiaTerminalLink? {
            guard contains(range) else { return nil }
            return NiaTerminalLink(url: url, firstColumn: columns[range.location], lastColumn: lastColumns[NSMaxRange(range) - 1])
        }
        // URLs win over paths, including their /path component. Invalid web
        // URLs must not fall through and become local filesystem links.
        for match in webPattern.matches(in: value, range: fullRange) where contains(match.range) {
            var range = match.range
            var candidate = ns.substring(with: range)
            while let last = candidate.last, ".,;:!?)]}".contains(last) {
                candidate.removeLast()
            }
            range.length = candidate.utf16.count
            guard candidate.utf16.count <= 2048, let url = URL(string: candidate),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
            return hit(url, range)
        }
        guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
        for token in tokenPattern.matches(in: value, range: fullRange) where contains(token.range) {
            var range = token.range
            var raw = ns.substring(with: range)
            guard raw.utf16.count <= 4096 else { return nil }
            // Markdown [label](path) and common path=/tmp/file diagnostics.
            if let marker = raw.range(of: "](") {
                let prefix = raw[..<marker.upperBound].utf16.count
                range.location += prefix; range.length -= prefix
                raw = String(raw[marker.upperBound...])
            } else if let equal = raw.firstIndex(of: "="),
                      raw[..<equal].allSatisfy({ $0.isLetter || $0 == "_" }) {
                let start = raw.index(after: equal)
                let prefix = raw[..<start].utf16.count
                range.location += prefix; range.length -= prefix
                raw = String(raw[start...])
            }
            let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">", "\"": "\"", "'": "'", "`": "`"]
            var quoted = false
            // Remove prose decoration while retaining balanced filename parens
            // and punctuation inside a quoted path.
            for _ in 0..<32 where !raw.isEmpty {
                if let first = raw.first, let last = raw.last,
                   raw.count > 1, pairs[first] == last {
                    range.location += 1
                    range.length -= 2
                    raw.removeFirst(); raw.removeLast()
                    if "\"'`".contains(first) { quoted = true; break }
                } else if let last = raw.last, ".,;:!?)]}>".contains(last) {
                    if let opener = pairs.first(where: { $0.value == last })?.key,
                       raw.filter({ $0 == opener }).count >= raw.filter({ $0 == last }).count { break }
                    range.length -= 1
                    raw.removeLast()
                } else { break }
            }
            guard contains(range), !raw.isEmpty, raw.utf16.count <= 4096 else { return nil }
            var path = quoted ? raw : unescapePath(raw)
            if let suffix = locationSuffix.firstMatch(in: path, range: NSRange(location: 0, length: path.utf16.count)) {
                path = (path as NSString).substring(to: suffix.range.location)
            }
            guard !path.isEmpty, !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { return nil }
            let url: URL
            if path.lowercased().hasPrefix("file://") {
                guard let decoded = path.removingPercentEncoding,
                      !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let parsed = URL(string: path), parsed.isFileURL,
                      parsed.host == nil || parsed.host == "" || parsed.host?.lowercased() == "localhost",
                      parsed.user == nil, parsed.password == nil,
                      !parsed.path.contains("\0"), !parsed.path.isEmpty else { return nil }
                url = URL(fileURLWithPath: parsed.path)
            } else {
                guard !path.contains("://"), !path.contains("$"), !path.contains("`"),
                      !path.contains(":/"), !path.hasPrefix("//") else { return nil }
                if path.hasPrefix("~/") {
                    url = URL(fileURLWithPath: homeDirectory).appendingPathComponent(String(path.dropFirst(2)))
                } else if path.hasPrefix("/") {
                    url = URL(fileURLWithPath: path)
                } else {
                    let isFilename = filenamePattern.firstMatch(in: path, range: NSRange(location: 0, length: path.utf16.count)) != nil
                    guard !path.hasPrefix("~"), !path.hasPrefix("-"),
                          path.contains("/") || isFilename else { return nil }
                    url = URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(path)
                }
            }
            return hit(url.standardizedFileURL, range)
        }
        return nil
    }

    private static func unescapePath(_ raw: String) -> String {
        var result = ""
        var characters = raw.makeIterator()
        while let character = characters.next() {
            if character == "\\", let next = characters.next() { result.append(next) }
            else { result.append(character) }
        }
        return result
    }
}
