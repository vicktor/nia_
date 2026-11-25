// SPDX-License-Identifier: MPL-2.0
import Foundation

@main struct NiaClaudeUsageTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        checks += 1
    }
    static func fails(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError(message) } catch { checks += 1 }
    }
    static func main() throws {
        let now = Date()
        let reset = now.addingTimeInterval(86400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = formatter.string(from: reset)
        let response: [String: Any] = ["rate_limits_available": true, "rate_limits": [
            "five_hour": ["utilization": 12.5, "resets_at": iso],
            "seven_day": ["utilization": 98, "resets_at": iso],
            "model_scoped": [["display_name": "Fable", "utilization": 100, "resets_at": iso]]]]
        let quota = try NiaUsageSnapshot.claudeAccount(response, now: now)
        check(quota.weekly?.usedPercent == 98, "Account weekly usage must match /usage, not statusLine's 5%")
        check(quota.windows.first { $0.scope == "Fable" }?.usedPercent == 100, "Keep the model limit separate")
        check(Set(quota.windows.map(\.id)).count == 3, "Five-hour, weekly and model windows need distinct IDs")
        check(abs(quota.weekly!.resetsAt!.timeIntervalSince(reset)) < 0.01, "Parse fractional ISO reset timestamps")
        check(quota.tokens == nil, "A quota poll must not invent session token totals")

        let bridge = try NiaUsageSnapshot.claude(JSONSerialization.data(withJSONObject: [
            "updated_at": now.timeIntervalSince1970, "rate_limits": ["seven_day": [
                "used_percentage": 5, "resets_at": reset.timeIntervalSince1970]],
            "input_tokens": 100, "output_tokens": 25]))
        let merged = quota.withClaudeSessionTokens(bridge)
        check(merged.weekly?.usedPercent == 98 && merged.tokens == 125, "A session report must never replace account quota")
        check(merged.windows == quota.windows && merged.updatedAt == now, "Token updates must not refresh or alter quota data")
        let staleQuota = try NiaUsageSnapshot.claudeAccount(response, now: now.addingTimeInterval(-3600))
        check(staleQuota.withClaudeSessionTokens(bridge).stale, "Fresh session tokens must not disguise stale quota")
        check(merged.withClaudeSessionTokens(nil).tokens == nil, "Disconnecting the bridge must clear session tokens")

        let modelOnly = try NiaUsageSnapshot.claudeAccount(["rate_limits_available": true, "rate_limits": [
            "model_scoped": [["display_name": "Fable", "utilization": 100, "resets_at": iso]]]])
        check(modelOnly.weekly == nil, "A model-specific quota must not be presented as the account's weekly quota")
        let unsupported = try NiaUsageSnapshot.claudeAccount(["rate_limits_available": false, "rate_limits": NSNull()])
        check(unsupported.windows.isEmpty, "Unsupported plans must show unavailable, not zero")
        fails("Unavailable server data must not erase the last successful reading") {
            _ = try NiaUsageSnapshot.claudeAccount(["rate_limits_available": true, "rate_limits": NSNull()])
        }
        for bad: Any in [-1, 101, true, "98", Double.infinity] {
            let invalid = try NiaUsageSnapshot.claudeAccount(["rate_limits_available": true, "rate_limits": [
                "seven_day": ["utilization": bad, "resets_at": iso]]])
            check(invalid.weekly == nil, "Reject malformed quota percentages")
        }
        let invalidReset = try NiaUsageSnapshot.claudeAccount(["rate_limits_available": true, "rate_limits": [
            "seven_day": ["utilization": 98, "resets_at": "not-a-date"]]])
        check(invalidReset.weekly == nil, "Malformed reset must not produce an evergreen quota")
        let expired = try NiaUsageSnapshot.claudeAccount(["rate_limits_available": true, "rate_limits": [
            "seven_day": ["utilization": 100, "resets_at": "2020-01-01T00:00:00Z"]]])
        check(expired.weekly == nil, "Expired windows must disappear")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nia-claude-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func fixture(_ name: String, _ body: String) throws -> String {
            let file = directory.appendingPathComponent(name)
            try ("#!/usr/bin/env python3\n" + body).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file.path
        }
        let payload = String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)!
        let good = try fixture("claude", """
        import json, sys
        args = sys.argv[1:]
        for flag in ['--print', '--safe-mode', '--no-session-persistence', '--strict-mcp-config', '--no-chrome']:
            assert flag in args
        assert args[args.index('--tools') + 1] == ''
        assert json.loads(args[args.index('--settings') + 1])['disableAllHooks'] is True
        request = json.loads(sys.stdin.readline())
        assert request['type'] == 'control_request'
        assert request['request'] == {'subtype': 'get_usage', 'skip_behaviors': True}
        response = {'type':'control_response', 'response':{'subtype':'success', 'request_id':request['request_id'], 'response':json.loads(r'''\(payload)''')}}
        # Ignore unrelated protocol messages and support fragmented stdout.
        print(json.dumps({'type':'system', 'subtype':'status'}), flush=True)
        data = json.dumps(response)
        sys.stdout.write(data[:20]); sys.stdout.flush()
        sys.stdout.write(data[20:] + '\\n'); sys.stdout.flush()
        sys.stdin.read()
        """)
        let actual = try NiaClaudeUsage.read(customPath: good)
        check(actual.weekly?.usedPercent == 98, "The process-to-toolbar path must use account data")
        let malformed = try fixture("malformed", "import sys\nsys.stdin.readline()\nprint('{bad json}', flush=True)\n")
        fails("Malformed subprocess output must fail boundedly") { _ = try NiaClaudeUsage.read(customPath: malformed) }
        let denied = try fixture("denied", """
        import json, sys
        r=json.loads(sys.stdin.readline())
        print(json.dumps({'type':'control_response','response':{'request_id':r['request_id'],'subtype':'error','error':'fixture'}}),flush=True)
        """)
        fails("Protocol errors must not appear as zero usage") { _ = try NiaClaudeUsage.read(customPath: denied) }
        let hanging = try fixture("hanging", "import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(60)\n")
        let start = Date()
        fails("A hung CLI must be terminated") { _ = try NiaClaudeUsage.read(customPath: hanging, timeout: 0.2) }
        check(Date().timeIntervalSince(start) < 4, "Hard deadline must reap an unresponsive child")
        fails("Missing executable must be reported") { _ = try NiaClaudeUsage.read(customPath: directory.appendingPathComponent("missing").path) }
        print("Claude usage checks passed: \(checks)")
    }
}
