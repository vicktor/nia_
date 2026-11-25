#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Check the real usage monitor with a local CLI fixture and session snapshot."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
import Foundation
import SwiftUI

enum NiaL10n { static func string(_ key: String) -> String { key } }

__MONITOR__

@main struct UsageMonitorTests {
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func finish(_ monitor: NiaUsageMonitor) async throws {
        let deadline = Date().addingTimeInterval(5)
        while monitor.refreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        check(!monitor.refreshing, "monitor must finish without blocking the main actor")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let bridge = root.appendingPathComponent("bridge.json")
        let cli = root.appendingPathComponent("claude")
        let response = root.appendingPathComponent("response.json")
        let reset = Date().addingTimeInterval(86400)
        let iso = ISO8601DateFormatter().string(from: reset)
        func bridgeData(_ tokens: Int) throws {
            try JSONSerialization.data(withJSONObject: ["updated_at": Date().timeIntervalSince1970,
                "input_tokens": tokens, "output_tokens": 1,
                "rate_limits": ["seven_day": ["used_percentage": 5, "resets_at": reset.timeIntervalSince1970]]])
                .write(to: bridge, options: .atomic)
        }
        try JSONSerialization.data(withJSONObject: ["rate_limits_available": true, "rate_limits": [
            "seven_day": ["utilization": 98, "resets_at": iso],
            "model_scoped": [["display_name": "Fable", "utilization": 100, "resets_at": iso]]]])
            .write(to: response)
        try bridgeData(100)
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(["nia.usage.enabled": true, "nia.usage.codex": false,
            "nia.usage.claude": true, "nia.usage.claudePath": cli.path], forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let monitor = NiaUsageMonitor(claudeSnapshotURL: bridge)
        monitor.refresh()
        try await finish(monitor)
        check(monitor.claude?.weekly?.usedPercent == 98, "toolbar must use /usage's 98%, not bridge's 5%")
        check(monitor.claude?.tokens == 101, "optional session tokens must remain available")
        check(monitor.claude?.windows.first { $0.scope == "Fable" }?.usedPercent == 100,
              "popover must retain the separate Fable limit")
        let stamp = monitor.claude?.updatedAt
        try bridgeData(200)
        monitor.refresh()
        try await finish(monitor)
        check(monitor.claude?.weekly?.usedPercent == 98 && monitor.claude?.tokens == 201,
              "a newer bridge report must never overwrite account quota")
        check(monitor.claude?.updatedAt == stamp, "session updates must not change the quota timestamp")
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        check(calls.split(separator: "\n").count == 1, "ordinary polling must respect the five-minute CLI cadence")
        try "{}".write(to: response, atomically: true, encoding: .utf8)
        monitor.refresh(force: true)
        try await finish(monitor)
        check(monitor.claudeError != nil && monitor.claude?.weekly?.usedPercent == 98,
              "CLI failures must retain the previous reading and show an error, never fall back to 5%")
        try FileManager.default.removeItem(at: bridge)
        monitor.refresh()
        try await finish(monitor)
        check(monitor.claude?.tokens == nil && monitor.claude?.weekly?.usedPercent == 98,
              "disconnecting session tokens must not remove account quota")
        check(monitor.claudeError != nil, "session refresh must not clear an account query error")
        print("Usage monitor regression checks passed")
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS SwiftUI")
class NativeUsageTests(unittest.TestCase):
    def test_account_quota_cannot_be_overwritten_by_session_reports(self):
        compiler = shutil.which("swiftc")
        if not compiler:
            self.skipTest("Swift compiler unavailable")
        source = (ROOT / "native/Sources/NiaUsageView.swift").read_text()
        monitor = source[source.index("@MainActor final class NiaUsageMonitor"):source.index("\nstruct NiaUsageToolbar:")]
        with tempfile.TemporaryDirectory(prefix="nia-usage-monitor-tests-") as directory:
            path = Path(directory)
            cli = path / "claude"
            cli.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
root = pathlib.Path(__file__).parent
request = json.loads(sys.stdin.readline())
assert request['type'] == 'control_request'
assert request['request'] == {'subtype': 'get_usage', 'skip_behaviors': True}
with (root/'calls').open('a') as log: log.write('usage\\n')
print(json.dumps({'type':'control_response','response':{'request_id':request['request_id'],
 'subtype':'success','response':json.loads((root/'response.json').read_text())}}), flush=True)
sys.stdin.read()
''')
            cli.chmod(0o700)
            harness = path / "UsageMonitorTests.swift"
            harness.write_text(HARNESS.replace("__MONITOR__", monitor))
            binary = path / "usage-monitor-tests"
            sources = ["NiaUsageModels.swift", "NiaClaudeUsage.swift", "NiaCodexUsage.swift"]
            build = subprocess.run([compiler, "-parse-as-library", str(harness),
                *[str(ROOT / "native/Sources" / name) for name in sources], "-o", str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(binary), directory], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
