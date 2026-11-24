#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Run the actual native refresh coordinator with Foundation and stubbed FFI.

The Swift blocks are extracted unchanged from NiaApp.swift. AppKit presentation,
the Rust FFI and the monotonic clock are replaced; Timer, RunLoop and notifications
are real. This exercises scheduling/ownership on Linux without claiming a macOS
UI or Metal test. Set SWIFTC if the Swift compiler is not on PATH.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "native/Sources/NiaApp.swift"


def between(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


STUBS = r'''
import Foundation

enum NSApplication {
    static let willTerminateNotification = Notification.Name("NiaHarnessWillTerminate")
}
enum NiaL10n {
    static func string(_ value: String) -> String { value }
}
enum NiaUpdateError: Error { case history }
@MainActor final class ProcessInfo {
    static let processInfo = ProcessInfo()
    var systemUptime = 0.0
}
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var confirmExit = true
    func object(forKey key: String) -> Any? {
        key == "nia.confirmExit" ? confirmExit : nil
    }
}
@MainActor enum FFI {
    static var creations = 0
    static var polls = 0
    static var maintenance = 0
    static var sessionReads = 0
    static var exitReads = 0
    static var aiReads = 0
    static var flushes = 0
    static var freedStrings = 0
    static var maintainResult: Int32 = 0
    static var sessionsJSON = "[]"
    static var exitsJSON = "[]"
    static var aiJSON = "[]"
    static var error = "disk unavailable"
    static var confirmed: [String] = []
}
func cString(_ text: String) -> UnsafeMutablePointer<CChar> {
    let bytes = text.utf8CString
    let result = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    bytes.withUnsafeBufferPointer { result.initialize(from: $0.baseAddress!, count: $0.count) }
    return result
}
@MainActor func nia_core_new() -> UnsafeMutableRawPointer? {
    FFI.creations += 1
    return UnsafeMutableRawPointer(bitPattern: 1)
}
@MainActor func nia_poll(_ handle: UnsafeMutableRawPointer) { FFI.polls += 1 }
@MainActor func nia_maintain(_ handle: UnsafeMutableRawPointer) -> Int32 {
    FFI.maintenance += 1
    return FFI.maintainResult
}
@MainActor func nia_sessions(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? {
    FFI.sessionReads += 1
    return cString(FFI.sessionsJSON)
}
@MainActor func nia_take_exit_requests(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? {
    FFI.exitReads += 1
    defer { FFI.exitsJSON = "[]" }
    return cString(FFI.exitsJSON)
}
@MainActor func nia_take_ai_queries(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? {
    FFI.aiReads += 1
    defer { FFI.aiJSON = "[]" }
    return cString(FFI.aiJSON)
}
@MainActor func nia_last_error(_ handle: UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>? {
    cString(FFI.error)
}
@MainActor func nia_string_free(_ pointer: UnsafeMutablePointer<CChar>) {
    FFI.freedStrings += 1
    pointer.deallocate()
}
@MainActor func nia_flush_pending(_ handle: UnsafeMutableRawPointer) -> Int32 {
    FFI.flushes += 1
    return 0
}
@MainActor func nia_confirm_exit(_ handle: UnsafeMutableRawPointer, _ id: UnsafePointer<CChar>) -> Int32 {
    FFI.confirmed.append(String(cString: id))
    return 0
}
'''

MODEL_PREFIX = r'''
@MainActor final class NiaModel {
    var handle: UnsafeMutableRawPointer? = NiaSharedCore.handle
    var windowID: String? = "test-window"
    var selected: String?
    var secondary: String?
    var splitMode = "off"
    var tabIDs: [String] = []
    var sessions: [SessionEntry] = [] { didSet { sessionWrites += 1 } }
    var error: String? { didSet { errorWrites += 1 } }
    var pendingExitSession: String?
    var pendingAIRequests: [NiaAIQuery] = []
    var aiRequest: NiaAIQuery?
    var sessionWrites = 0
    var errorWrites = 0
    var screens: [String] = []
    var archived: [String] = []

    init(_ selected: String) {
        self.selected = selected
        tabIDs = [selected]
    }
    func refreshScreen(for id: String) { screens.append(id) }
    func archive(_ id: String) {
        archived.append(id)
        tabIDs.removeAll { $0 == id }
    }
    func report(_ result: Int32) -> Bool { result == 0 }
    func saveWorkspace() -> Bool { true }
'''

HARNESS = r'''
private extension NiaSharedCore {
    static func testPump() { pump() }
    static var testTimer: Timer? { timer }
    static var testModelCount: Int { models.count }
}

@main struct RefreshTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    @MainActor static func tick(_ time: Double) {
        ProcessInfo.processInfo.systemUptime = time
        NiaSharedCore.testPump()
    }
    static func session(_ id: String, closed: Bool = false) -> SessionEntry {
        SessionEntry(id: id, display_name: id, cwd: "/tmp/nia-test", closed: closed,
                     venv: nil, color: "blue", remote_host: nil)
    }
    @MainActor static func cadence() {
        FFI.sessionsJSON = """
        [{"id":"a","display_name":"a","cwd":"/tmp/nia-test","closed":false,"color":"blue"}]
        """
        let first = NiaModel("a")
        first.secondary = "b"
        first.splitMode = "vertical"
        let second = NiaModel("c")
        NiaSharedCore.register(first)
        let timer = NiaSharedCore.testTimer!
        NiaSharedCore.register(second)
        check(NiaSharedCore.testTimer === timer, "a second window must reuse the process timer")
        check(timer.timeInterval == 1.0 / 60.0, "the presentation clock must be 60 Hz")
        for frame in 0..<30 { tick(Double(frame) / 60.0) }
        check(FFI.creations == 1, "all windows must share one core")
        check(FFI.polls == 30, "one poll per tick, irrespective of model count")
        check(first.screens.count == 60 && second.screens.count == 30,
              "each live pane must receive each poll result")
        check(FFI.maintenance == 1 && FFI.sessionReads == 1,
              "metadata must not be fetched for every presentation frame")
        tick(0.5)
        check(FFI.polls == 31 && FFI.maintenance == 2, "maintenance is due at 500 ms")
        check(FFI.sessionReads == 2 && FFI.exitReads == 2 && FFI.aiReads == 2,
              "metadata and request queues share the slower cadence")
        check(first.sessionWrites == 1 && second.sessionWrites == 1,
              "unchanged session metadata must not republish either model")
        check(FFI.freedStrings == 6, "every metadata string returned by the FFI must be freed")
    }
    @MainActor static func visiblePanes() {
        let model = NiaModel("a")
        model.secondary = "b"
        model.refreshAfterPoll(maintenance: false, sessions: [session("new")], backgroundError: nil)
        check(model.screens == ["a"], "a hidden split must not refresh its secondary pane")
        check(model.sessionWrites == 0, "fast refresh must not publish metadata")
        model.splitMode = "vertical"
        model.secondary = "a"
        model.screens = []
        model.refreshAfterPoll(maintenance: false, sessions: nil, backgroundError: nil)
        check(model.screens == ["a"], "the same session must not be fetched twice in one model")
        model.secondary = "b"
        model.screens = []
        model.refreshAfterPoll(maintenance: false, sessions: nil, backgroundError: nil)
        check(model.screens == ["a", "b"], "both distinct visible panes must refresh")
        model.windowID = nil
        model.screens = []
        model.refreshAfterPoll(maintenance: true, sessions: [session("new")], backgroundError: "error")
        check(model.screens.isEmpty && model.sessionWrites == 0 && model.error == nil,
              "a detached window must not publish refresh state")
    }
    @MainActor static func requestOwnership() {
        FFI.exitsJSON = #"["a","b","c","unowned"]"#
        FFI.aiJSON = """
        [{"session_id":"a","question":"one"},{"session_id":"a","question":"two"},
         {"session_id":"c","question":"other window"},{"session_id":"unowned","question":"later"}]
        """
        let first = NiaModel("a")
        first.tabIDs = ["a", "b"]
        let second = NiaModel("c")
        NiaSharedCore.register(first)
        NiaSharedCore.register(second)
        tick(0)
        check(first.pendingExitSession == "a" && second.pendingExitSession == "c",
              "exit prompts must go to the window owning the tab")
        check(NiaSharedCore.exitQueue.sorted() == ["b", "unowned"],
              "additional and unowned exit requests must wait without being discarded")
        check(first.aiRequest?.question == "one" && second.aiRequest?.question == "other window",
              "AI requests must route to the owning window")
        check(first.pendingAIRequests.map(\.question) == ["two"], "additional requests remain queued")
        check(NiaSharedCore.aiQueue.map(\.session_id) == ["unowned"], "unowned AI requests remain available")
        tick(0.5)
        check(first.pendingAIRequests.map(\.question) == ["two"], "maintenance must not replay AI requests")
        check(NiaSharedCore.exitQueue.sorted() == ["b", "unowned"], "waiting exit requests must not duplicate")
        first.aiRequest = nil
        first.showNextAIRequest()
        check(first.aiRequest?.question == "two" && first.pendingAIRequests.isEmpty,
              "completed AI presentation advances exactly once")
        UserDefaults.standard.confirmExit = false
        tick(1)
        check(FFI.confirmed == ["b"], "automatic exit confirmation must use the owning session")
        tick(1.5)
        check(FFI.confirmed == ["b"], "a consumed exit request must not be replayed")
    }
    @MainActor static func maintenanceError() {
        let model = NiaModel("a")
        model.sessions = [session("a")]
        model.sessionWrites = 0
        FFI.sessionsJSON = "invalid JSON"
        FFI.maintainResult = 1
        NiaSharedCore.register(model)
        tick(0)
        check(model.error == "disk unavailable" && model.errorWrites == 1,
              "a background persistence error must be surfaced")
        check(model.sessions.map(\.id) == ["a"] && model.sessionWrites == 0,
              "malformed metadata must not erase existing sessions")
        tick(0.25)
        tick(0.5)
        check(model.errorWrites == 1, "an unchanged background error must not republish at frame rate")
        FFI.error = "different error"
        tick(1)
        check(model.errorWrites == 2 && model.error == "different error", "a changed error must be published")
        model.error = nil // Dismiss the alert while the underlying failure persists.
        tick(1.5)
        check(model.error == nil && model.errorWrites == 3,
              "a dismissed persistent error must not reopen every maintenance tick")
        FFI.maintainResult = 0
        tick(2)
        FFI.maintainResult = 1
        tick(2.5)
        check(model.error == "different error" && model.errorWrites == 4,
              "the same failure after recovery must be reported again")
        check(model.screens.count == 7, "visible output must continue even when maintenance fails")
    }
    @MainActor static func closedSessions() {
        let model = NiaModel("a")
        model.tabIDs = ["a", "b"]
        let entries = [session("a", closed: true), session("b")]
        model.refreshAfterPoll(maintenance: true, sessions: entries, backgroundError: nil)
        check(model.archived == ["a"] && model.tabIDs == ["b"], "closed local sessions must leave their owning tabs")
        model.refreshAfterPoll(maintenance: true, sessions: entries, backgroundError: nil)
        check(model.archived == ["a"], "closed sessions must not be archived repeatedly")
        check(model.sessionWrites == 1, "stable metadata must not republish during archive maintenance")
    }
    @MainActor static func weakModels() {
        var first: NiaModel? = NiaModel("a")
        var second: NiaModel? = NiaModel("b")
        weak var weakFirst = first
        weak var weakSecond = second
        NiaSharedCore.register(first!)
        NiaSharedCore.register(second!)
        let oldTimer = NiaSharedCore.testTimer!
        first = nil
        tick(0)
        check(weakFirst == nil && NiaSharedCore.testModelCount == 1, "the coordinator must not retain closed windows")
        check(FFI.polls == 1 && second!.screens.count == 1, "remaining windows must keep receiving output")
        second = nil
        tick(0.1)
        check(weakSecond == nil && NiaSharedCore.testModelCount == 0, "all dead models must be pruned")
        check(FFI.polls == 1 && NiaSharedCore.testTimer == nil && !oldTimer.isValid,
              "the process timer must stop when there are no models")
        let next = NiaModel("c")
        NiaSharedCore.register(next)
        check(NiaSharedCore.testTimer != nil && NiaSharedCore.testTimer !== oldTimer,
              "opening a later window must restart a single timer")
        tick(0.2)
        check(FFI.polls == 2 && next.screens == ["c"], "a restarted timer must refresh the new model")
    }
    @MainActor static func termination() {
        let model = NiaModel("a")
        NiaSharedCore.register(model)
        let timer = NiaSharedCore.testTimer!
        tick(0)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        check(FFI.flushes == 1 && NiaSharedCore.testTimer == nil && !timer.isValid,
              "termination must stop presentation and flush pending history")
        tick(1)
        check(FFI.polls == 1 && FFI.maintenance == 1, "no core work may continue after termination")
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        check(FFI.flushes == 1, "termination notification must be idempotent")
        let late = NiaModel("b")
        NiaSharedCore.register(late)
        check(NiaSharedCore.testTimer == nil, "late registration must not restart a terminating process")
    }
    @MainActor static func foundationTimer() {
        let model = NiaModel("a")
        NiaSharedCore.register(model)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        check(FFI.polls > 0, "the real Foundation main run loop must drive the registered timer")
        check(model.screens.count == FFI.polls, "each timer callback must run once on the main actor")
        check(FFI.maintenance == 1, "timer callbacks must still honor the monotonic maintenance clock")
    }
    @MainActor static func main() {
        switch CommandLine.arguments[1] {
        case "cadence": cadence()
        case "panes": visiblePanes()
        case "ownership": requestOwnership()
        case "errors": maintenanceError()
        case "closed": closedSessions()
        case "weak": weakModels()
        case "termination": termination()
        case "timer": foundationTimer()
        default: preconditionFailure("unknown test")
        }
        print("\(checks) refresh checks passed")
    }
}
'''


class NativeRefreshTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = os.environ.get("SWIFTC") or shutil.which("swiftc")
        if not compiler:
            raise unittest.SkipTest("Swift compiler unavailable; set SWIFTC to run native coordinator tests")
        source = SOURCE.read_text()
        coordinator = between(source, "@MainActor private enum NiaSharedCore {", "private struct NiaWindowModelKey:")
        sessions = between(source, "struct SessionEntry:", "struct NiaCommandMark:")
        queries = between(source, "struct NiaAIQuery:", "/// Persisted together")
        refresh = between(source, "    func showNextAIRequest() {", "\n}\n\nprivate struct NiaWindowRoot:")
        cls.temp = tempfile.TemporaryDirectory(prefix="nia-refresh-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        path = Path(cls.temp.name)
        harness = path / "RefreshTests.swift"
        harness.write_text(STUBS + sessions + queries + coordinator + MODEL_PREFIX + refresh + "\n}\n" + HARNESS)
        cls.binary = path / "refresh-tests"
        compiled = subprocess.run(
            [compiler, "-swift-version", "6", "-parse-as-library", str(harness), "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=60,
        )
        if compiled.returncode:
            raise AssertionError("Actual coordinator failed Swift typechecking:\n" + compiled.stdout + compiled.stderr)

    def run_case(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("refresh checks passed", result.stdout)

    def test_one_process_clock_and_500ms_metadata(self):
        self.run_case("cadence")

    def test_only_distinct_visible_panes_refresh(self):
        self.run_case("panes")

    def test_request_ownership_without_replay(self):
        self.run_case("ownership")

    def test_maintenance_error_does_not_block_output(self):
        self.run_case("errors")

    def test_closed_sessions_are_archived_once(self):
        self.run_case("closed")

    def test_weak_model_pruning_stops_and_restarts_timer(self):
        self.run_case("weak")

    def test_shutdown_flushes_once(self):
        self.run_case("termination")

    def test_real_foundation_timer_and_main_actor_callback(self):
        self.run_case("timer")


if __name__ == "__main__":
    unittest.main()
