// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

@MainActor final class NiaUsageMonitor: ObservableObject {
    static let shared = NiaUsageMonitor()
    @Published private(set) var codex: NiaUsageSnapshot?
    @Published private(set) var claude: NiaUsageSnapshot?
    @Published private(set) var codexError: String?
    @Published private(set) var claudeError: String?
    @Published private(set) var refreshing = false
    private var timer: Timer?
    private var lastCodexPoll = Date.distantPast
    private var claudeStamp: Date?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh(force: Bool = false) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "nia.usage.enabled"), !refreshing else { return }
        let codexEnabled = defaults.object(forKey: "nia.usage.codex") as? Bool ?? true
        let claudeEnabled = defaults.object(forKey: "nia.usage.claude") as? Bool ?? true
        let pollCodex = codexEnabled && (force || Date().timeIntervalSince(lastCodexPoll) >= 300)
        let path = defaults.string(forKey: "nia.usage.codexPath") ?? ""
        if pollCodex { lastCodexPoll = Date() }
        refreshing = true
        Task {
            if claudeEnabled {
                let url = NiaUsagePaths.claudeSnapshot
                do {
                    let stamp = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    if stamp != claudeStamp || force {
                        let value = try await Task.detached {
                            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 65536 else { throw NiaUsageError.unavailable }
                            return try NiaUsageSnapshot.claude(Data(contentsOf: url))
                        }.value
                        claude = value
                        claudeStamp = stamp
                        claudeError = nil
                    }
                } catch { claudeError = NiaL10n.string(NiaUsageError.claudeWaiting.rawValue) }
            }
            if pollCodex {
                do {
                    codex = try await Task.detached { try NiaCodexUsage.read(customPath: path) }.value
                    codexError = nil
                } catch {
                    codexError = NiaL10n.string((error as? NiaUsageError)?.rawValue ?? NiaUsageError.codexFailed.rawValue)
                }
            }
            refreshing = false
        }
    }
}

struct NiaUsageToolbar: ToolbarContent {
    @AppStorage("nia.usage.enabled") private var enabled = false
    @AppStorage("nia.usage.codex") private var showCodex = true
    @AppStorage("nia.usage.claude") private var showClaude = true
    @ObservedObject private var monitor = NiaUsageMonitor.shared
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if enabled {
                if showCodex { NiaProviderUsage(name: "Codex", snapshot: monitor.codex, error: monitor.codexError) }
                if showClaude { NiaProviderUsage(name: "Claude", snapshot: monitor.claude, error: monitor.claudeError) }
            }
        }
    }
}

private struct NiaProviderUsage: View {
    let name: String
    let snapshot: NiaUsageSnapshot?
    let error: String?
    @State private var expanded = false
    @AppStorage("nia.language") private var language = "system"
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(name)
                        if let weekly = snapshot?.weekly {
                            Text("\(Int(weekly.usedPercent.rounded())) %").monospacedDigit()
                        } else { Text("—") }
                    }.font(.caption)
                    if let weekly = snapshot?.weekly {
                        ProgressView(value: weekly.usedPercent, total: 100)
                            .tint(error != nil || snapshot?.stale == true ? .gray : weekly.usedPercent >= 90 ? .orange : .accentColor)
                            .frame(width: 88)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 3).fixedSize()
            }
            .buttonStyle(.plain)
            .help("Cuota semanal utilizada")
            .accessibilityLabel("\(name): \(NiaL10n.string("Cuota semanal utilizada"))")
            .accessibilityIdentifier("nia.usage.\(name.lowercased())")
            .popover(isPresented: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(name).font(.headline)
                    if let snapshot {
                        ForEach(snapshot.windows) { window in
                            if window.isCurrent() {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(LocalizedStringKey(window.minutes == 10080 ? "Semana" : window.minutes == 300 ? "5 horas" : "Otra ventana de cuota"))
                                        Spacer()
                                        Text("\(Int(window.usedPercent.rounded())) %").monospacedDigit()
                                    }
                                    ProgressView(value: window.usedPercent, total: 100)
                                    if let reset = window.resetsAt {
                                        HStack { Text("Se reinicia:"); Text(reset, format: .dateTime.day().month().hour().minute()) }
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if snapshot.weekly == nil { Text("Cuota semanal no disponible.").foregroundStyle(.secondary) }
                        if let tokens = snapshot.tokens {
                            LabeledContent(LocalizedStringKey(snapshot.tokenLabel)) { Text(tokens.formatted()).monospacedDigit() }
                                .font(.caption)
                        }
                        HStack { Text("Última lectura:"); Text(snapshot.updatedAt, style: .relative) }.font(.caption).foregroundStyle(.secondary)
                        if snapshot.stale { Text("Datos antiguos; pueden haber cambiado.").font(.caption).foregroundStyle(.orange) }
                    } else { Text("Sin datos todavía.").foregroundStyle(.secondary) }
                    if let error { Text(verbatim: error).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    Text("La barra muestra cuota utilizada, no un límite fijo de tokens.").font(.caption).foregroundStyle(.secondary)
                    Button("Actualizar consumo") { NiaUsageMonitor.shared.refresh(force: true) }
                        .disabled(NiaUsageMonitor.shared.refreshing)
                }.padding(18).frame(width: 330)
                    .environment(\.locale, language == "system" ? Locale.autoupdatingCurrent : Locale(identifier: language))
            }
        }
    }
}

struct NiaUsageSettings: View {
    @AppStorage("nia.usage.enabled") private var enabled = false
    @AppStorage("nia.usage.codex") private var codex = true
    @AppStorage("nia.usage.claude") private var claude = true
    @AppStorage("nia.usage.codexPath") private var codexPath = ""
    @State private var connected = NiaClaudeConnection.isConnected()
    @State private var error: String?
    var body: some View {
        Section("Consumo de Claude y Codex") {
            Toggle("Mostrar consumo en la barra superior", isOn: $enabled)
            if enabled {
                Toggle("Mostrar Codex", isOn: $codex)
                Toggle("Mostrar Claude", isOn: $claude)
                if codex {
                    HStack {
                        Text("Codex CLI")
                        Text(codexPath.isEmpty ? NiaL10n.string("Detectar automáticamente") : codexPath).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Seleccionar…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                codexPath = url.path
                                NiaUsageMonitor.shared.refresh(force: true)
                            }
                        }
                    }
                }
                if claude {
                    HStack {
                        Button {
                            do {
                                if connected { try NiaClaudeConnection.disconnect() }
                                else { try NiaClaudeConnection.connect() }
                                connected = NiaClaudeConnection.isConnected()
                                error = nil
                                NiaUsageMonitor.shared.refresh(force: true)
                            } catch { self.error = NiaL10n.string((error as? NiaUsageError)?.rawValue ?? NiaUsageError.settingsInvalid.rawValue) }
                        } label: { Text(LocalizedStringKey(connected ? "Desconectar Claude Code" : "Conectar Claude Code")) }
                        if connected { Label("Conectado", systemImage: "checkmark.circle") }
                    }
                    Text("Conectar añade un lector a la línea de estado de Claude Code y conserva el comando anterior. Reinicia las sesiones de Claude abiertas para aplicarlo. Desconectar restaura la configuración anterior.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Codex consulta su cuenta cada cinco minutos. Claude aporta datos después de sus respuestas. Los límites dependen del plan; no se leen conversaciones ni se guardan credenciales.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(verbatim: error).foregroundStyle(.red).font(.caption) }
                Button("Actualizar consumo") { NiaUsageMonitor.shared.refresh(force: true) }
            }
        }
        .onChange(of: enabled) { _, value in if value { NiaUsageMonitor.shared.refresh(force: true) } }
        .onChange(of: codex) { _, _ in NiaUsageMonitor.shared.refresh(force: true) }
        .onChange(of: claude) { _, _ in NiaUsageMonitor.shared.refresh(force: true) }
    }
}
