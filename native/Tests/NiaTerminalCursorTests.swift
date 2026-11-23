// SPDX-License-Identifier: MPL-2.0
// swiftc native/Sources/NiaTerminalCursor.swift native/Tests/NiaTerminalCursorTests.swift -o /tmp/nia-cursor-tests
// /tmp/nia-cursor-tests

@main
struct NiaTerminalCursorTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
            checks += 1
        }

        // Regression: after Enter in a prompt-less program, the parser is on
        // a blank row. The old renderer searched prior text and painted row0,
        // then jumped to row1 as soon as the first character was echoed.
        let afterEnter = NiaTerminalCursor.position(row: 1, column: 0, rows: 30, columns: 100)
        let afterFirstCharacter = NiaTerminalCursor.position(row: 1, column: 1, rows: 30, columns: 100)
        check(afterEnter == NiaTerminalCursorPosition(row: 1, column: 0), "Blank input rows retain the parser position")
        check(afterFirstCharacter?.row == afterEnter?.row, "First echoed character must not make the cursor jump rows")
        check(afterFirstCharacter?.column == 1, "Echo advances the cursor in the parser's column")
        check(NiaTerminalCursor.position(row: 29, column: 0, rows: 30, columns: 100)?.row == 29,
              "The empty last row remains usable")
        check(NiaTerminalCursor.position(row: 2, column: 0, rows: 30, columns: 100)?.row == 2,
              "Wrapping to an empty row must not seek previous text")
        check(NiaTerminalCursor.position(row: 0, column: 0, rows: 0, columns: 100) == nil, "An empty snapshot has no cursor")
        check(NiaTerminalCursor.position(row: 0, column: 0, rows: 30, columns: 0) == nil, "A zero-width snapshot has no cursor")
        check(NiaTerminalCursor.position(row: -1, column: -2, rows: 30, columns: 100) == NiaTerminalCursorPosition(row: 0, column: 0),
              "Invalid negative coordinates stay inside the grid")
        check(NiaTerminalCursor.position(row: 40, column: 200, rows: 30, columns: 100) == NiaTerminalCursorPosition(row: 29, column: 99),
              "Out-of-bounds coordinates clamp to the grid without scanning text")

        var cursor = NiaTerminalCursor()
        let interval = NiaTerminalCursor.blinkInterval
        check(cursor.phaseVisible, "Cursor starts visible")
        check(!cursor.recordActivity(at: 10), "Activity on a visible cursor needs no extra repaint")
        check(!cursor.advance(at: 10.1) && cursor.phaseVisible, "A stale timer tick must not hide recent input")
        check(cursor.advance(at: 10 + interval) && !cursor.phaseVisible, "Idle cursor blinks after its interval")
        check(cursor.recordActivity(at: 11) && cursor.phaseVisible, "Typing while hidden immediately shows the cursor")
        check(!cursor.recordActivity(at: 11.2), "Continued typing postpones blinking")
        check(!cursor.advance(at: 11 + interval) && cursor.phaseVisible, "The previous blink deadline is cancelled by activity")
        check(cursor.advance(at: 11.2 + interval) && !cursor.phaseVisible, "Blinking resumes after the latest input")
        check(cursor.recordActivity(at: 12) && cursor.phaseVisible, "Parser cursor movement also restores visibility")
        check(!cursor.advance(at: 12.1), "Movement is protected from an old timer tick")
        check(cursor.advance(at: 12 + interval) && !cursor.phaseVisible, "Idle period after movement can blink")
        check(cursor.advance(at: 20) && cursor.phaseVisible, "A late timer advances once without catch-up flicker")
        check(!cursor.advance(at: 20.1), "A late timer establishes a fresh deadline")
        print("Nia terminal cursor: \(checks) checks passed")
    }
}
