// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Unified localization for AppKit messages and Swift errors. SwiftUI Text/Label
// use the scene's Locale environment; AppKit selects the same language here.
enum NiaL10n {
    static func string(_ key: String) -> String {
        let code = UserDefaults.standard.string(forKey: "nia.language") ?? "system"
        if code == "en" || code == "es",
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: nil, table: nil)
        }
        return NSLocalizedString(key, comment: "")
    }
}

// Font list is cached once; never enumerate fonts on each SwiftUI redraw.
// Store the PostScript name, because families may contain proportional variants.
private struct NiaFontChoice: Identifiable {
    let name: String
    let title: String
    var id: String { name }
}
private enum NiaMonospaceFonts {
    static let installed: [NiaFontChoice] = {
        NSFontManager.shared.availableFonts.compactMap { name -> NiaFontChoice? in
            guard let font = NSFont(name: name, size: 13), font.isFixedPitch else { return nil }
            return NiaFontChoice(name: name, title: font.displayName ?? name)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }()
}

struct SessionEntry: Decodable, Identifiable, Hashable {
    let id: String
    let display_name: String
    let cwd: String
    let closed: Bool
    let venv: String?
    let color: String
    let remote_host: String?
}
struct NiaCommandMark: Decodable, Identifiable {
    let id: Int64
    let started_at: Double
    let duration_ms: Int64
    let exit_code: Int64
    let cwd: String
    let command: String
    let repeat_count: Int64
    let has_anchor: Bool
}
struct NiaTimelineTarget: Identifiable {
    let id: String
}
struct NiaAIQuery: Decodable, Identifiable {
    let session_id: String
    let question: String
    var id: String { session_id + ":" + question }
}

/// Persisted together in SQLite, not as independent UserDefaults keys.
/// This prevents the left and right pane from referring to different launches.
private struct WorkspaceLayout: Codable {
    let primary: String?
    let secondary: String?
    let mode: String
    let focusedPane: Int
    let tabs: [String]?
}

@MainActor private enum NiaSharedCore {
    static let handle: UnsafeMutableRawPointer? = nia_core_new()
    static var owners: [String: String] = [:]
    static var aiQueue: [NiaAIQuery] = []
    static var exitQueue: [String] = []
    private struct WeakModel { weak var value: NiaModel? }
    private static var models: [WeakModel] = []
    private static var timer: Timer?
    private static var terminationObserver: NSObjectProtocol?
    private static var lastMaintenance = -Double.infinity
    private static var lastMaintenanceError: String?
    private static var stopping = false

    static func string(_ value: UnsafeMutablePointer<CChar>?) -> String {
        guard let value else { return "" }
        defer { nia_string_free(value) }
        return String(cString: value)
    }
    static func sessionEntries() -> [SessionEntry]? {
        guard let handle,
              let data = string(nia_sessions(handle)).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([SessionEntry].self, from: data)
    }
    static func register(_ model: NiaModel) {
        models.removeAll { $0.value == nil }
        models.append(WeakModel(value: model))
        guard timer == nil, !stopping else { return }
        // One clock for the process, including split panes and extra windows.
        // All mutable core access stays serialized on the main actor. The Rust
        // output pump only parses/queues bytes; its worker performs disk writes.
        let poll = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated { pump() }
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    guard !stopping else { return }
                    stopping = true
                    timer?.invalidate()
                    timer = nil
                    if let handle, nia_flush_pending(handle) != 0 {
                        NSLog("Nia history flush: %@", string(nia_last_error(handle)))
                    }
                }
            }
        }
    }
    private static func pump() {
        guard !stopping, let handle else { return }
        models.removeAll { $0.value == nil }
        guard !models.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        nia_poll(handle)
        let now = ProcessInfo.processInfo.systemUptime
        let maintenance = now - lastMaintenance >= 0.5
        var entries: [SessionEntry]?
        var backgroundError: String?
        if maintenance {
            lastMaintenance = now
            if nia_maintain(handle) != 0 {
                let message = NiaL10n.string(string(nia_last_error(handle)))
                // Dismissing one error must not reopen an alert every 500 ms.
                // A new error or a failure after recovery is reported again.
                if message != lastMaintenanceError { backgroundError = message }
                lastMaintenanceError = message
            } else {
                lastMaintenanceError = nil
            }
            entries = sessionEntries()
            if let data = string(nia_take_exit_requests(handle)).data(using: .utf8),
               let incoming = try? JSONDecoder().decode([String].self, from: data) {
                exitQueue.append(contentsOf: incoming)
            }
            if let data = string(nia_take_ai_queries(handle)).data(using: .utf8),
               let incoming = try? JSONDecoder().decode([NiaAIQuery].self, from: data) {
                aiQueue.append(contentsOf: incoming)
            }
        }
        for model in models.compactMap({ $0.value }) {
            model.refreshAfterPoll(maintenance: maintenance, sessions: entries,
                                   backgroundError: backgroundError)
        }
    }
    static func claim(_ session: String, window: String) -> Bool {
        if let current = owners[session], current != window { return false }
        owners[session] = window
        return true
    }
    static func release(_ session: String, window: String) {
        if owners[session] == window { owners.removeValue(forKey: session) }
    }
    static func releaseAll(_ window: String) {
        owners = owners.filter { $0.value != window }
    }
}
private struct NiaWindowModelKey: FocusedValueKey { typealias Value = NiaModel }
private extension FocusedValues {
    var niaWindowModel: NiaModel? {
        get { self[NiaWindowModelKey.self] }
        set { self[NiaWindowModelKey.self] = newValue }
    }
}
@MainActor final class NiaModel: ObservableObject {
    private var handle: UnsafeMutableRawPointer?
    @Published var sessions: [SessionEntry] = []
    @Published private(set) var tabIDs: [String] = []
    var visibleSessions: [SessionEntry] {
        tabIDs.compactMap { id in sessions.first { $0.id == id } }
    }
    private var windowID: String?

    @Published var selected: String? = nil
    @Published private(set) var frames: [String: ScreenSnapshot] = [:]
    @Published private(set) var revisions: [String: UInt64] = [:]
    @Published var secondary: String? = nil
    @Published var splitMode: String = "off"
    @Published var activePane = 0
    @Published private(set) var focusEpoch: UInt64 = 0
    @Published private(set) var focusSession: String? = nil
    @Published var error: String?
    @Published var aiRequest: NiaAIQuery?
    @Published var pendingExitSession: String?
    @Published var timelineTarget: NiaTimelineTarget?
    private var pendingAIRequests: [NiaAIQuery] = []
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    private var screenGenerationBySession: [String: UInt64] = [:]
    private var paneSizes: [String: (rows: Int, columns: Int)] = [:]

    init() {
        handle = NiaSharedCore.handle
        guard let handle else { error = NiaL10n.string("No se pudo abrir la base de datos de Nia"); return }
        let saved = UserDefaults.standard.object(forKey: "nia.scrollbackLines") as? Int ?? 10000
        _ = nia_set_scrollback_limit(handle, UInt32(clamping: min(100000, max(1000, saved))))
        refreshSessions()
        NiaSharedCore.register(self)
    }
    private func resultString(_ value: UnsafeMutablePointer<CChar>?) -> String {
        NiaSharedCore.string(value)
    }
    private func report(_ code: Int32) -> Bool {
        guard code == 0 else { error = NiaL10n.string(resultString(nia_last_error(handle))); return false }
        error = nil
        return true
    }
    func refreshSessions() {
        if let entries = NiaSharedCore.sessionEntries(), entries != sessions {
            sessions = entries
        }
    }
    func configureWindow(_ id: String) {
        guard windowID == nil else { return }
        windowID = id
        restoreWorkspace()
    }
    func detachWindow() {
        guard let id = windowID else { return }
        saveWorkspace()
        NiaSharedCore.releaseAll(id)
        windowID = nil
    }
    private func saveWorkspace() {
        guard let handle, let windowID else { return }
        let layout = WorkspaceLayout(primary: selected,
                                     secondary: secondary,
                                     mode: splitMode,
                                     focusedPane: splitMode == "off" ? 0 : activePane,
                                     tabs: tabIDs)
        guard let data = try? JSONEncoder().encode(layout),
              let payload = String(data: data, encoding: .utf8) else { return }
        // Save alongside sessions, so encrypted backups include every window.
        let status = windowID.withCString { id in
            payload.withCString { nia_save_window_workspace(handle, id, $0) }
        }
        if status != 0 { error = NiaL10n.string(resultString(nia_last_error(handle))) }
    }

    private func restoreWorkspace() {
        guard let handle, let windowID else { return }
        let raw = windowID.withCString { resultString(nia_window_workspace(handle, $0)) }
        var saved = raw.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(WorkspaceLayout.self, from: $0)
        }
        let migrate = !UserDefaults.standard.bool(forKey: "nia.workspace.migrated")
        if saved == nil && migrate {
            let old = resultString(nia_workspace_layout(handle))
            saved = old.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(WorkspaceLayout.self, from: $0)
            }
            UserDefaults.standard.set(true, forKey: "nia.workspace.migrated")
        }
        let existing = Set(sessions.map(\.id))
        // SceneStorage may provide a new UUID on relaunch, even when older
        // windows and their per-window layouts remain in SQLite. Recover all
        // open sessions into the first window as a safe fallback. Additional
        // Cmd+N windows still start empty, because those IDs are claimed.
        let firstWindowWithoutLayout = saved == nil && NiaSharedCore.owners.isEmpty
        let candidates = saved?.tabs ?? (firstWindowWithoutLayout
            ? sessions.filter { !$0.closed }.map(\.id)
            : [])
        var accepted: [String] = []
        for id in candidates where existing.contains(id) && !accepted.contains(id) {
            if NiaSharedCore.claim(id, window: windowID) { accepted.append(id) }
        }
        tabIDs = accepted
        selected = saved?.primary.flatMap { accepted.contains($0) ? $0 : nil } ?? accepted.first
        secondary = saved?.secondary.flatMap { accepted.contains($0) && $0 != selected ? $0 : nil }
        let mode = saved?.mode ?? "off"
        splitMode = ["vertical", "horizontal"].contains(mode) && secondary != nil ? mode : "off"
        activePane = splitMode != "off" && saved?.focusedPane == 1 ? 1 : 0
        // Restore every tab's shell, not only the visible split panes.
        // Previously only the selected/secondary PTYs were respawned, so
        // Claude or another long-running CLI in an unfocused tab disappeared.
        for id in tabIDs {
            if report(id.withCString({ nia_open_session(handle, $0) })) {
                if id == selected || (splitMode != "off" && id == secondary) {
                    prepareScreen(for: id)
                }
            }
        }
        saveWorkspace()
        if let id = activePane == 1 ? secondary : selected { requestFocus(id) }
    }

    func reconnectRemote(_ name: String) {
        guard let handle else { return }
        let result = name.withCString { nia_reconnect_remote_session(handle, $0) }
        if report(result) { prepareScreen(for: name); requestFocus(name) }
    }

    func createRemote(name rawName: String, host rawHost: String) {
        guard let handle else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && !host.isEmpty else { return }
        let result = name.withCString { n in
            host.withCString { h in nia_create_remote_session(handle, n, h) }
        }
        if report(result) { refreshSessions(); activate(name) }
    }

    func create(_ raw: String) {
        guard let handle else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if report(name.withCString { nia_create_session(handle, $0) }) {
            refreshSessions()
            activate(name)
        }
    }
    func renameSession(_ id: String, to name: String) -> Bool {
        guard let handle else { return false }
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            error = NiaL10n.string("El nombre de la sesión no puede estar vacío.")
            return false
        }
        let result = id.withCString { session in
            newName.withCString { title in nia_rename_session(handle, session, title) }
        }
        if report(result) { refreshSessions(); return true }
        return false
    }
    func title(for id: String) -> String {
        sessions.first(where: { $0.id == id })?.display_name ?? id
    }
    func requestFocus(_ id: String) {
        focusSession = id
        focusEpoch &+= 1
    }
    func activate(_ name: String) {
        guard let handle, let windowID else { return }
        let adding = !tabIDs.contains(name)
        if adding && !NiaSharedCore.claim(name, window: windowID) {
            error = NiaL10n.string("Esta sesión está abierta en otra ventana. Ciérrala allí para trasladarla.")
            return
        }
        // Explicitly keep the two panes distinct; selecting a session already
        // visible in the other pane moves keyboard focus there instead.
        if splitMode != "off" && name == secondary {
            activePane = 1
            saveWorkspace()
            requestFocus(name)
            return
        }
        if name == selected {
            activePane = 0
            saveWorkspace()
            requestFocus(name)
            return
        }
        guard report(name.withCString({ nia_open_session(handle, $0) })) else {
            if adding { NiaSharedCore.release(name, window: windowID) }
            return
        }
        if adding { tabIDs.append(name) }
        refreshSessions()
        // Decode a complete screen before publishing the pane identity.
        prepareScreen(for: name)
        if splitMode != "off" && activePane == 1 {
            if selected == name { activePane = 0 }
            else {
                secondary = name
            }
        } else { selected = name }
        saveWorkspace()
        requestFocus(name)
    }
    func archive(_ name: String) {
        // Closing a window's tab does not terminate a PTY or delete its history.
        guard let windowID else { return }
        tabIDs.removeAll { $0 == name }
        NiaSharedCore.release(name, window: windowID)
        frames.removeValue(forKey: name)
        revisions.removeValue(forKey: name)
        screenGenerationBySession.removeValue(forKey: name)
        paneSizes.removeValue(forKey: name)
        if pendingExitSession == name { pendingExitSession = nil }
        if secondary == name { secondary = nil; splitMode = "off"; activePane = 0 }
        if selected == name {
            selected = secondary.flatMap { tabIDs.contains($0) ? $0 : nil } ?? tabIDs.first
            secondary = nil
            splitMode = "off"
            activePane = 0
        }
        if let selected { prepareScreen(for: selected); requestFocus(selected) }
        saveWorkspace()
    }

    func reorder(_ dragged: String, relativeTo target: String, after: Bool) {
        guard dragged != target, let from = tabIDs.firstIndex(of: dragged) else { return }
        tabIDs.remove(at: from)
        guard let to = tabIDs.firstIndex(of: target) else { return }
        tabIDs.insert(dragged, at: to + (after ? 1 : 0))
        saveWorkspace()
    }

    func setSplit(_ mode: String) {
        guard ["off", "vertical", "horizontal"].contains(mode) else { return }
        splitMode = mode
        if mode == "off" {
            activePane = 0
            saveWorkspace()
            if let selected { requestFocus(selected) }
            return
        }
        if secondary == nil || secondary == selected {
            secondary = visibleSessions.first(where: { $0.id != selected })?.id
        }
        if let secondary {
            if let handle { _ = secondary.withCString { nia_open_session(handle, $0) } }
            prepareScreen(for: secondary)
        }
        saveWorkspace()
        if let selected { requestFocus(selected) }
    }
    func chooseSecondary(_ id: String) {
        guard let handle, id != selected, let windowID else { return }
        let adding = !tabIDs.contains(id)
        if adding && !NiaSharedCore.claim(id, window: windowID) {
            error = NiaL10n.string("Esta sesión pertenece a otra ventana.")
            return
        }
        guard report(id.withCString({ nia_open_session(handle, $0) })) else {
            if adding { NiaSharedCore.release(id, window: windowID) }
            return
        }
        if adding { tabIDs.append(id) }
        secondary = id
        if splitMode == "off" { splitMode = "vertical" }
        refreshSessions()
        prepareScreen(for: id)
        activePane = 1
        saveWorkspace()
        requestFocus(id)
    }
    func paneFocused(_ index: Int, session: String) {
        // A mouse click has ALREADY made that MTKView the first responder.
        // Never enqueue a second asynchronous makeFirstResponder here: doing so
        // can move focus back to a stale pane during Cmd+V.
        guard activePane != index || focusSession != session else { return }
        activePane = index
        focusSession = session
        saveWorkspace()
    }
    func screen(for id: String) -> ScreenSnapshot? { frames[id] }
    func revision(for id: String) -> UInt64 { revisions[id] ?? 0 }
    func setColor(_ color: Color, for id: String) {
        guard let handle else { return }
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .systemBlue
        let hex = String(format: "#%02X%02X%02X", Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
        if report(id.withCString { name in hex.withCString { value in nia_set_session_color(handle, name, value) } }) {
            refreshSessions()
        }
    }
    func showTimeline(for session: String? = nil) {
        let id = session ?? (splitMode != "off" && activePane == 1 ? secondary : selected)
        if let id { timelineTarget = NiaTimelineTarget(id: id) }
    }
    func commandMarks(for session: String) -> [NiaCommandMark] {
        guard let handle else { return [] }
        let raw = session.withCString { resultString(nia_command_marks(handle, $0)) }
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([NiaCommandMark].self, from: data)) ?? []
    }
    func selectSlot(_ number: Int) {
        if tabIDs.indices.contains(number) { activate(tabIDs[number]) }
    }
    func send(_ bytes: [UInt8], to id: String) {
        guard let handle, !bytes.isEmpty else { return }
        let status = bytes.withUnsafeBufferPointer { buffer in
            id.withCString { nia_send(handle, $0, buffer.baseAddress, buffer.count) }
        }
        // The PTY input queue accepts the entire event or reports a failure.
        // Do not publish an unchanged error=nil on every successful keypress.
        if status != 0 {
            let message = NiaL10n.string(resultString(nia_last_error(handle)))
            if error != message { error = message }
        }
    }
    /// Navigate the indexed transcript without sending anything to the shell.
    func jumpToCommand(_ mark: NiaCommandMark, session id: String) -> Bool {
        guard let handle else { return false }
        // The selected tab is already owned by this window; an old archived
        // session is activated normally before querying its disk history.
        activate(id)
        guard report(id.withCString({ nia_jump_to_command(handle, $0, mark.id) })) else { return false }
        refreshScreen(for: id)
        return true
    }
    func scroll(lines: Int, session id: String) {
        guard let handle, lines != 0 else { return }
        guard report(id.withCString({ nia_scroll(handle, $0, Int32(clamping: lines)) })) else { return }
        refreshScreen(for: id)
    }
    func resize(rows: Int, columns: Int, session id: String) -> Bool {
        guard let handle else { return false }
        let r = min(Int(UInt16.max), max(1, rows)), c = min(Int(UInt16.max), max(1, columns))
        if let prev = paneSizes[id], prev.rows == r && prev.columns == c,
           let screen = frames[id], Int(screen.rows) == r, Int(screen.cols) == c { return true }
        // Critical: inform the PTY of the real column count immediately.
        // Debouncing this call made new output wrap to the old width.
        let status = id.withCString {
            nia_resize_fast(handle, $0, UInt16(clamping: r), UInt16(clamping: c))
        }
        guard status == 0 else {
            paneSizes.removeValue(forKey: id)
            let message = NiaL10n.string(resultString(nia_last_error(handle)))
            if error != message { error = message }
            return false
        }
        // Cache only an acknowledged PTY resize, so an early failed attempt
        // cannot suppress the first valid size for a newly opened session.
        paneSizes[id] = (r, c)
        refreshScreen(for: id)

        // Do not replay the ANSI log over a live shell. Resize is immediate,
        // and applications redraw when notified by the PTY's SIGWINCH.
        return true
    }
    private func prepareScreen(for id: String) {
        guard let handle else { return }
        if let size = paneSizes[id] {
            _ = id.withCString { nia_resize(handle, $0, UInt16(clamping: size.rows), UInt16(clamping: size.columns)) }
        }
        nia_poll(handle)
        refreshScreen(for: id)
    }
    private func refreshScreen(for id: String) {
        guard let handle else { return }
        var length = 0
        let known = screenGenerationBySession[id] ?? 0
        guard let bytes = id.withCString({ nia_screen_snapshot(handle, $0, known, &length) }) else { return }
        defer { nia_snapshot_free(bytes, length) }
        let buffer = UnsafeRawBufferPointer(start: bytes, count: length)
        guard let decoded = try? NiaScreenDecoder.decode(buffer, sessionID: id) else { return }
        screenGenerationBySession[id] = decoded.revision
        frames[id] = decoded.snapshot
        revisions[id, default: 0] &+= 1
    }
    func approvePendingExit() {
        guard let id = pendingExitSession, let handle else { return }
        pendingExitSession = nil
        if !report(id.withCString({ nia_confirm_exit(handle, $0) })) { return }
    }

    func cancelPendingExit() {
        pendingExitSession = nil
        // The Zsh line was discarded before execution. Shell is untouched.
    }

    func showNextAIRequest() {
        guard aiRequest == nil, !pendingAIRequests.isEmpty else { return }
        aiRequest = pendingAIRequests.removeFirst()
    }
    fileprivate func refreshAfterPoll(maintenance: Bool, sessions entries: [SessionEntry]?,
                                      backgroundError: String?) {
        guard let handle, windowID != nil else { return }
        if let backgroundError, error != backgroundError { error = backgroundError }
        if let selected { refreshScreen(for: selected) }
        if splitMode != "off", let secondary, secondary != selected {
            refreshScreen(for: secondary)
        }
        guard maintenance else { return }
        if let entries, entries != sessions { sessions = entries }
        // A completed local PTY is archived by Rust. Remove its tab from
        // whichever native window currently owns the presentation.
        for id in tabIDs where sessions.first(where: { $0.id == id })?.closed == true {
            archive(id)
        }
        let mine = NiaSharedCore.exitQueue.filter { tabIDs.contains($0) }
        NiaSharedCore.exitQueue.removeAll { tabIDs.contains($0) }
        for id in mine {
            if !(UserDefaults.standard.object(forKey: "nia.confirmExit") as? Bool ?? true) {
                _ = report(id.withCString { nia_confirm_exit(handle, $0) })
            } else if pendingExitSession == nil {
                pendingExitSession = id
            } else {
                NiaSharedCore.exitQueue.append(id)
            }
        }
        let own = NiaSharedCore.aiQueue.filter { tabIDs.contains($0.session_id) }
        NiaSharedCore.aiQueue.removeAll { tabIDs.contains($0.session_id) }
        pendingAIRequests.append(contentsOf: own)
        showNextAIRequest()
    }
}

private struct NiaWindowRoot: View {
    @SceneStorage("nia.workspace.identity") private var windowID = UUID().uuidString
    @StateObject private var model = NiaModel()
    @AppStorage("nia.language") private var language = "system"

    var body: some View {
        MainWindow()
            .environmentObject(model)
            .environment(\.locale, language == "system" ? Locale.autoupdatingCurrent : Locale(identifier: language))
            .focusedSceneValue(\.niaWindowModel, model)
            .frame(minWidth: 720, minHeight: 420)
            .onAppear { model.configureWindow(windowID) }
            .onDisappear { model.detachWindow() }
    }
}
@main struct NiaApp: App {
    @AppStorage("nia.language") private var language = "system"
    @AppStorage("nia.appearance") private var appearance = "system"
    @FocusedValue(\.niaWindowModel) private var focusedModel
    var body: some Scene {
        // WindowGroup supplies the native Cmd+N action.
        WindowGroup("nia_") {
            NiaWindowRoot()
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(NiaL10n.string("Acerca de nia_")) {
                    let github = URL(string: "https://github.com/vicktor/nia_")!
                    let text = NSMutableAttributedString(string: NiaL10n.string("Source / Código: github.com/vicktor/nia_ · MPL-2.0"))
                    let range = (text.string as NSString).range(of: "github.com/vicktor/nia_")
                    text.addAttribute(.link, value: github, range: range)
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "nia_",
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.0",
                        .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
                        .credits: text
                    ])
                }
                Button(NiaL10n.string("Repositorio de nia_ en GitHub")) {
                    if let url = URL(string: "https://github.com/vicktor/nia_") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button(NiaL10n.string("Historial de comandos")) {
                    focusedModel?.showTimeline()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Button(NiaL10n.string("Mostrar/ocultar sesiones")) {
                    if let model = focusedModel {
                        model.sidebarVisibility = model.sidebarVisibility == .detailOnly ? .all : .detailOnly
                    }
                }.keyboardShortcut("b", modifiers: .command)
                Divider()
                ForEach(0..<9, id: \.self) { index in
                    Button(String(format: NiaL10n.string("Sesión %d"), index + 1)) { focusedModel?.selectSlot(index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index+1))), modifiers: .command)
                }
            }
        }
        Settings {
            NiaSettings()
                .environment(\.locale, language == "system" ? Locale.autoupdatingCurrent : Locale(identifier: language))
                // Settings is a separate macOS scene: it does not inherit
                // MainWindow's preferredColorScheme. Keep both in sync.
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject private var model: NiaModel
    @AppStorage("nia.appearance") private var appearance = "system"
    @AppStorage("nia.cursorBlink") private var cursorBlink = true
    @AppStorage("nia.cursorShape") private var cursorShape = "bar"
    @AppStorage("nia.terminalOpacity") private var terminalOpacity = 1.0
    @AppStorage("nia.fontName") private var terminalFontName = "system"
    @AppStorage("nia.fontSize") private var terminalFontSize = 13.0
    @State private var newSession = ""
    @State private var editingSession: String?
    @State private var editedTitle = ""
    @FocusState private var editingTitleFocused: Bool
    @State private var showRemoteSetup = false
    @State private var remoteName = ""
    @State private var remoteHost = ""
    @State private var filter = ""
    @State private var showExitConfirmation = false
    @State private var draggingSession: String?
    @State private var dropTarget: String?
    @State private var dropAfter = false
    @FocusState private var addingSession: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar sesiones", text: $filter).textFieldStyle(.plain)
                }
                .padding(9)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .top], 10)

                List(selection: Binding(get: { model.activePane == 1 && model.splitMode != "off" ? model.secondary : model.selected }, set: { if let id = $0 { model.activate(id) } })) {
                    Section("SESIONES") {
                        ForEach(model.visibleSessions.filter {
                            filter.isEmpty || $0.display_name.localizedCaseInsensitiveContains(filter)
                                || $0.id.localizedCaseInsensitiveContains(filter)
                        }) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.closed ? "archivebox" : (item.remote_host == nil ? "terminal" : "network"))
                                    .foregroundStyle(Color(hexRGB: item.color))
                                VStack(alignment: .leading, spacing: 3) {
                                    if editingSession == item.id {
                                        TextField("Nombre de sesión", text: $editedTitle)
                                            .textFieldStyle(.plain)
                                            .focused($editingTitleFocused)
                                            .onSubmit { commitRename(item.id) }
                                            .onExitCommand { cancelRename() }
                                    } else {
                                        Text(item.display_name)
                                            .lineLimit(1)
                                            .onTapGesture(count: 2) { beginRename(item) }
                                    }
                                    Text(item.cwd).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                ZStack {
                                    Circle()
                                        .fill(Color(hexRGB: item.color))
                                        .frame(width: 8, height: 8)
                                    ColorPicker("Color de sesión", selection: Binding(
                                        get: { Color(hexRGB: model.sessions.first(where: { $0.id == item.id })?.color ?? item.color) },
                                        set: { model.setColor($0, for: item.id) }
                                    ), supportsOpacity: false)
                                    .labelsHidden()
                                    .blendMode(.destinationOver)
                                    .opacity(0.015)
                                }
                                .frame(width: 18, height: 18) // 18pt hit target, 8pt visible color dot
                                .help("Cambiar color de la sesión")
                            }
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .opacity(draggingSession == item.id ? 0.5 : 1)
                            .overlay(alignment: .top) {
                                if dropTarget == item.id && !dropAfter {
                                    Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 5)
                                        .offset(y: -2).allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if dropTarget == item.id && dropAfter {
                                    Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 5)
                                        .offset(y: 2).allowsHitTesting(false)
                                }
                            }
                            .onDrag {
                                draggingSession = item.id
                                return NSItemProvider(object: item.id as NSString)
                            } preview: {
                                Label(item.id, systemImage: "terminal")
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .onDrop(of: [UTType.utf8PlainText], delegate: SessionDropDelegate(
                                target: item.id,
                                dragging: $draggingSession, hovering: $dropTarget,
                                after: $dropAfter,
                                reorder: { moved, target, after in
                                    model.reorder(moved, relativeTo: target, after: after)
                                }
                            ))
                            .contextMenu {
                                Button("Renombrar sesión") { beginRename(item) }
                                Button(LocalizedStringKey(item.closed ? "Abrir sesión" : "Cambiar a sesión")) { model.activate(item.id) }
                                Button("Historial de comandos") { model.showTimeline(for: item.id) }
                                if item.remote_host != nil {
                                    Button("Reconectar SSH") { model.reconnectRemote(item.id) }
                                }
                                if !item.closed {
                                    Button("Abrir en segundo panel") { model.chooseSecondary(item.id) }
                                    Button("Cerrar pestaña") { model.archive(item.id) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                HStack {
                    TextField("Nueva sesión", text: $newSession)
                        .focused($addingSession)
                        .onSubmit { create() }
                    Button(action: create) { Image(systemName: "plus") }
                        .buttonStyle(.bordered).help("Crear sesión local")
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 185, ideal: 245, max: 350)
        } detail: {
            VStack(spacing: 0) {
                if let selected = model.selected {
                    if model.splitMode != "off", let second = model.secondary, second != selected {
                        if model.splitMode == "vertical" {
                            HSplitView {
                                pane(selected, index: 0)
                                pane(second, index: 1)
                            }
                        } else {
                            VSplitView {
                                pane(selected, index: 0)
                                pane(second, index: 1)
                            }
                        }
                    } else {
                        pane(selected, index: 0)
                    }
                } else {
                    ContentUnavailableView("No hay ninguna sesión abierta", systemImage: "terminal",
                        description: Text("Crea una sesión o abre una sesión guardada."))
                }
            }
            // A fresh Cmd+N window has no terminal drawable yet. Keep its
            // empty detail opaque, regardless of the saved terminal opacity.
            .background(model.selected == nil
                ? Color(nsColor: .textBackgroundColor) : Color.clear)
        }
        .background(NiaWindowTransparency(opacity: model.selected == nil ? 1.0 : terminalOpacity))
        .navigationTitle(model.selected.map { model.title(for: $0) } ?? "nia_")
        // Keep the native macOS titlebar and traffic-light controls.
        // Arrange the three workspace actions left to right in one group.
        // No custom titlebar overlays or NSWindow toolbar manipulation.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { model.setSplit("off") } label: {
                        Label("Una sesión", systemImage: "rectangle")
                    }
                    Button { model.setSplit("vertical") } label: {
                        Label("Lado a lado", systemImage: "rectangle.split.2x1")
                    }
                    Button { model.setSplit("horizontal") } label: {
                        Label("Arriba y abajo", systemImage: "rectangle.split.1x2")
                    }
                } label: {
                    Image(systemName: model.splitMode == "vertical"
                        ? "rectangle.split.2x1"
                        : model.splitMode == "horizontal"
                            ? "rectangle.split.1x2" : "rectangle")
                }
                .help("Disposición de terminales")
                Button {
                    showRemoteSetup = true
                } label: {
                    Image(systemName: "network")
                }
                .help("Nueva sesión SSH remota")
                Menu {
                    let saved = model.sessions.filter { !model.tabIDs.contains($0.id) }
                    if saved.isEmpty {
                        Text("No hay sesiones guardadas")
                    } else {
                        ForEach(saved) { item in
                            Button(item.display_name) { model.activate(item.id) }
                        }
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Abrir sesión guardada en esta ventana")
                Button {
                    model.showTimeline()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Historial de comandos")
                .disabled(model.selected == nil)
            }
        }
        .sheet(item: $model.timelineTarget) { target in
            NiaCommandTimeline(
                session: target.id, marks: model.commandMarks(for: target.id),
                onInsert: { command in
                    guard !command.contains("\n") && !command.contains("\r") else { return }
                    model.activate(target.id)
                    model.send(Array(command.utf8), to: target.id)
                    model.requestFocus(target.id)
                }, onJump: { mark in
                    model.jumpToCommand(mark, session: target.id)
                }
            )
        }
        .sheet(isPresented: $showRemoteSetup) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nueva sesión remota").font(.title2.bold())
                Text("Nia conecta por SSH con verificación estricta del host y recupera una sesión tmux existente.")
                    .foregroundStyle(.secondary)
                TextField("Nombre de sesión en Nia", text: $remoteName)
                TextField("Alias SSH (ej. mac-studio)", text: $remoteHost)
                    .textContentType(.URL)
                HStack {
                    Spacer()
                    Button("Cancelar") { showRemoteSetup = false }
                    Button("Conectar") {
                        model.createRemote(name: remoteName, host: remoteHost)
                        showRemoteSetup = false
                        remoteName = ""; remoteHost = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(remoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22)
            .frame(width: 440)
        }
        .onChange(of: model.pendingExitSession) { _, id in
            showExitConfirmation = (id != nil)
        }
        .confirmationDialog(
            "¿Finalizar esta sesión?",
            isPresented: $showExitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Finalizar sesión", role: .destructive) {
                model.approvePendingExit()
            }
            Button("Cancelar", role: .cancel) {
                model.cancelPendingExit()
            }
        } message: {
            if let name = model.pendingExitSession {
                Text(String(format: NiaL10n.string("La sesión «%@» sigue activa. ¿Quieres ejecutar exit y cerrarla?"), name))
            }
        }
        .sheet(item: $model.aiRequest, onDismiss: {
            model.showNextAIRequest()
        }) { query in
            NiaAICommandSheet(query: query, onInsert: { command in
                model.send(Array(command.utf8), to: query.session_id)
                model.requestFocus(query.session_id)
            }, onAutoExecute: { command in
                // A complete shell line with one Enter; validated independently
                // of the LLM. It is only sent to the originating focused pane.
                model.send(Array((command + "\r").utf8), to: query.session_id)
                model.requestFocus(query.session_id)
            }, canAutoExecute: {
                model.focusSession == query.session_id &&
                (model.selected == query.session_id || model.secondary == query.session_id)
            })
        }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .alert("nia_", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Aceptar") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    @ViewBuilder private func pane(_ session: String, index: Int) -> some View {
        VStack(spacing: 0) {
            if model.splitMode != "off" {
                HStack {
                    Circle().fill(Color(hexRGB: model.sessions.first(where: { $0.id == session })?.color ?? "#648ACA"))
                        .frame(width: 5, height: 5)
                    Text(model.title(for: session)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(.bar)
            }
            TerminalPanel(sessionID: session,
                frame: model.screen(for: session), revision: model.revision(for: session),
                cursorBlink: cursorBlink, cursorShape: cursorShape, opacity: terminalOpacity,
                fontName: terminalFontName, fontSize: terminalFontSize,
                focusEpoch: model.focusSession == session ? model.focusEpoch : 0,
                onFocus: { model.paneFocused(index, session: session) },
                onInput: { model.send($0, to: session) },
                onResize: { r,c in model.resize(rows:r, columns:c, session:session) },
                onScroll: { model.scroll(lines:$0, session:session) })
                .frame(minWidth: 180, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func beginRename(_ item: SessionEntry) {
        editedTitle = item.display_name
        editingSession = item.id
        DispatchQueue.main.async { editingTitleFocused = true }
    }

    private func cancelRename() {
        editingSession = nil
        editingTitleFocused = false
    }

    private func commitRename(_ id: String) {
        if model.renameSession(id, to: editedTitle) {
            cancelRename()
        } else {
            editingTitleFocused = true
        }
    }

    private func create() {
        model.create(newSession)
        newSession = ""
        addingSession = false
    }
}

/// On-demand, bounded history of completed Zsh commands. No polling while
/// the sheet is closed and no extra renderer or services.
private struct NiaCommandTimeline: View {
    let session: String
    let marks: [NiaCommandMark]
    let onInsert: (String) -> Void
    let onJump: (NiaCommandMark) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var visible: [NiaCommandMark] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return marks }
        return marks.filter {
            $0.command.localizedCaseInsensitiveContains(query) ||
            $0.cwd.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasSearch: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // A fixed, full-height sheet avoids the native window re-centering its
        // content when search switches from a scroll view to an empty state.
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Historial de comandos", systemImage: "clock.arrow.circlepath")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cerrar") { dismiss() }
            }
            Text(session)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Buscar comandos", text: $search)
                .textFieldStyle(.roundedBorder)

            Group {
                if visible.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: hasSearch ? "magnifyingglass" : "terminal")
                            .font(.system(size: 31, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(hasSearch ? "No hay coincidencias" : "Sin comandos registrados")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(hasSearch
                            ? "No se ha encontrado ningún comando que coincida con tu búsqueda."
                            : "Se registran los comandos completados en Zsh local.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { mark in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(mark.command)
                                            .font(.system(size: 12, design: .monospaced))
                                            .textSelection(.enabled)
                                        if mark.repeat_count > 1 {
                                            Text("×\(mark.repeat_count)")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    Text(mark.cwd)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    HStack(spacing: 10) {
                                        Text(Date(timeIntervalSince1970: mark.started_at)
                                            .formatted(date: .abbreviated, time: .shortened))
                                        Text(String(format: "%.2f s", Double(mark.duration_ms) / 1000.0))
                                        Label(String(mark.exit_code),
                                            systemImage: mark.exit_code == 0 ? "checkmark.circle" : "xmark.circle")
                                            .foregroundStyle(mark.exit_code == 0 ? Color.green : Color.orange)
                                        Spacer()
                                        Button("Ver salida") {
                                            if onJump(mark) { dismiss() }
                                        }
                                        .disabled(!mark.has_anchor)
                                        .help(mark.has_anchor
                                            ? "Ir al resultado de este comando"
                                            : "Esta ejecución no tiene marca de navegación")
                                        Button("Copiar") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(mark.command, forType: .string)
                                        }
                                        Button("Insertar") {
                                            onInsert(mark.command)
                                            dismiss()
                                        }
                                        .disabled(mark.command.contains("\n") || mark.command.contains("\r"))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 9)
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Los comandos pueden contener datos sensibles. El historial se guarda localmente en SQLite.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 710, height: 560)
    }
}

struct NiaSettings: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Apariencia", systemImage: "paintbrush") }
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            BackupSettings().tabItem { Label("Backup", systemImage: "externaldrive") }
            NiaAISettings().tabItem { Label("IA", systemImage: "sparkles") }
        }
        .padding(20)
        .frame(minWidth: 790, idealWidth: 830, minHeight: 520, idealHeight: 570)
    }
}
struct GeneralSettings: View {
    @AppStorage("nia.language") private var language = "system"
    @AppStorage("nia.restoreSessions") private var restore = true
    @AppStorage("nia.copyOnSelect") private var copy = true
    @AppStorage("nia.confirmExit") private var confirmExit = true
    var body: some View {
        Form {
            Picker("Idioma", selection: $language) {
                Text("Automático (macOS)").tag("system")
                Text("English").tag("en")
                Text("Español").tag("es")
            }
            Toggle("Restaurar sesiones al abrir Nia", isOn: $restore)
            Toggle("Copiar automáticamente al seleccionar", isOn: $copy)
            Toggle("Preguntar antes de cerrar una sesión con exit", isOn: $confirmExit)
            Text("Los historiales siguen guardándose en la base de datos existente.")
                .foregroundStyle(.secondary).font(.caption)
        }.formStyle(.grouped)
    }
}
struct AppearanceSettings: View {
    @AppStorage("nia.appearance") private var theme = "system"
    @AppStorage("nia.fontName") private var fontName = "system"
    @AppStorage("nia.fontSize") private var size = 13.0
    @AppStorage("nia.cursorBlink") private var blink = true
    @AppStorage("nia.cursorShape") private var cursorShape = "bar"
    @AppStorage("nia.terminalOpacity") private var opacity = 1.0
    var body: some View {
        Form {
            Picker("Apariencia", selection: $theme) {
                Text("Automática").tag("system")
                Text("Clara").tag("light")
                Text("Oscura").tag("dark")
            }.pickerStyle(.segmented)
            Picker("Fuente monoespaciada", selection: $fontName) {
                Text("Sistema (monoespaciada)").tag("system")
                ForEach(NiaMonospaceFonts.installed) { font in
                    Text(font.title).tag(font.name)
                }
            }
            HStack {
                Text("Tamaño de fuente")
                Slider(value: $size, in: 9...32, step: 1)
                Text("\(Int(size)) pt").monospacedDigit().frame(width: 48)
            }
            HStack {
                Text("Vista previa").foregroundStyle(.secondary)
                Spacer()
                Text("Nia ➜ git status  0123456789")
                    .font(fontName == "system"
                        ? .system(size: size, design: .monospaced)
                        : .custom(fontName, size: size))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Picker("Forma del cursor", selection: $cursorShape) {
                Text("Barra vertical").tag("bar")
                Text("Bloque").tag("block")
                Text("Subrayado").tag("underline")
            }
            Toggle("Cursor parpadeante", isOn: $blink)
            HStack {
                Text("Opacidad del panel")
                Slider(value: $opacity, in: 0.55...1.0)
                Text("\(Int(opacity * 100)) %").monospacedDigit().frame(width: 48)
            }
            Text("Transparencia experimental: el área Metal utiliza alfa real; la barra de título permanece nativa y opaca.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
struct TerminalSettings: View {
    @AppStorage("nia.scrollbackLines") private var scrollbackLines = 10000
    var body: some View {
        Form {
            LabeledContent("Shell") { Text("Shell del usuario").foregroundStyle(.secondary) }
            LabeledContent("Historial") { Text("Por sesión · SQLite").foregroundStyle(.secondary) }
            Picker("Scrollback en memoria", selection: $scrollbackLines) {
                Text("1.000 líneas").tag(1000)
                Text("5.000 líneas").tag(5000)
                Text("10.000 líneas").tag(10000)
                Text("25.000 líneas").tag(25000)
                Text("50.000 líneas").tag(50000)
                Text("100.000 líneas").tag(100000)
            }
            Text("El límite se aplica a las sesiones abiertas en el próximo inicio de Nia. El historial guardado en disco no se borra al cambiarlo.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Entornos Python") { Text("Restauración de venv disponible").foregroundStyle(.secondary) }
            Text("La terminal conserva los hooks Zsh y los archivos de historial de versiones anteriores.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
struct BackupSettings: View {
    var body: some View {
        Form {
            Label("Copias de seguridad cifradas con restic", systemImage: "lock.shield")
            Text("Esta primera versión nativa conserva el motor de backup, pero todavía no integra su configuración ni ejecución en SwiftUI.")
                .foregroundStyle(.secondary)
            Text("Puedes seguir usando nia-backup desde Terminal y restaurar tus sesiones existentes.")
                .font(.caption)
        }.formStyle(.grouped)
    }
}

private extension Color {
    init(hexRGB: String) {
        let h = hexRGB.hasPrefix("#") ? String(hexRGB.dropFirst()) : hexRGB
        let v = UInt32(h, radix: 16) ?? 0x648ACA
        self.init(.sRGB, red: Double((v >> 16) & 255)/255, green: Double((v >> 8) & 255)/255, blue: Double(v & 255)/255, opacity: 1)
    }
}


/// Native drag-and-drop with a visible insertion line above or below the row.
private struct SessionDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var hovering: String?
    @Binding var after: Bool
    let reorder: (String, String, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil && dragging != target && info.hasItemsConforming(to: [UTType.utf8PlainText])
    }
    func dropEntered(info: DropInfo) { hovering = target }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hovering = target
        after = info.location.y > 21  // midpoint of the approximately 42pt session row
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if hovering == target { hovering = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; hovering = nil; after = false }
        guard let dragging, dragging != target else { return false }
        reorder(dragging, target, after)
        return true
    }
}

/// The window must be non-opaque for the Metal drawable's alpha to reveal
/// the desktop. That also makes the *window* background transparent, including
/// the native titlebar. Put a separate solid layer behind the native titlebar
/// controls; do not extend terminal content into that region.
private final class NiaTitlebarBackdrop: NSView {
    override var isOpaque: Bool { true }
    // The titlebar backdrop must participate in hit testing so the native
    // titlebar can be dragged. Returning nil made the region inert.
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }
    func refreshColor() {
        // NSColor has no resolvedColor(with:) API on macOS. Resolve the
        // dynamic system color under this view's effective appearance.
        var background: NSColor = .windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)
                ?? NSColor.windowBackgroundColor
        }
        layer?.backgroundColor = background.cgColor
    }
}

private final class NiaTransparencyHost: NSView {
    var requestedOpacity: Double = 1.0 { didSet { configureWindow() } }
    private weak var hostedWindow: NSWindow?
    private var backdrop: NiaTitlebarBackdrop?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if hostedWindow !== window {
            backdrop?.removeFromSuperview()
            backdrop = nil
            hostedWindow = window
        }
        configureWindow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backdrop?.refreshColor()
    }

    private func installBackdrop(in window: NSWindow) {
        guard let content = window.contentView, let frameView = content.superview else { return }
        if backdrop?.superview !== frameView {
            backdrop?.removeFromSuperview()
            let newBackdrop = NiaTitlebarBackdrop(frame: .zero)
            newBackdrop.wantsLayer = true
            newBackdrop.refreshColor()
            // Behind the ordinary titlebar controls and below the content view.
            frameView.addSubview(newBackdrop, positioned: .below, relativeTo: content)
            backdrop = newBackdrop
        }
        guard let backdrop else { return }
        let totalHeight = frameView.bounds.height
        let titleHeight = max(0, min(totalHeight,
            window.frame.height - window.contentLayoutRect.height))
        let y = frameView.isFlipped ? 0 : totalHeight - titleHeight
        backdrop.frame = NSRect(x: 0, y: y, width: frameView.bounds.width, height: titleHeight)
        backdrop.autoresizingMask = frameView.isFlipped ? [.width, .maxYMargin] : [.width, .minYMargin]
        backdrop.refreshColor()
    }

    private func configureWindow() {
        guard let window else { return }
        let transparent = requestedOpacity < 0.999
        window.titlebarAppearsTransparent = false
        // Keep the standard NSWindow titlebar visible and unmanaged.
        // Do not modify styleMask or hide the toolbar from an NSView host.
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .windowBackgroundColor
        installBackdrop(in: window)
        backdrop?.isHidden = !transparent
    }
}
private struct NiaWindowTransparency: NSViewRepresentable {
    let opacity: Double
    func makeNSView(context: Context) -> NiaTransparencyHost { NiaTransparencyHost(frame: .zero) }
    func updateNSView(_ view: NiaTransparencyHost, context: Context) {
        view.requestedOpacity = opacity
    }
}
