// SPDX-License-Identifier: MPL-2.0
// swiftc -O native/Sources/NiaScreenDecoder.swift native/Tests/NiaScreenDecoderTests.swift -o /tmp/nia-screen-tests
// /tmp/nia-screen-tests [--benchmark | --compare snapshot.bin snapshot.json]
import Foundation
import Dispatch

@main
struct NiaScreenDecoderTests {
    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        let bits = UInt64(truncatingIfNeeded: value)
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: bits >> shift))
        }
    }

    private static func packet(_ snapshot: ScreenSnapshot, revision: UInt64 = 0x0102030405060708) -> Data {
        var bytes = Array("NIA1".utf8)
        append(revision, to: &bytes)
        append(snapshot.rows, to: &bytes)
        append(snapshot.cols, to: &bytes)
        append(snapshot.cursor_row, to: &bytes)
        append(snapshot.cursor_col, to: &bytes)
        append(UInt64(snapshot.scrollback_offset), to: &bytes)
        bytes += [snapshot.cursor_visible ? 1 : 0, 0, 0, 0]
        for cell in snapshot.cells.flatMap({ $0 }) {
            append(cell.fg, to: &bytes)
            append(cell.bg, to: &bytes)
            bytes.append(cell.flags)
            bytes.append((cell.wide ? 1 : 0) | (cell.continuation ? 2 : 0))
            let text = Array(cell.t.utf8)
            append(UInt16(text.count), to: &bytes)
            bytes += text
        }
        return Data(bytes)
    }

    private static func json(_ snapshot: ScreenSnapshot) throws -> Data {
        let cells: [[[String: Any]]] = snapshot.cells.map { row in
            row.map { cell in
                ["t": cell.t, "fg": Int(cell.fg), "bg": Int(cell.bg), "flags": Int(cell.flags),
                 "wide": cell.wide, "continuation": cell.continuation]
            }
        }
        return try JSONSerialization.data(withJSONObject: [
            "session_id": snapshot.session_id, "cells": cells,
            "rows": Int(snapshot.rows), "cols": Int(snapshot.cols),
            "cursor_row": Int(snapshot.cursor_row), "cursor_col": Int(snapshot.cursor_col),
            "cursor_visible": snapshot.cursor_visible, "scrollback_offset": snapshot.scrollback_offset
        ])
    }

    private static func singleCell(_ text: String) -> ScreenSnapshot {
        ScreenSnapshot(session_id: "test", cells: [[TerminalCell(
            t: text, fg: -1, bg: -1, flags: 0, wide: false, continuation: false)]],
            cursor_row: 0, cursor_col: 0, cursor_visible: true, rows: 1, cols: 1, scrollback_offset: 0)
    }

    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
            checks += 1
        }
        func reject(_ data: Data, _ expected: NiaScreenDecodingError, _ message: String) {
            do {
                _ = try NiaScreenDecoder.decode(data, sessionID: "test")
                fatalError("Accepted invalid frame: \(message)")
            } catch let error as NiaScreenDecodingError {
                check(error == expected, "\(message): \(error), expected \(expected)")
            } catch { fatalError("Unexpected error: \(error)") }
        }

        let expected = ScreenSnapshot(session_id: "sesión-α", cells: [
            [TerminalCell(t: "A", fg: -1, bg: 255, flags: 31, wide: false, continuation: false),
             TerminalCell(t: "é", fg: 0x01010203, bg: 0, flags: 1, wide: false, continuation: false),
             TerminalCell(t: "e\u{0301}", fg: 15, bg: -1, flags: 8, wide: false, continuation: false),
             TerminalCell(t: " ", fg: 16, bg: 0x01abcdef, flags: 2, wide: false, continuation: false)],
            [TerminalCell(t: "界", fg: 7, bg: -1, flags: 4, wide: true, continuation: false),
             TerminalCell(t: "", fg: 7, bg: -1, flags: 4, wide: false, continuation: true),
             TerminalCell(t: "👩‍💻", fg: 232, bg: -1, flags: 16, wide: true, continuation: false),
             TerminalCell(t: "", fg: 232, bg: -1, flags: 16, wide: false, continuation: true)]
        ], cursor_row: 1, cursor_col: 2, cursor_visible: false, rows: 2, cols: 4, scrollback_offset: 123456)
        let valid = packet(expected)
        let decoded = try NiaScreenDecoder.decode(valid, sessionID: expected.session_id)
        check(decoded.revision == 0x0102030405060708, "Read full little-endian revision")
        check(decoded.snapshot == expected, "Preserve UTF-8, color signs, styles, wide cells, cursor and scrollback")
        let oldJSON = try JSONDecoder().decode(ScreenSnapshot.self, from: json(expected))
        check(decoded.snapshot == oldJSON, "Binary and legacy JSON yield the same complete snapshot")
        check(decoded.snapshot.cells[0][2].t.utf8.elementsEqual("e\u{0301}".utf8), "Keep combining bytes without normalization")

        for length in 0..<valid.count {
            reject(Data(valid.prefix(length)), .truncated, "Truncation at byte \(length)")
        }
        var malformed = valid
        malformed[3] = Character("2").asciiValue!
        reject(malformed, .unsupportedFormat, "Unknown wire version")
        malformed = valid
        malformed.replaceSubrange(4..<12, with: repeatElement(UInt8(0), count: 8))
        reject(malformed, .invalidRevision, "Zero revision is reserved for a caller's unknown frame")
        for offset in [12, 14] {
            malformed = valid
            malformed[offset] = 0; malformed[offset + 1] = 0
            reject(malformed, .invalidDimensions, "Zero grid dimension")
        }
        malformed = valid
        malformed.replaceSubrange(12..<16, with: [255, 255, 255, 255])
        reject(malformed, .invalidDimensions, "Reject excessive cell product before allocating the grid")
        malformed = valid
        malformed[16] = 2
        reject(malformed, .invalidCursor, "Cursor below the grid")
        malformed = valid
        malformed[18] = 5
        reject(malformed, .invalidCursor, "Cursor beyond the pending-wrap boundary")
        malformed = valid
        malformed[18] = 4
        let wrapped = try NiaScreenDecoder.decode(malformed, sessionID: expected.session_id)
        check(wrapped.snapshot.cursor_col == expected.cols, "Pending autowrap may expose cursor column equal to width")
        for offset in [28, 29, 30, 31, 40, 41] {
            malformed = valid
            malformed[offset] = 0x80
            reject(malformed, .invalidFlags, "Reserved header/cell bits at \(offset)")
        }
        malformed = valid
        malformed.replaceSubrange(20..<28, with: repeatElement(UInt8(255), count: 8))
        reject(malformed, .oversizedPayload, "Scrollback must fit the host Int without trapping")
        malformed = valid
        malformed[42] = 255; malformed[43] = 255
        reject(malformed, .truncated, "Length prefix cannot read past the buffer")
        malformed = valid
        malformed.append(0)
        reject(malformed, .trailingBytes, "Extra cells/trailing bytes are not silently ignored")
        reject(Data(repeating: 0, count: NiaScreenDecoder.maximumByteCount + 1), .oversizedPayload,
               "Reject oversized payloads before parsing or allocating a grid")

        for invalid: [UInt8] in [[0x80], [0xff], [0xc0, 0xaf], [0xe2, 0x82],
                                [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xe2, 0x28, 0xa1]] {
            var bytes = Array(packet(singleCell("")))
            bytes[42] = UInt8(invalid.count)
            bytes += invalid
            reject(Data(bytes), .invalidUTF8, "Malformed UTF-8: \(invalid)")
        }
        for text in ["", "\u{0000}", "\t", "ñ", "🇪🇸", "\u{10ffff}"] {
            let snapshot = singleCell(text)
            let result = try NiaScreenDecoder.decode(packet(snapshot), sessionID: snapshot.session_id)
            check(result.snapshot == snapshot, "Valid empty/ASCII/Unicode text: \(text.debugDescription)")
        }

        var unaligned = Data([0])
        unaligned.append(valid)
        let unalignedResult = try unaligned.withUnsafeBytes { bytes in
            try NiaScreenDecoder.decode(UnsafeRawBufferPointer(rebasing: bytes[1...]), sessionID: expected.session_id)
        }
        check(unalignedResult.snapshot == expected, "FFI input need not be aligned for integer loads")
        let longText = String(repeating: "owned é界 ", count: 20)
        let ownedBytes = packet(singleCell(longText))
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: ownedBytes.count, alignment: 1)
        ownedBytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let owned = try NiaScreenDecoder.decode(UnsafeRawBufferPointer(start: pointer, count: ownedBytes.count), sessionID: "test")
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: ownedBytes.count)
        pointer.deallocate()
        check(owned.snapshot.cells[0][0].t == longText, "Swift strings outlive freed Rust snapshot buffers")
        print("Nia screen decoder: \(checks) checks passed")

        if CommandLine.arguments.contains("--benchmark") { try benchmark() }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--compare" {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let jsonBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            let legacy = try JSONDecoder().decode(ScreenSnapshot.self, from: jsonBytes)
            let binary = try NiaScreenDecoder.decode(bytes, sessionID: legacy.session_id)
            check(binary.snapshot == legacy, "Rust-produced binary must match its legacy JSON snapshot")
            print("Rust/Swift snapshot equivalence passed (revision \(binary.revision), \(legacy.rows)×\(legacy.cols))")
        }
    }

    private static func benchmark() throws {
        var checksum = 0
        func measure(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.3f ms / p95 %.3f ms", sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])
        }
        for (rows, columns) in [(30, 100), (50, 160), (80, 240)] {
            let cell = TerminalCell(t: "a", fg: -1, bg: -1, flags: 0, wide: false, continuation: false)
            let snapshot = ScreenSnapshot(session_id: "benchmark", cells: Array(repeating: Array(repeating: cell, count: columns), count: rows),
                cursor_row: UInt16(rows - 1), cursor_col: UInt16(columns - 1), cursor_visible: true,
                rows: UInt16(rows), cols: UInt16(columns), scrollback_offset: 0)
            let binary = packet(snapshot), legacy = try json(snapshot)
            let raw = String(decoding: legacy, as: UTF8.self)
            var jsonTimes: [Double] = [], binaryTimes: [Double] = []
            for _ in 0..<80 {
                jsonTimes.append(try measure {
                    let result = try JSONDecoder().decode(ScreenSnapshot.self, from: raw.data(using: .utf8)!)
                    checksum += Int(result.cols)
                })
                binaryTimes.append(try measure {
                    let result = try NiaScreenDecoder.decode(binary, sessionID: snapshot.session_id)
                    checksum += Int(result.snapshot.cols)
                })
            }
            print("\(rows)×\(columns): JSON \(legacy.count) B \(summary(jsonTimes)); NIA1 \(binary.count) B \(summary(binaryTimes))")
        }
        print("Benchmark checksum: \(checksum)")
    }
}
