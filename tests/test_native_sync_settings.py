#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Mount the real Sync settings offscreen to test provider selection lifetime.

Only account/session services are substituted. SwiftUI state and AppStorage are
real, using a private defaults suite; no account, Keychain or session is touched.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
import AppKit
import SwiftUI

enum NiaL10n { static func string(_ key: String) -> String { key } }
enum NiaSyncEngine { static func newKey() -> String { "fixture-key" } }
struct NiaSyncLocal: Identifiable { let id: String; let title: String; let cwd: String }
struct NiaDriveFile: Identifiable { let id: String; let name: String }
@MainActor final class NiaSync: ObservableObject {
    static let shared = NiaSync()
    @Published var connected = false
    @Published var enabled = false
    @Published var busy = false
    @Published var isGoogleDrive = false
    @Published var selected: Set<String> = []
    @Published var local: [NiaSyncLocal] = []
    var locationLabel = "Fixture space"
    var message = ""
    func start() {}
    func refreshCatalog() {}
    func setEnabled(_ value: Bool) { enabled = value }
    func synchronize() {}
    func copyKey() {}
    func disconnect() { connected = false; isGoogleDrive = false }
    func select(_ id: String, _ value: Bool) {}
    func connect(folder: URL, key: String, create: Bool) {}
    func connectGoogle(folder: NiaDriveFile?, name: String, key: String) {}
}
@MainActor final class NiaGoogleDriveAccount: ObservableObject {
    static let shared = NiaGoogleDriveAccount()
    @Published var authorized = false
    var configured = true
    var busy = false
    var message = ""
    var spaces: [NiaDriveFile] = []
    func connect() {}
    func cancel() {}
    func disconnect() { authorized = false }
    func refresh() {}
}

__SETTINGS__

__GOOGLE_SETUP__

@MainActor final class ProviderProbe {
    static var current = ProviderProbe()
    var read: (() -> String)?
    var select: ((String) -> Void)?
}
struct ProviderInspection: View {
    let value: String
    let select: (String) -> Void
    let probe = ProviderProbe.current
    var body: some View {
        Color.clear.onAppear(perform: record).onChange(of: value) { _, _ in record() }
    }
    private func record() {
        probe.read = { value }
        probe.select = select
    }
}

@main struct SyncSettingsTests {
    @MainActor static func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
    }
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func mount(_ defaults: UserDefaults) -> (NSWindow, ProviderProbe) {
        let probe = ProviderProbe()
        ProviderProbe.current = probe
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: NiaSyncSettings().defaultAppStorage(defaults))
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        check(probe.read != nil && probe.select != nil, "the real settings view must be mounted")
        return (window, probe)
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments[1], suite = CommandLine.arguments[2]
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.synchronize() }
        if mode == "cleanup" { defaults.removePersistentDomain(forName: suite); return }
        if mode == "remember" {
            let (window, first) = mount(defaults)
            check(first.read?() == "folder", "a new installation defaults to folder sync")
            first.select?("googleDrive"); settle()
            check(first.read?() == "googleDrive", "selecting Google Drive changes the form")
            window.contentView = nil; settle()
            let (reopened, next) = mount(defaults)
            check(next.read?() == "googleDrive", "reopening settings must remember Google Drive")
            reopened.contentView = nil
        } else if mode == "relaunch" {
            let (window, probe) = mount(defaults)
            check(probe.read?() == "googleDrive", "a fresh process must remember Google Drive")
            // An explicit folder choice must win over an already linked account.
            NiaGoogleDriveAccount.shared.authorized = true
            probe.select?("folder"); settle()
            window.contentView = nil; settle()
            let (reopened, next) = mount(defaults)
            check(next.read?() == "folder", "explicit folder selection survives reopening with Google linked")
            // An active space determines the displayed service and help text.
            NiaSync.shared.isGoogleDrive = true; NiaSync.shared.connected = true; settle()
            check(next.read?() == "googleDrive", "the active Google space takes precedence")
            NiaSync.shared.isGoogleDrive = false; settle()
            check(next.read?() == "folder", "an active folder space takes precedence over Google authorization")
            reopened.contentView = nil
        } else if mode == "migration" {
            defaults.removePersistentDomain(forName: suite)
            NiaGoogleDriveAccount.shared.authorized = true
            let (window, probe) = mount(defaults)
            check(probe.read?() == "googleDrive", "existing linked accounts open Google setup without a saved selection")
            window.contentView = nil; settle()
            defaults.set("unknown-provider", forKey: "nia.sync.setup.provider")
            let (reopened, next) = mount(defaults)
            check(next.read?() == "googleDrive", "unknown saved selections fall back to the linked account")
            reopened.contentView = nil
        } else { fatalError("Unknown test mode") }
        print("Sync settings \(mode): passed")
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "Requires AppKit and SwiftUI")
class NativeSyncSettingsTests(unittest.TestCase):
    def test_provider_survives_view_and_process_recreation(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("Swift compiler unavailable")
        source = (ROOT / "native/Sources/NiaSync.swift").read_text()
        start = source.index("struct NiaSyncSettings: View {")
        settings = source[start:source.index("\nstruct NiaSyncBrowser:", start)]
        # Observe the installed view's state inside body. An outer modifier
        # would capture an uninstalled copy of @State and test the wrong thing.
        appearance = "}.onAppear { sync.start(); sync.refreshCatalog() }"
        self.assertEqual(settings.count(appearance), 1)
        settings = settings.replace(appearance, appearance +
            "\n.background(ProviderInspection(value: provider, select: { provider = $0 }))")
        source = (ROOT / "native/Sources/NiaGoogleDriveView.swift").read_text()
        setup = source[source.index("struct NiaGoogleDriveSetup: View {"):]
        suite = "dev.nia.tests.sync-settings." + uuid.uuid4().hex
        with tempfile.TemporaryDirectory(prefix="nia-sync-settings-tests-") as directory:
            path = Path(directory)
            harness = path / "SyncSettingsTests.swift"
            harness.write_text(HARNESS.replace("__SETTINGS__", settings).replace("__GOOGLE_SETUP__", setup))
            binary = path / "sync-settings-tests"
            build = subprocess.run([compiler, "-parse-as-library", str(harness), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=90)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            try:
                for mode in ["remember", "relaunch", "migration"]:
                    result = subprocess.run([str(binary), mode, suite], capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            finally:
                subprocess.run([str(binary), "cleanup", suite], check=True, capture_output=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
