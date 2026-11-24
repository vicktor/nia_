// SPDX-License-Identifier: MPL-2.0
// swiftc native/Sources/NiaWindowPlacement.swift native/Tests/NiaWindowPlacementTests.swift -o /tmp/nia-window-placement-tests
// /tmp/nia-window-placement-tests
import AppKit

private final class PlacementTestWindow: NSWindow {
    var simulateFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { simulateFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
}

@main
@MainActor
struct NiaWindowPlacementTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }
    static func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

    static func main() throws {
        if CommandLine.arguments.count == 3 {
            try windowPhase(CommandLine.arguments[1], suite: CommandLine.arguments[2])
            return
        }
        let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let minimum = CGSize(width: 720, height: 450)
        let normal = NiaWindowPlacement(frame: CGRect(x: 150, y: 120, width: 1000, height: 650))
        check(normal.fitted(to: [main], minimumSize: minimum) == normal.frame, "Restore exact position and dimensions")
        let external = NiaWindowPlacement(frame: CGRect(x: -1800, y: 100, width: 1200, height: 800))
        check(external.fitted(to: [main, left], minimumSize: minimum) == external.frame, "Keep negative coordinates on a connected monitor")
        let recovered = external.fitted(to: [main], minimumSize: minimum)!
        check(main.contains(recovered), "A disconnected monitor cannot hide the window")
        check(recovered.size == external.frame.size, "Keep size when the replacement screen has room")
        let huge = NiaWindowPlacement(frame: CGRect(x: 0, y: 0, width: 3000, height: 2000))
        check(huge.fitted(to: [main], minimumSize: minimum) == main, "Fit oversized frames below menu bar and above Dock")
        let tiny = NiaWindowPlacement(frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        check(tiny.fitted(to: [main], minimumSize: minimum)?.size == minimum, "Respect the terminal's minimum size")
        check(normal.fitted(to: [], minimumSize: minimum) == nil, "Wait when no display is available")
        check(!NiaWindowPlacement(frame: .zero).isValid, "Reject empty frames")
        check(!NiaWindowPlacement(frame: CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 600)).isValid, "Reject nonfinite coordinates")
        let suite = "dev.nia.window-placement-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NiaWindowPlacementStore(defaults: defaults)
        defaults.set(Data("broken".utf8), forKey: "nia.window.placement.corrupt")
        check(store.placement(for: "corrupt") == nil, "Ignore corrupt preferences")
        store.save(normal, for: "one")
        store.save(external, for: "two")
        check(store.placement(for: "one") == normal, "Each window retains its own placement")
        check(store.lastPlacement == external, "Remember the last frame for a fresh scene ID")
        store.save(NiaWindowPlacement(frame: .zero), for: "two")
        check(store.placement(for: "two") == external, "An invalid frame cannot overwrite a saved one")

        // Separate processes verify UserDefaults persistence across a restart,
        // with two actual AppKit windows, without touching the user's app/data.
        for phase in ["write", "read"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [phase, suite]
            try process.run()
            process.waitUntilExit()
            check(process.terminationStatus == 0, "Window \(phase) process passed")
        }
        print("Nia window placement: \(checks) geometry/persistence checks passed; AppKit restart checks passed")
    }

    static func windowPhase(_ phase: String, suite: String) throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: suite)!
        let store = NiaWindowPlacementStore(defaults: defaults)
        func makeWindow() -> PlacementTestWindow {
            let window = PlacementTestWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 740),
                                  styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        let first = makeWindow(), second = makeWindow()
        let a = NiaWindowPlacementController(store: store), b = NiaWindowPlacementController(store: store)
        a.attach(to: first, id: "window-a")
        b.attach(to: second, id: "window-b")
        settle()
        if phase == "write" {
            let screen = NSScreen.main!.visibleFrame
            let frameA = CGRect(x: screen.minX + 50, y: screen.minY + 50, width: 900, height: 550)
            let frameB = CGRect(x: screen.minX + 90, y: screen.minY + 90, width: 800, height: 500)
            first.setFrame(frameA, display: false)
            second.setFrame(frameB, display: false)
            check(store.placement(for: "window-a")?.frame == frameA, "Save a resized/moved AppKit window automatically")
            check(store.placement(for: "window-b")?.frame == frameB, "Second window writes independently")
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: first)
            first.setFrame(screen, display: false)
            check(store.placement(for: "window-a")?.frame == frameA, "Full-screen animation must not replace the normal frame")
            first.simulateFullScreen = true
            NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: first)
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
            check(store.placement(for: "window-a")?.frame == frameA, "Ignore resize events while full screen")
            NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: first)
            first.simulateFullScreen = false
            first.setFrame(frameA, display: false)
            NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: first)
            a.attach(to: first, id: "window-a")
            settle()
            check(first.frame == frameA, "SwiftUI updates do not reapply an old position")
            first.close()
            second.close()
            a.detach(); b.detach()
            check(defaults.synchronize(), "Flush the isolated test suite before process exit")
        } else {
            check(first.frame == store.placement(for: "window-a")?.frame, "First window restores after process restart")
            check(second.frame == store.placement(for: "window-b")?.frame, "Second window restores after process restart")
            check(first.frame != second.frame, "Independent frames remain distinct after restart")
            let fallback = store.lastPlacement!.frame
            let fresh = makeWindow()
            let c = NiaWindowPlacementController(store: store)
            c.attach(to: fresh, id: "new-scene-after-restart")
            settle()
            check(fresh.frame == fallback, "A new scene ID restores the last placement")
            a.detach(); b.detach(); c.detach()
            first.close(); second.close(); fresh.close()
        }
        print("AppKit \(phase): \(checks) checks passed")
    }
}
