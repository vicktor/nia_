#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Exercise actual tab close/open/restore methods with an isolated FFI store.

AppKit rendering and the Rust boundary are stubbed; the model methods and
workspace serialization are extracted unchanged. Rust tests cover durable
storage and preservation of live PTYs separately.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_native_refresh import SOURCE, between


STUBS = r'''
import Foundation
enum NiaL10n { static func string(_ value: String) -> String { value } }
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    func bool(forKey: String) -> Bool { true }
    func set(_ value: Bool, forKey: String) {}
}
@MainActor enum FFI {
    static var layouts: [String: String] = [:]
    static var dismissed = Set<String>()
    static var closed = Set<String>()
    static var opened: [String] = []
    static var failDismiss = false
    static func sessions() -> String {
        let rows = ["left", "right", "removed"].map { id -> [String: Any] in
            ["id": id, "display_name": id, "cwd": "/tmp", "color": "blue",
             "closed": closed.contains(id), "dismissed": dismissed.contains(id)]
        }
        return String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
    }
}
func cString(_ text: String) -> UnsafeMutablePointer<CChar>? { strdup(text) }
func nia_string_free(_ value: UnsafeMutablePointer<CChar>) { free(value) }
@MainActor func nia_sessions(_ h: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? { cString(FFI.sessions()) }
@MainActor func nia_last_error(_ h: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? { cString("write failed") }
@MainActor func nia_workspace_layout(_ h: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? { nil }
@MainActor func nia_window_workspace(_ h: UnsafeMutableRawPointer?, _ id: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    cString(FFI.layouts[String(cString: id)] ?? "")
}
@MainActor func nia_save_window_workspace(_ h: UnsafeMutableRawPointer?, _ id: UnsafePointer<CChar>, _ data: UnsafePointer<CChar>) -> Int32 {
    FFI.layouts[String(cString: id)] = String(cString: data)
    return 0
}
@MainActor func nia_open_session(_ h: UnsafeMutableRawPointer?, _ id: UnsafePointer<CChar>) -> Int32 {
    let name = String(cString: id)
    FFI.opened.append(name)
    FFI.dismissed.remove(name)
    FFI.closed.remove(name)
    return 0
}
@MainActor func nia_reload_sessions(_ h: UnsafeMutableRawPointer?) -> Int32 { 0 }
@MainActor func nia_dismiss_session(_ h: UnsafeMutableRawPointer?, _ id: UnsafePointer<CChar>) -> Int32 {
    guard !FFI.failDismiss else { return -1 }
    FFI.dismissed.insert(String(cString: id))
    return 0
}
'''

MODEL = r'''
@MainActor final class NiaModel {
    var handle: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(bitPattern: 1)
    var windowID: String?
    var tabIDs: [String] = []
    var sessions: [SessionEntry] = []
    var selected: String?
    var secondary: String?
    var splitMode = "off"
    var activePane = 0
    var frames: [String: Int] = [:]
    var revisions: [String: Int] = [:]
    var screenGenerationBySession: [String: Int] = [:]
    var paneSizes: [String: Int] = [:]
    var pendingExitSession: String?
    var error: String?
    var focusSession: String?
    var focusEpoch: UInt64 = 0
    init(_ id: String) { windowID = id; refreshSessions() }
    func prepareScreen(for id: String) {}
'''

HARNESS = r'''
private extension NiaModel { func testRestore() { restoreWorkspace() } }
@main struct WorkspaceTests {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func main() {
        let scenario = CommandLine.arguments[1]
        let model = NiaModel("original")
        if scenario == "synced" {
            FFI.closed = ["left", "right"]
            // Use the same per-session callback as Restore all, including reload.
            for id in ["left", "right", "removed"] { model.activateSynced(id) }
            model.activateSynced("left")
            check(model.tabIDs == ["left", "right", "removed"], "repeating a restored session must not duplicate its tab")
        } else { for id in ["left", "right", "removed"] { model.activate(id) } }
        model.selected = "left"
        model.secondary = "right"
        model.splitMode = "vertical"
        model.activePane = 1
        model.saveWorkspace()
        let stale = FFI.layouts["original"]!
        let waitingWindow = NiaModel("waiting-window")
        FFI.failDismiss = scenario == "failure"
        model.archive("removed")
        if scenario == "failure" {
            check(model.tabIDs.contains("removed"), "a failed durable close must keep the tab visible")
            check(model.error != nil, "persistence failure must be reported")
            return
        }
        check(model.tabIDs == ["left", "right"], "the removed tab must disappear immediately")
        if scenario == "all-removed" {
            model.archive("left")
            model.archive("right")
            model.detachWindow()
            NiaSharedCore.owners = [:]
            let empty = NiaModel("empty-new-scene")
            empty.testRestore()
            check(empty.tabIDs.isEmpty && empty.selected == nil && empty.secondary == nil,
                  "closing the final tab must leave the next launch empty")
            return
        }
        model.detachWindow()
        NiaSharedCore.owners = [:] // A new process has no in-memory ownership.
        FFI.opened = []
        if scenario == "stale" { FFI.layouts["original"] = stale }
        if scenario == "closed" { FFI.closed.insert("left") }
        let restored = scenario == "waiting-window" ? waitingWindow : NiaModel(scenario == "new-scene" ? "new-scene" : "original")
        restored.testRestore()
        check(!restored.tabIDs.contains("removed"), "a removed tab must not reappear after restart (" + scenario + ")")
        check(!FFI.opened.contains("removed"), "restoration must not reopen the removed PTY")
        if scenario == "closed" {
            check(restored.tabIDs == ["right"], "a stale layout must not reopen an exited session")
        } else {
            check(restored.tabIDs == ["left", "right"], "remaining sessions must survive restart")
            if scenario != "new-scene" && scenario != "waiting-window" {
                check(restored.selected == "left" && restored.secondary == "right" && restored.splitMode == "vertical" && restored.activePane == 1,
                      "both split terminals and keyboard focus must survive restart")
            }
        }
        restored.activate("removed")
        check(restored.tabIDs.contains("removed"), "explicit reopen must still work")
        restored.detachWindow()
        NiaSharedCore.owners = [:]
        let reopened = NiaModel("later-scene")
        reopened.testRestore()
        check(reopened.tabIDs.contains("removed"), "explicit reopen must restore automatic restoration")
        print("workspace checks passed")
    }
}
'''


class NativeWorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not compiler:
            raise unittest.SkipTest("Swift compiler unavailable")
        source = SOURCE.read_text()
        types = between(source, "struct SessionEntry:", "struct NiaCommandMark:")
        types += between(source, "private struct WorkspaceLayout:", "@MainActor private enum NiaSharedCore")
        core = "@MainActor private enum NiaSharedCore {\nstatic let handle = UnsafeMutableRawPointer(bitPattern: 1)\nstatic var owners: [String: String] = [:]\n"
        shared = source[source.index("@MainActor private enum NiaSharedCore"):]
        core += between(shared, "    static func string(", "    static func register(")
        core += between(shared, "    static func claim(", "    static func prepareForUpdate(") + "}\n"
        methods = between(source, "    private func resultString(", "    func activateSynced(")
        start = source.index("    func activateSynced(")
        methods += source[start:source.index("\n    func ", start + 10)]
        methods += between(source, "    func refreshSessions()", "    func reconnectRemote(")
        methods += between(source, "    func requestFocus(", "    func archive(")
        # Extract through the next method without rewriting archive's body.
        start = source.index("    func archive(")
        end = source.index("\n    func ", start + 10)
        methods += source[start:end]
        cls.temp = tempfile.TemporaryDirectory(prefix="nia-workspace-tests-")
        cls.addClassCleanup(cls.temp.cleanup)
        path = Path(cls.temp.name)
        harness = path / "WorkspaceTests.swift"
        harness.write_text(STUBS + types + core + MODEL + methods + "}\n" + HARNESS)
        cls.binary = path / "workspace-tests"
        result = subprocess.run([compiler, "-swift-version", "6", "-parse-as-library", str(harness), "-o", str(cls.binary)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_case(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_new_scene_does_not_resurrect_removed_tab(self): self.run_case("new-scene")
    def test_stale_layout_does_not_resurrect_removed_tab(self): self.run_case("stale")
    def test_split_restart_and_explicit_reopen(self): self.run_case("split")
    def test_restored_sessions_keep_both_split_panes_after_restart(self): self.run_case("synced")
    def test_stale_layout_does_not_reopen_exited_session(self): self.run_case("closed")
    def test_failed_close_keeps_tab_visible(self): self.run_case("failure")
    def test_closing_all_tabs_leaves_next_launch_empty(self): self.run_case("all-removed")
    def test_waiting_window_refreshes_metadata_before_restoring(self): self.run_case("waiting-window")


if __name__ == "__main__":
    unittest.main()
