// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation

struct NiaQuotaWindow: Equatable, Sendable, Identifiable {
    let minutes: Int
    let usedPercent: Double
    let resetsAt: Date?
    var scope: String? = nil
    var id: String { "\(minutes):\(scope ?? "all")" }
    func isCurrent(at now: Date = Date()) -> Bool { resetsAt.map { $0 > now } ?? true }
}

struct NiaUsageSnapshot: Equatable, Sendable {
    let windows: [NiaQuotaWindow]
    let tokens: Int64?
    let tokenLabel: String
    let updatedAt: Date
    var weekly: NiaQuotaWindow? { windows.first { $0.minutes == 10080 && $0.scope == nil && $0.isCurrent() } }
    var stale: Bool { Date().timeIntervalSince(updatedAt) > 900 }

    static func window(_ value: Any?, minutes: Int?, percentKey: String, resetKey: String) -> NiaQuotaWindow? {
        guard let object = value as? [String: Any], let minutes, minutes > 0,
              let used = object[percentKey] as? Double, used.isFinite, (0...100).contains(used) else { return nil }
        let reset = (object[resetKey] as? Double).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return NiaQuotaWindow(minutes: minutes, usedPercent: used, resetsAt: reset)
    }

    static func codex(limits: [String: Any], usage: [String: Any]?, now: Date = Date()) -> Self {
        let buckets = limits["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any]) ?? (limits["rateLimits"] as? [String: Any]) ?? [:]
        let windows = ["primary", "secondary"].compactMap { key -> NiaQuotaWindow? in
            let value = bucket[key] as? [String: Any]
            let minutes = (value?["windowDurationMins"] as? NSNumber).flatMap { Int(exactly: $0.doubleValue) }
            return window(value, minutes: minutes, percentKey: "usedPercent", resetKey: "resetsAt")
        }
        let tokens = ((usage?["summary"] as? [String: Any])?["lifetimeTokens"] as? NSNumber)?.int64Value
        return Self(windows: windows, tokens: tokens.flatMap { $0 >= 0 ? $0 : nil },
                    tokenLabel: "Tokens acumulados (cuenta)", updatedAt: now)
    }

    static func claude(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = object["updated_at"] as? Double, updated.isFinite, updated > 0,
              updated <= Date().timeIntervalSince1970 + 60 else { throw NiaUsageError.unavailable }
        let limits = object["rate_limits"] as? [String: Any] ?? [:]
        let windows = [window(limits["five_hour"], minutes: 300, percentKey: "used_percentage", resetKey: "resets_at"),
                       window(limits["seven_day"], minutes: 10080, percentKey: "used_percentage", resetKey: "resets_at")].compactMap { $0 }
        var tokens: Int64?
        if let input = (object["input_tokens"] as? NSNumber)?.int64Value,
           let output = (object["output_tokens"] as? NSNumber)?.int64Value,
           input >= 0, output >= 0 {
            let sum = input.addingReportingOverflow(output)
            if !sum.overflow { tokens = sum.partialValue }
        }
        return Self(windows: windows, tokens: tokens, tokenLabel: "Tokens de la última sesión conectada",
                    updatedAt: Date(timeIntervalSince1970: updated))
    }

    // get_usage is the account source used by Claude's /usage screen. The
    // status-line header snapshot can disagree even when it was just written.
    static func claudeAccount(_ response: [String: Any], now: Date = Date()) throws -> Self {
        guard let available = response["rate_limits_available"] as? Bool else { throw NiaUsageError.claudeFailed }
        guard !available || response["rate_limits"] is [String: Any] else { throw NiaUsageError.claudeFailed }
        let limits = available ? (response["rate_limits"] as? [String: Any] ?? [:]) : [:]
        let dates = ISO8601DateFormatter()
        func window(_ value: Any?, minutes: Int, scope: String? = nil) -> NiaQuotaWindow? {
            guard let object = value as? [String: Any],
                  let number = object["utilization"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...100).contains(number.doubleValue),
                  let timestamp = object["resets_at"] as? String else { return nil }
            dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var reset = dates.date(from: timestamp)
            if reset == nil {
                dates.formatOptions = [.withInternetDateTime]
                reset = dates.date(from: timestamp)
            }
            guard let reset, reset.timeIntervalSince1970 > 0 else { return nil }
            return NiaQuotaWindow(minutes: minutes, usedPercent: number.doubleValue, resetsAt: reset, scope: scope)
        }
        var windows = [window(limits["five_hour"], minutes: 300),
                       window(limits["seven_day"], minutes: 10080)].compactMap { $0 }
        for model in (limits["model_scoped"] as? [[String: Any]] ?? []).prefix(32) {
            guard let name = model["display_name"] as? String,
                  !name.isEmpty, name.count <= 80,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !windows.contains(where: { $0.scope == name }),
                  let value = window(model, minutes: 10080, scope: name) else { continue }
            windows.append(value)
        }
        // Older CLI responses provide these model windows separately.
        for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            if !windows.contains(where: { $0.scope == name }),
               let value = window(limits[key], minutes: 10080, scope: name) { windows.append(value) }
        }
        return Self(windows: windows, tokens: nil, tokenLabel: "Tokens de la última sesión conectada", updatedAt: now)
    }

    func withClaudeSessionTokens(_ session: Self?) -> Self {
        // Session reports must never replace account quotas or make them look fresh.
        Self(windows: windows, tokens: session?.tokens,
             tokenLabel: "Tokens de la última sesión conectada", updatedAt: updatedAt)
    }
}

enum NiaUsageError: String, Error, LocalizedError {
    case unavailable = "No hay datos de consumo disponibles."
    case codexMissing = "No se encuentra Codex CLI. Selecciona su ejecutable en Preferencias → IA."
    case codexFailed = "No se pudo consultar Codex. Comprueba su sesión iniciada y la conexión."
    case claudeMissing = "No se encuentra Claude Code CLI. Selecciona su ejecutable en Preferencias → IA."
    case claudeFailed = "No se pudo consultar Claude Code. Actualiza su CLI y comprueba su sesión iniciada y la conexión."
    case settingsChanged = "La configuración de Claude ha cambiado. Se ha conservado sin sobrescribirla."
    case settingsInvalid = "No se pudo leer la configuración de Claude Code."
    var errorDescription: String? { rawValue }
}

enum NiaUsagePaths {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ember-terminal/usage", isDirectory: true)
    }
    static var claudeSnapshot: URL { directory.appendingPathComponent("claude-usage.json") }
    static var claudeSettings: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("settings.json").resolvingSymlinksInPath()
    }
}

enum NiaClaudeConnection {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func isConnected(settings: URL = NiaUsagePaths.claudeSettings, directory: URL = NiaUsagePaths.directory) -> Bool {
        guard let data = try? Data(contentsOf: settings),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = try? Data(contentsOf: directory.appendingPathComponent("claude-connection.json")),
              let saved = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
              let expected = saved["command"] as? String else { return false }
        return (config["statusLine"] as? [String: Any])?["command"] as? String == expected
    }
    static func connect(settings: URL = NiaUsagePaths.claudeSettings, directory: URL = NiaUsagePaths.directory,
                        helper: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nia-usage-bridge")) throws {
        if isConnected(settings: settings, directory: directory) { return }
        let fm = FileManager.default
        let original = fm.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
        var config = try original.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard config != nil, fm.isExecutableFile(atPath: helper.path) else { throw NiaUsageError.settingsInvalid }
        let previous = config?["statusLine"]
        var status = previous as? [String: Any] ?? [:]
        if previous != nil && (status["type"] as? String != "command" || status["command"] as? String == nil) {
            throw NiaUsageError.settingsInvalid
        }
        if (status["command"] as? String)?.contains("nia-usage-bridge") == true { throw NiaUsageError.settingsChanged }
        var command = "\(quote(helper.path)) --output \(quote(directory.appendingPathComponent("claude-usage.json").path))"
        if let old = status["command"] as? String { command += " --previous-command \(quote(old))" }
        status["type"] = "command"
        status["command"] = command
        config?["statusLine"] = status
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = directory.appendingPathComponent("claude-connection.json")
        let saved: [String: Any] = ["command": command, "previous": previous ?? NSNull()]
        // Preserve all unrelated settings and refuse a concurrent edit.
        let latest = fm.fileExists(atPath: settings.path) ? try Data(contentsOf: settings) : nil
        guard latest == original else { throw NiaUsageError.settingsChanged }
        try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(to: record, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        do {
            try JSONSerialization.data(withJSONObject: config!, options: [.prettyPrinted, .sortedKeys]).write(to: settings, options: .atomic)
        } catch { try? fm.removeItem(at: record); throw error }
    }
    static func disconnect(settings: URL = NiaUsagePaths.claudeSettings, directory: URL = NiaUsagePaths.directory) throws {
        let data = try Data(contentsOf: settings)
        let record = directory.appendingPathComponent("claude-connection.json")
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any],
              let command = saved["command"] as? String,
              (config["statusLine"] as? [String: Any])?["command"] as? String == command else { throw NiaUsageError.settingsChanged }
        if saved["previous"] is NSNull { config.removeValue(forKey: "statusLine") }
        else { config["statusLine"] = saved["previous"] }
        guard try Data(contentsOf: settings) == data else { throw NiaUsageError.settingsChanged }
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: settings, options: .atomic)
        try? FileManager.default.removeItem(at: record)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("claude-usage.json"))
    }
}
