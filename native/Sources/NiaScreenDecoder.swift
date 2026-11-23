// SPDX-License-Identifier: MPL-2.0
import Foundation

struct TerminalCell: Decodable, Equatable {
    let t: String
    let fg: Int32
    let bg: Int32
    let flags: UInt8
    let wide: Bool
    let continuation: Bool
}

struct ScreenSnapshot: Decodable, Equatable {
    let session_id: String
    let cells: [[TerminalCell]]
    let cursor_row: UInt16
    let cursor_col: UInt16
    let cursor_visible: Bool
    let rows: UInt16
    let cols: UInt16
    let scrollback_offset: Int
}

struct NiaDecodedScreenSnapshot {
    let revision: UInt64
    let snapshot: ScreenSnapshot
}

enum NiaScreenDecodingError: Error, Equatable {
    case truncated
    case unsupportedFormat
    case invalidRevision
    case invalidDimensions
    case invalidCursor
    case invalidFlags
    case invalidUTF8
    case oversizedPayload
    case trailingBytes
}

/// NIA1 is an owned, complete frame, not a delta or a pointer into Rust's VT grid.
/// All integers are little-endian. The 32-byte header contains magic, revision,
/// rows/columns, cursor row/column, UInt64 scrollback, visible byte and 3 zero bytes.
/// Each row-major cell has Int32 foreground/background, style/width flags,
/// a UInt16 UTF-8 byte count, then that many text bytes (12-byte fixed prefix).
enum NiaScreenDecoder {
    static let maximumCellCount = 1_000_000
    static let maximumByteCount = 64 * 1024 * 1024

    // Most terminal cells are empty or one ASCII byte. Reuse their small strings
    // instead of invoking Foundation's UTF-8 conversion for every displayed cell.
    private static let ascii = (0..<128).map { String(UnicodeScalar($0)!) }

    static func decode(_ data: Data, sessionID: String) throws -> NiaDecodedScreenSnapshot {
        try data.withUnsafeBytes { bytes in
            try decode(bytes, sessionID: sessionID)
        }
    }

    /// Returned arrays and strings own their storage; callers may free the FFI
    /// buffer immediately after this returns. No Data copy is needed on input.
    static func decode(_ bytes: UnsafeRawBufferPointer,
                       sessionID: String) throws -> NiaDecodedScreenSnapshot {
        guard bytes.count <= maximumByteCount else { throw NiaScreenDecodingError.oversizedPayload }
        guard bytes.count >= 32, bytes.baseAddress != nil else { throw NiaScreenDecodingError.truncated }
        var reader = Reader(bytes: bytes)
        guard reader.uint32() == 0x3141494e else { throw NiaScreenDecodingError.unsupportedFormat }
        let revision = reader.uint64()
        guard revision != 0 else { throw NiaScreenDecodingError.invalidRevision }
        let rows = reader.uint16(), columns = reader.uint16()
        let cursorRow = reader.uint16(), cursorColumn = reader.uint16()
        let rawScrollback = reader.uint64()
        let visible = reader.byte(), reservedByte = reader.byte(), reservedWord = reader.uint16()
        guard rows > 0, columns > 0 else { throw NiaScreenDecodingError.invalidDimensions }
        let cellCount = Int(rows) * Int(columns)
        guard cellCount <= maximumCellCount else { throw NiaScreenDecodingError.invalidDimensions }
        // vt100 can expose cursorColumn == columns while autowrap is pending.
        guard cursorRow < rows, cursorColumn <= columns else { throw NiaScreenDecodingError.invalidCursor }
        guard visible <= 1, reservedByte == 0, reservedWord == 0 else {
            throw NiaScreenDecodingError.invalidFlags
        }
        guard let scrollback = Int(exactly: rawScrollback) else { throw NiaScreenDecodingError.oversizedPayload }
        // Check the whole minimum size before allocating rows for an invalid grid.
        guard cellCount <= reader.remaining / 12 else { throw NiaScreenDecodingError.truncated }

        var grid: [[TerminalCell]] = []
        grid.reserveCapacity(Int(rows))
        for _ in 0..<rows {
            var line: [TerminalCell] = []
            line.reserveCapacity(Int(columns))
            for _ in 0..<columns {
                guard reader.remaining >= 12 else { throw NiaScreenDecodingError.truncated }
                let foreground = Int32(bitPattern: reader.uint32())
                let background = Int32(bitPattern: reader.uint32())
                let flags = reader.byte(), widths = reader.byte()
                let textLength = Int(reader.uint16())
                guard flags & ~UInt8(0x1f) == 0, widths & ~UInt8(0x03) == 0 else {
                    throw NiaScreenDecodingError.invalidFlags
                }
                let text = try reader.text(length: textLength)
                line.append(TerminalCell(t: text, fg: foreground, bg: background, flags: flags,
                                         wide: widths & 1 != 0, continuation: widths & 2 != 0))
            }
            grid.append(line)
        }
        guard reader.remaining == 0 else { throw NiaScreenDecodingError.trailingBytes }
        return NiaDecodedScreenSnapshot(revision: revision, snapshot: ScreenSnapshot(
            session_id: sessionID, cells: grid, cursor_row: cursorRow, cursor_col: cursorColumn,
            cursor_visible: visible != 0, rows: rows, cols: columns, scrollback_offset: scrollback))
    }

    /// Fixed-width reads are only used after the header/cell-prefix bounds checks.
    /// Byte-wise reads avoid alignment assumptions about Rust/Data buffers.
    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        private(set) var offset = 0
        var remaining: Int { bytes.count - offset }

        mutating func byte() -> UInt8 {
            defer { offset += 1 }
            return bytes[offset]
        }
        mutating func uint16() -> UInt16 {
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            return value
        }
        mutating func uint32() -> UInt32 {
            let value = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            offset += 4
            return value
        }
        mutating func uint64() -> UInt64 {
            let low = UInt64(uint32()), high = UInt64(uint32())
            return low | (high << 32)
        }
        mutating func text(length: Int) throws -> String {
            guard length <= remaining else { throw NiaScreenDecodingError.truncated }
            if length == 0 { return "" }
            if length == 1 {
                let value = byte()
                guard value < 128 else { throw NiaScreenDecodingError.invalidUTF8 }
                return NiaScreenDecoder.ascii[Int(value)]
            }
            let end = offset + length
            guard let value = String(bytes: bytes[offset..<end], encoding: .utf8) else {
                throw NiaScreenDecodingError.invalidUTF8
            }
            offset = end
            return value
        }
    }
}
