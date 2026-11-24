// SPDX-License-Identifier: MPL-2.0
import AppKit

// The terminal view uses the app's localization helper; this standalone test
// does not link the @main SwiftUI application.
enum NiaL10n {
    static func string(_ key: String) -> String { key }
}

@main struct NiaClipboardTests {
    @MainActor static var checks = 0

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init("dev.nia.clipboard-test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NiaMetalView(frame: window.contentView!.bounds)
        window.contentView = view
        view.copyPasteboard = pasteboard
        view.activeSessionID = "first"
        let text = "añ é 漢"
        let cells = ["a", "ñ", " ", "é", " ", "漢", ""].enumerated().map { index, value in
            TerminalCell(t: value, fg: -1, bg: -1, flags: 0,
                         wide: index == 5, continuation: index == 6)
        }
        let frame = ScreenSnapshot(session_id: "first", cells: [cells],
            cursor_row: 0, cursor_col: 0, cursor_visible: true,
            rows: 1, cols: UInt16(cells.count), scrollback_offset: 0)
        view.present(frame, revision: 1)
        pasteboard.setString("untouched", forType: .string)
        var confirmations = 0
        view.onCopy = {
            check(pasteboard.string(forType: .string) == text,
                  "Confirmation must follow a successful Unicode clipboard write")
            confirmations += 1
        }
        view.copy(nil)
        check(confirmations == 0, "No selection must not show a confirmation")
        check(pasteboard.string(forType: .string) == "untouched",
              "No selection must leave the clipboard intact")

        let location = view.convert(NSPoint(x: 1, y: 1), to: nil)
        let selection = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 3, pressure: 1)!
        view.mouseDown(with: selection)
        check(confirmations == 1, "Automatic selection copy must notify its pane")
        let release = NSEvent.mouseEvent(with: .leftMouseUp, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 3, pressure: 0)!
        view.mouseUp(with: release)
        check(confirmations == 1, "Releasing a triple-click must not announce the same copy twice")
        check(window.firstResponder === view, "Copy confirmation must retain terminal focus")
        view.copy(nil)
        check(confirmations == 2, "Repeated copies must each renew the confirmation")

        view.activeSessionID = "second"
        view.present(frame, revision: 2)
        view.copy(nil)
        check(confirmations == 2, "Changing session must discard the previous selection")
        view.copyOnSelection = false
        view.mouseDown(with: selection)
        check(confirmations == 2, "Disabling automatic copy must suppress its confirmation")
        let commandC = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "c", charactersIgnoringModifiers: "c",
            isARepeat: false, keyCode: 8)!
        check(view.performKeyEquivalent(with: commandC), "The focused terminal must handle Cmd+C")
        check(confirmations == 3, "Manual copy must still notify with automatic copy disabled")
        check(window.firstResponder === view, "Manual copy must retain terminal focus")
        var scrolls: [Int] = []
        var input: [UInt8] = []
        view.onScroll = { lines, _, _ in scrolls.append(lines) }
        view.onBytes = { input.append(contentsOf: $0) }
        func wheel(momentum: Int64 = 0) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0)!
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return NSEvent(cgEvent: event)!
        }
        view.scrollWheel(with: wheel())
        check(!scrolls.isEmpty, "A deliberate wheel gesture must reach the terminal")
        check(abs(scrolls[0]) <= 2, "Twenty trackpad points must not jump several text rows")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "x", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7)!
        view.keyDown(with: key)
        check(input == Array("x".utf8), "Typing must still reach the PTY input callback")
        for code: UInt16 in [36, 76] {
            input = []
            let shiftedReturn = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: code)!
            view.keyDown(with: shiftedReturn)
            check(input == Array("\u{1b}[13;2u".utf8), "Shift+Return must preserve the modifier instead of submitting")
            input = []
            let plainReturn = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: code)!
            view.keyDown(with: plainReturn)
            check(input == [13], "Plain Return must still submit")
        }
        let beforeMomentum = scrolls.count
        let momentum = wheel(momentum: 1)
        check(!momentum.momentumPhase.isEmpty, "The regression must exercise a real momentum event")
        view.scrollWheel(with: momentum)
        check(scrolls.count == beforeMomentum, "Momentum after typing must not hide the prompt again")
        view.scrollWheel(with: wheel())
        check(scrolls.count == beforeMomentum + 1, "A new deliberate gesture must re-enable scrolling")
        let secondView = NiaMetalView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        view.addSubview(secondView)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        view.mouseDown(with: click)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        check(window.firstResponder === view,
              "A newly attached pane must not steal focus after the user clicks another pane")
        secondView.updateFocusRequest(1)
        check(window.firstResponder === secondView, "An explicit pane focus request must take effect")
        secondView.updateFocusRequest(0)
        view.mouseDown(with: click)
        secondView.updateFocusRequest(0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        check(window.firstResponder === view, "An inactive pane must not regain keyboard focus")
        let pendingView = NiaMetalView(frame: secondView.frame)
        pendingView.updateFocusRequest(2)
        view.addSubview(pendingView)
        check(window.firstResponder === pendingView, "A focus request before attachment must be applied on attachment")
        print("\(checks) clipboard, scroll and focus checks passed")
    }
}
