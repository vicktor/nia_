// SPDX-License-Identifier: MPL-2.0

struct NiaTerminalCursorPosition: Equatable {
    let row: Int
    let column: Int
}

/// Cursor coordinates belong to the terminal parser. Blank rows are valid
/// positions (for example after Enter in `cat`) and must not move the cursor.
struct NiaTerminalCursor {
    static let blinkInterval = 0.55
    private(set) var phaseVisible = true
    private var nextBlink = 0.0

    static func position(row: Int, column: Int, rows: Int, columns: Int) -> NiaTerminalCursorPosition? {
        guard rows > 0, columns > 0 else { return nil }
        return NiaTerminalCursorPosition(row: min(max(0, row), rows - 1),
                                         column: min(max(0, column), columns - 1))
    }

    /// Returns whether a previously hidden cursor needs repainting immediately.
    @discardableResult
    mutating func recordActivity(at now: Double) -> Bool {
        let changed = !phaseVisible
        phaseVisible = true
        nextBlink = now + Self.blinkInterval
        return changed
    }

    /// Called from a monotonic clock; an old timer tick cannot hide a cursor
    /// immediately after input or a parser-reported position change.
    mutating func advance(at now: Double) -> Bool {
        guard now >= nextBlink else { return false }
        phaseVisible.toggle()
        nextBlink = now + Self.blinkInterval
        return true
    }
}
