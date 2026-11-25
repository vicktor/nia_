#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Exercise SwiftUI's name-field → AppKit terminal focus handoff offscreen.

The creation action is extracted unchanged from MainWindow. The terminal view
and SwiftUI focus system are real; only session creation/storage are substituted.
No window is shown and no user sessions or keyboard events are used.
Run: python3 -m unittest discover -s tests -p test_native_focus.py -v
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
import AppKit
import SwiftUI

enum NiaL10n { static func string(_ key: String) -> String { key } }

@MainActor final class FocusModel: ObservableObject {
    @Published var selected: String?
    @Published var secondary: String?
    @Published var activePane = 0
    @Published var focusSession: String?
    @Published var focusEpoch: UInt64 = 0
    @Published var revision: UInt64 = 0
    var edit: ((String) -> Void)?
    var submit: (() -> Void)?

    func create(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if activePane == 1 { secondary = name } else { selected = name }
        focusSession = name
        focusEpoch &+= 1
    }
}

struct FocusForm: View {
    @ObservedObject var model: FocusModel
    @State private var newSession = ""
    @FocusState private var addingSession: Bool

    var body: some View {
        HStack {
            VStack {
                TextField("Nueva sesión", text: $newSession)
                    .focused($addingSession)
                    .onSubmit { create() }
                Button("Crear", action: create)
            }.frame(width: 180)
            if let id = model.selected { pane(id) }
            if let id = model.secondary { pane(id) }
        }
        .onAppear {
            model.edit = { name in newSession = name; addingSession = true }
            model.submit = { create() }
        }
    }

    private func pane(_ id: String) -> some View {
        TerminalPanel(sessionID: id, workingDirectory: nil, frame: nil,
            revision: model.revision, cursorBlink: false, cursorShape: "bar",
            opacity: 1, fontName: "system", fontSize: 13,
            focusEpoch: model.focusSession == id ? model.focusEpoch : 0,
            onFocus: {},
            onInput: { _ in },
            onResize: { _, _ in true }, onScroll: { _, _, _ in }, onCopy: {})
    }

__CREATE__
}

@main struct FocusTests {
    @MainActor static func settle() {
        // Let both SwiftUI focus reconciliation and NSView updates complete.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func window(_ model: FocusModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: FocusForm(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        check(model.edit != nil && model.submit != nil, "the real SwiftUI form must be mounted")
        return window
    }
    @MainActor static func create(_ name: String, model: FocusModel, window: NSWindow) {
        model.edit?(name)
        settle()
        check((window.firstResponder as? NSTextView)?.isFieldEditor == true,
              "the name field must have keyboard focus before submitting")
        model.submit?()
        settle()
        check((window.firstResponder as? NiaMetalView)?.activeSessionID == name,
              "confirming \(name) must focus its terminal after SwiftUI settles")
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = FocusModel()
        let firstWindow = window(model)
        create("first", model: model, window: firstWindow)
        create("second", model: model, window: firstWindow)
        create("third", model: model, window: firstWindow)
        model.activePane = 1
        create("right", model: model, window: firstWindow)
        create("right-again", model: model, window: firstWindow)
        check(model.selected == "third", "creation in the right pane must preserve the left pane")
        model.activePane = 0
        create("left-again", model: model, window: firstWindow)
        check(model.secondary == "right-again", "creation in the left pane must preserve the right pane")

        // Updating an unchanged focus request must never take focus back from a
        // field the user has deliberately started editing after creation.
        model.edit?("next-name")
        settle()
        let editor = firstWindow.firstResponder
        model.revision &+= 1
        settle()
        check(firstWindow.firstResponder === editor && (editor as? NSTextView)?.isFieldEditor == true,
              "a later terminal refresh must not steal focus from the name field")

        create("before-other-window", model: model, window: firstWindow)
        let firstTerminal = firstWindow.firstResponder
        let otherModel = FocusModel()
        let otherWindow = window(otherModel)
        create("other-window", model: otherModel, window: otherWindow)
        check(firstWindow.firstResponder === firstTerminal, "creating a terminal must not change another window's terminal responder")
        print("Focus handoff checks passed: repeated creation, both split panes, editing and independent windows")
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "Requires AppKit and SwiftUI")
class NativeFocusTests(unittest.TestCase):
    def test_creation_hands_focus_to_terminal_after_swiftui_reconciliation(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("Swift compiler unavailable")
        source = (ROOT / "native/Sources/NiaApp.swift").read_text()
        start = source.index("    private func create() {")
        end = source.index("\n}\n", start)
        create = source[start:end]
        with tempfile.TemporaryDirectory(prefix="nia-focus-tests-") as directory:
            path = Path(directory)
            harness = path / "FocusTests.swift"
            harness.write_text(HARNESS.replace("__CREATE__", create))
            binary = path / "focus-tests"
            sources = ["NiaScreenDecoder.swift", "NiaTerminalGeometry.swift", "NiaTerminalCursor.swift",
                       "NiaTerminalView.swift", "NiaTerminalLink.swift"]
            build = subprocess.run(
                [compiler, "-parse-as-library", str(harness),
                 *[str(ROOT / "native/Sources" / name) for name in sources], "-o", str(binary)],
                capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
