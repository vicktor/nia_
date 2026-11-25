// SPDX-License-Identifier: MPL-2.0
import Foundation

@main struct NiaTerminalLinkTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func cells(_ text: String) -> [TerminalCell] {
        text.map { TerminalCell(t: String($0), fg: -1, bg: -1, flags: 0, wide: false, continuation: false) }
    }
    static func link(_ text: String, at needle: String, cwd: String? = "/tmp/project") -> NiaTerminalLink? {
        let range = text.range(of: needle)!
        let column = text.distance(from: text.startIndex, to: range.lowerBound)
        return NiaTerminalLinkDetector.link(in: cells(text), column: column, workingDirectory: cwd, homeDirectory: "/Users/test")
    }
    static func main() {
        for (text, needle, expected) in [
            ("saved /tmp/result.txt", "result", "/tmp/result.txt"),
            ("~/Downloads/report.pdf", "Downloads", "/Users/test/Downloads/report.pdf"),
            ("./Sources/main.swift", "Sources", "/tmp/project/Sources/main.swift"),
            ("../README.md", "README", "/tmp/README.md"),
            ("src/main.rs:42:7", "42", "/tmp/project/src/main.rs"),
            ("README.md", "README", "/tmp/project/README.md"),
            ("\"/tmp/My Documents/report.pdf\"", "Documents", "/tmp/My Documents/report.pdf"),
            ("'/tmp/My Documents/report.pdf'", "Documents", "/tmp/My Documents/report.pdf"),
            ("`/tmp/My Documents/report.pdf`", "Documents", "/tmp/My Documents/report.pdf"),
            ("/tmp/My\\ Documents/report.pdf", "Documents", "/tmp/My Documents/report.pdf"),
            ("(/tmp/report.txt).", "report", "/tmp/report.txt"),
            ("[file](/tmp/report.txt:20)", "report", "/tmp/report.txt"),
            ("path=/tmp/report.txt", "report", "/tmp/report.txt"),
            ("/tmp/report(1).txt", "report", "/tmp/report(1).txt"),
            ("\"/tmp/report,.txt\"", "report", "/tmp/report,.txt"),
            ("file:///tmp/My%20Documents/report.pdf", "Documents", "/tmp/My Documents/report.pdf"),
            ("file://localhost/tmp/report.txt", "report", "/tmp/report.txt"),
            ("🙂 é /tmp/日本語.txt", "日本", "/tmp/日本語.txt"),
        ] {
            let hit = link(text, at: needle)
            check(hit?.url.isFileURL == true && hit?.url.path == expected, "path: \(text) -> \(String(describing: hit))")
            check(hit?.copyText == expected, "copy uses native path")
        }
        for source in ["https://example.com/a/b?q=1", "http://localhost:8080/path"] {
            let hit = link(source, at: "path" == source.suffix(4) ? "path" : "example", cwd: nil)
            check(hit?.url.absoluteString == source && hit?.url.isFileURL == false, "web links still work remotely")
        }
        for (text, needle) in [
            ("plain text", "plain"), ("https://user:secret@example.com/tmp/a", "tmp"),
            ("ftp://server/tmp/a", "tmp"), ("file://server/tmp/a", "tmp"),
            ("user@server:/tmp/a", "tmp"), ("$HOME/Documents/a", "Documents"),
            ("//server/path", "path"), ("file:///tmp/a%00b", "tmp"),
        ] { check(link(text, at: needle) == nil, "unsupported: \(text)") }
        check(link("/tmp/local", at: "local", cwd: nil) == nil, "remote sessions do not resolve local paths")
        check(link("src/file.swift", at: "file", cwd: "/other/project")?.url.path == "/other/project/src/file.swift", "relative path follows session cwd")
        check(link("(/tmp/report.txt).", at: ").") == nil, "punctuation is outside the clickable range")
        check(link("\"/tmp/a b\"", at: "\"") == nil, "quotes are outside the clickable range")
        let wide = [TerminalCell(t: "界", fg: -1, bg: -1, flags: 0, wide: true, continuation: false),
                    TerminalCell(t: "", fg: -1, bg: -1, flags: 0, wide: false, continuation: true)] + cells(" /tmp/a.txt")
        let hit = NiaTerminalLinkDetector.link(in: wide, column: 8, workingDirectory: "/tmp")
        check(hit?.firstColumn == 3 && hit?.lastColumn == 12, "wide glyphs before paths preserve cell coordinates")
        check(NiaTerminalLinkDetector.link(in: cells("/tmp/a"), column: 99, workingDirectory: "/tmp") == nil, "out-of-bounds click")
        print("\(checks) terminal link checks passed")
    }
}
