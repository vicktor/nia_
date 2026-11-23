// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    let cwd: String
    let closed: Bool
    let venv: String?
    let color: String
    let remote_host: String?
}
struct TerminalCell: Decodable, Equatable {
    let t: String
    let fg: Int32
    let bg: Int32
    let flags: UInt8
    let wide: Bool
    let continuation: Bool
}
struct ScreenSnapshot: Decodable {
    let session_id: String
    let cells: [[TerminalCell]]
    let cursor_row: UInt16
    let cursor_col: UInt16
    let cursor_visible: Bool
    let rows: UInt16
    let cols: UInt16
    let scrollback_offset: Int
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
    private var pendingAIRequests: [NiaAIQuery] = []
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    private var timer: Timer?
    private var previousScreenBySession: [String: String] = [:]
    private var paneSizes: [String: (rows: Int, columns: Int)] = [:]

    init() {
        handle = NiaSharedCore.handle
        guard let handle else { error = "No se pudo abrir la base de datos de Nia"; return }
        let saved = UserDefaults.standard.object(forKey: "nia.scrollbackLines") as? Int ?? 10000
        _ = nia_set_scrollback_limit(handle, UInt32(clamping: min(100000, max(1000, saved))))
        refreshSessions()
        let poll = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }
    deinit {
        timer?.invalidate()
        // Core lifetime belongs to this process. macOS tears it down at exit.
    }
    private func resultString(_ value: UnsafeMutablePointer<CChar>?) -> String {
        guard let value else { return "" }
        defer { nia_string_free(value) }
        return String(cString: value)
    }
    private func report(_ code: Int32) -> Bool {
        guard code == 0 else { error = resultString(nia_last_error(handle)); return false }
        error = nil
        return true
    }
    func refreshSessions() {
        guard let handle else { return }
        let value = resultString(nia_sessions(handle))
        if let data = value.data(using: .utf8), let entries = try? JSONDecoder().decode([SessionEntry].self, from: data) {
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
        if status != 0 { error = resultString(nia_last_error(handle)) }
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
        let candidates = saved?.tabs ?? (migrate
            ? sessions.filter { !$0.closed }.map(\.id)
            : [saved?.primary, saved?.secondary].compactMap { $0 })
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
        for id in [selected, splitMode == "off" ? nil : secondary].compactMap({ $0 }) {
            if report(id.withCString({ nia_open_session(handle, $0) })) {
                prepareScreen(for: id)
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
    func requestFocus(_ id: String) {
        focusSession = id
        focusEpoch &+= 1
    }
    func activate(_ name: String) {
        guard let handle, let windowID else { return }
        let adding = !tabIDs.contains(name)
        if adding && !NiaSharedCore.claim(name, window: windowID) {
            error = "Esta sesión está abierta en otra ventana. Ciérrala allí para trasladarla."
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
        previousScreenBySession.removeValue(forKey: name)
        paneSizes.removeValue(forKey: name)
        if secondary == name { secondary = nil; splitMode = "off"; activePane = 0 }
        if selected == name { selected = tabIDs.first }
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
            error = "Esta sesión pertenece a otra ventana."
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
    func selectSlot(_ number: Int) {
        if tabIDs.indices.contains(number) { activate(tabIDs[number]) }
    }
    func send(_ bytes: [UInt8], to id: String) {
        guard let handle, !bytes.isEmpty else { return }
        _ = bytes.withUnsafeBufferPointer { buffer in
            id.withCString { nia_send(handle, $0, buffer.baseAddress, buffer.count) }
        }
    }
    func scroll(lines: Int, session id: String) {
        guard let handle, lines != 0 else { return }
        _ = id.withCString { nia_scroll(handle, $0, Int32(clamping: lines)) }
        refreshScreen(for: id)
    }
    func resize(rows: Int, columns: Int, session id: String) {
        guard let handle else { return }
        let r = max(1, rows), c = max(1, columns)
        if let prev = paneSizes[id], prev.rows == r && prev.columns == c { return }
        paneSizes[id] = (r, c)
        // Critical: inform the PTY of the real column count immediately.
        // Debouncing this call made new output wrap to the old width.
        let status = id.withCString {
            nia_resize_fast(handle, $0, UInt16(clamping: r), UInt16(clamping: c))
        }
        if status != 0 { _ = report(status); return }
        refreshScreen(for: id)

        // Do not replay the ANSI log over a live shell. Resize is immediate,
        // and applications redraw when notified by the PTY's SIGWINCH.
    }
    private func prepareScreen(for id: String) {
        guard let handle else { return }
        if let size = paneSizes[id] {
            _ = id.withCString { nia_resize(handle, $0, UInt16(clamping: size.rows), UInt16(clamping: size.columns)) }
        }
        nia_poll(handle)
        let raw = id.withCString { resultString(nia_screen(handle, $0)) }
        guard let data = raw.data(using: .utf8),
              let snap = try? JSONDecoder().decode(ScreenSnapshot.self, from: data),
              snap.session_id == id else { return }
        previousScreenBySession[id] = raw
        frames[id] = snap
        revisions[id, default: 0] &+= 1
    }
    private func refreshScreen(for id: String) {
        guard let handle else { return }
        let raw = id.withCString { resultString(nia_screen(handle, $0)) }
        guard raw != previousScreenBySession[id],
              let data = raw.data(using: .utf8),
              let snap = try? JSONDecoder().decode(ScreenSnapshot.self, from: data),
              snap.session_id == id else { return }
        previousScreenBySession[id] = raw
        frames[id] = snap
        revisions[id, default: 0] &+= 1
    }
    func showNextAIRequest() {
        guard aiRequest == nil, !pendingAIRequests.isEmpty else { return }
        aiRequest = pendingAIRequests.removeFirst()
    }
    private func tick() {
        guard let handle, windowID != nil else { return }
        nia_poll(handle)
        refreshSessions()
        let payload = resultString(nia_take_ai_queries(handle))
        if let data = payload.data(using: .utf8),
           let incoming = try? JSONDecoder().decode([NiaAIQuery].self, from: data) {
            NiaSharedCore.aiQueue.append(contentsOf: incoming)
        }
        let own = NiaSharedCore.aiQueue.filter { tabIDs.contains($0.session_id) }
        NiaSharedCore.aiQueue.removeAll { tabIDs.contains($0.session_id) }
        pendingAIRequests.append(contentsOf: own)
        showNextAIRequest()
        if let selected { refreshScreen(for: selected) }
        if splitMode != "off", let secondary, secondary != selected {
            refreshScreen(for: secondary)
        }
    }
}

private struct NiaWindowRoot: View {
    @SceneStorage("nia.workspace.identity") private var windowID = UUID().uuidString
    @StateObject private var model = NiaModel()

    var body: some View {
        MainWindow()
            .environmentObject(model)
            .focusedSceneValue(\.niaWindowModel, model)
            .frame(minWidth: 720, minHeight: 420)
            .onAppear { model.configureWindow(windowID) }
            .onDisappear { model.detachWindow() }
    }
}
@main struct NiaApp: App {
    @FocusedValue(\.niaWindowModel) private var focusedModel
    var body: some Scene {
        // WindowGroup supplies the native Cmd+N action.
        WindowGroup("nia_") {
            NiaWindowRoot()
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Acerca de nia_") {
                    let github = URL(string: "https://github.com/vicktor/nia_")!
                    let text = NSMutableAttributedString(string: "Source / Código: github.com/vicktor/nia_ · MPL-2.0")
                    let range = (text.string as NSString).range(of: "github.com/vicktor/nia_")
                    text.addAttribute(.link, value: github, range: range)
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "nia_",
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.6.0",
                        .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
                        .credits: text
                    ])
                }
                Button("Repositorio de nia_ en GitHub") {
                    if let url = URL(string: "https://github.com/vicktor/nia_") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Mostrar/ocultar sesiones") {
                    if let model = focusedModel {
                        model.sidebarVisibility = model.sidebarVisibility == .detailOnly ? .all : .detailOnly
                    }
                }.keyboardShortcut("b", modifiers: .command)
                Divider()
                ForEach(0..<9, id: \.self) { index in
                    Button("Sesión \(index + 1)") { focusedModel?.selectSlot(index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index+1))), modifiers: .command)
                }
            }
        }
        Settings { NiaSettings() }
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
    @State private var showRemoteSetup = false
    @State private var remoteName = ""
    @State private var remoteHost = ""
    @State private var filter = ""
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
                        ForEach(model.visibleSessions.filter { filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter) }) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.closed ? "archivebox" : (item.remote_host == nil ? "terminal" : "network"))
                                    .foregroundStyle(Color(hexRGB: item.color))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.id).lineLimit(1)
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
                                Button(item.closed ? "Abrir sesión" : "Cambiar a sesión") { model.activate(item.id) }
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
                    Button { showRemoteSetup = true } label: { Image(systemName: "network") }
                        .buttonStyle(.bordered).help("Nueva sesión SSH remota")
                    Menu {
                        ForEach(model.sessions.filter { !model.tabIDs.contains($0.id) }) { item in
                            Button(item.id) { model.activate(item.id) }
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help("Abrir sesión guardada en esta ventana")
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
            .background(Color.clear)
        }
        .background(NiaWindowTransparency(opacity: terminalOpacity))
        .navigationTitle(model.selected ?? "nia_")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Dividir terminal", selection: Binding(
                    get: { model.splitMode }, set: { model.setSplit($0) }
                )) {
                    Label("Una sesión", systemImage: "rectangle").tag("off")
                    Label("Lado a lado", systemImage: "rectangle.split.2x1").tag("vertical")
                    Label("Arriba y abajo", systemImage: "rectangle.split.1x2").tag("horizontal")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
                .help("Disposición de terminales")
            }
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
                    Text(session).font(.caption).foregroundStyle(.secondary)
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
                .frame(minWidth: 180, minHeight: 100)
        }
    }
    private func create() {
        model.create(newSession)
        newSession = ""
        addingSession = false
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
    @AppStorage("nia.restoreSessions") private var restore = true
    @AppStorage("nia.copyOnSelect") private var copy = true
    var body: some View {
        Form {
            Toggle("Restaurar sesiones al abrir Nia", isOn: $restore)
            Toggle("Copiar automáticamente al seleccionar", isOn: $copy)
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
        window.styleMask.remove(.fullSizeContentView)
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
