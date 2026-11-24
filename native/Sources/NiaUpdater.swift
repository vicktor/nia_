// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

@MainActor final class NiaUpdater: ObservableObject {
    static let shared = NiaUpdater()
    enum Phase { case idle, checking, current, available, downloading, ready, installing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidate: NiaUpdateCandidate?
    @Published private(set) var errorMessage: String?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private var service: NiaUpdateService {
        NiaUpdateService(allowGitHubCLI: UserDefaults.standard.object(forKey: "nia.updates.githubCLI") as? Bool ?? true)
    }
    private var prepared: NiaPreparedUpdate?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var controller: NSWindowController?
    private var pendingPresentation = false
    private var beforeInstall: (() throws -> Void)?
    private var started = false
    var busy: Bool { phase == .checking || phase == .downloading || phase == .installing }

    func start(beforeInstall: @escaping () throws -> Void) {
        guard !started else { return }
        started = true
        self.beforeInstall = beforeInstall
        UserDefaults.standard.register(defaults: ["nia.updates.automatic": true, "nia.updates.previews": true])
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.pendingPresentation == true { self?.showWindow() }
                }
            }
        readInstallationResult()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "nia.updates.automatic"), !busy, prepared == nil,
              Date().timeIntervalSince1970 - defaults.double(forKey: "nia.updates.lastAttempt") >= 86400 else { return }
        check(manual: false)
    }

    func check(manual: Bool = true) {
        if manual { showWindow() }
        guard !busy, prepared == nil else { return }
        phase = .checking
        errorMessage = nil
        let previews = UserDefaults.standard.object(forKey: "nia.updates.previews") as? Bool ?? true
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "nia.updates.lastAttempt")
        task = Task {
            do {
                let available = try await service.candidate(current: currentVersion, previews: previews)
                try Task.checkCancellation()
                candidate = available
                phase = candidate == nil ? .current : .available
                if candidate != nil && !manual { presentWhenActive() }
            } catch {
                phase = .idle
                errorMessage = message(error)
            }
            task = nil
        }
    }

    func download() {
        guard let candidate, !busy else { return }
        phase = .downloading
        errorMessage = nil
        task = Task {
            do {
                prepared = try await service.prepare(candidate)
                phase = .ready
            } catch {
                phase = .available
                if !Task.isCancelled { errorMessage = message(error) }
            }
            task = nil
        }
    }

    func cancelDownload() { task?.cancel() }

    func install() {
        guard let prepared, let candidate, !busy else { return }
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let pid = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: "dev.nia.terminal").contains(where: {
            $0.processIdentifier != pid && $0.bundleURL?.resolvingSymlinksInPath() == destination
        }) {
            errorMessage = NiaL10n.string(NiaUpdateError.running.rawValue)
            return
        }
        phase = .installing
        errorMessage = nil
        task = Task {
            var job: NiaUpdateJob?
            do {
                let from = currentVersion
                job = try await Task.detached {
                    try NiaUpdateService.stage(prepared, destination: destination, from: from,
                                               to: candidate.version, parentPID: pid)
                }.value
                guard let job else { throw NiaUpdateError.install }
                guard let beforeInstall else { throw NiaUpdateError.history }
                try beforeInstall()
                let process = Process()
                process.executableURL = job.directory.appendingPathComponent("installer")
                process.arguments = [job.manifestURL.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                UserDefaults.standard.set(job.directory.path, forKey: "nia.updates.pendingDirectory")
                try process.run()
                try? FileManager.default.removeItem(at: prepared.directory)
                self.prepared = nil
                NSApp.terminate(nil)
                // If another component cancels termination, the helper times out.
                // Keep the UI responsive and report that result without killing it.
                while process.isRunning { try await Task.sleep(for: .seconds(1)) }
                readInstallationResult()
                phase = .available
            } catch {
                if let job { try? FileManager.default.removeItem(at: job.directory) }
                UserDefaults.standard.removeObject(forKey: "nia.updates.pendingDirectory")
                phase = .ready
                errorMessage = message(error)
            }
            task = nil
        }
    }

    private func message(_ error: Error) -> String {
        if let update = error as? NiaUpdateError { return NiaL10n.string(update.rawValue) }
        if let url = error as? URLError { return url.localizedDescription }
        return NiaL10n.string(NiaUpdateError.response.rawValue)
    }

    private func readInstallationResult() {
        guard let path = UserDefaults.standard.string(forKey: "nia.updates.pendingDirectory") else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")),
              let job = try? JSONDecoder().decode(NiaUpdateJob.self, from: data),
              (try? job.validatePaths()) != nil,
              job.destination == Bundle.main.bundleURL.resolvingSymlinksInPath(),
              let resultData = try? Data(contentsOf: job.resultURL),
              let result = try? JSONDecoder().decode(NiaUpdateResult.self, from: resultData) else { return }
        UserDefaults.standard.removeObject(forKey: "nia.updates.pendingDirectory")
        if !result.success {
            errorMessage = NiaL10n.string(result.message ?? NiaUpdateError.install.rawValue)
            presentWhenActive()
        }
        // Retain the rollback copy until a process from the new version starts.
        if !result.success || currentVersion == job.toVersion { try? FileManager.default.removeItem(at: directory) }
    }

    private func presentWhenActive() {
        if NSApp.isActive { showWindow() }
        else { pendingPresentation = true }
    }

    func showWindow() {
        pendingPresentation = false
        if controller == nil {
            let view = NiaUpdateView(updater: self)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = NiaL10n.string("Actualizaciones de nia_")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }
}

struct NiaUpdateView: View {
    @ObservedObject var updater: NiaUpdater
    @AppStorage("nia.language") private var language = "system"
    @State private var confirmInstall = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Actualizaciones de nia_", systemImage: "arrow.down.circle")
                .font(.title2.weight(.semibold))
            Text("Versión instalada: \(updater.currentVersion)").foregroundStyle(.secondary)
            if let candidate = updater.candidate {
                HStack {
                    Text("Versión disponible: \(candidate.version)").font(.headline)
                    if candidate.release.prerelease { Text("Preliminar").font(.caption).foregroundStyle(.secondary) }
                }
                if let notes = candidate.release.body, !notes.isEmpty {
                    ScrollView {
                        Text(verbatim: notes)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A maximum alone lets the hosting window collapse this
                    // viewport to one line. Reserve room for at least ten.
                    .frame(height: 240)
                }
            }
            if let error = updater.errorMessage {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            switch updater.phase {
            case .checking: ProgressView("Buscando actualizaciones…")
            case .downloading: ProgressView("Descargando y verificando…")
            case .installing: ProgressView("Preparando el reinicio…")
            case .current: Text("Ya tienes la versión más reciente del canal seleccionado.")
            case .ready: Text("La actualización está verificada y lista para instalar.")
            default: EmptyView()
            }
            HStack {
                Link("Ver releases en GitHub", destination: URL(string: "https://github.com/vicktor/nia_/releases")!)
                Spacer()
                if updater.phase == .available {
                    Button("Descargar actualización") { updater.download() }.keyboardShortcut(.defaultAction)
                } else if updater.phase == .ready {
                    Button("Instalar y reiniciar…") { confirmInstall = true }.keyboardShortcut(.defaultAction)
                } else if updater.phase == .downloading {
                    Button("Cancelar descarga") { updater.cancelDownload() }
                } else if !updater.busy {
                    Button("Buscar de nuevo") { updater.check() }
                }
            }
        }
        .padding(24).frame(width: 680)
        .environment(\.locale, language == "system" ? Locale.autoupdatingCurrent : Locale(identifier: language))
        .alert("¿Instalar y reiniciar nia_?", isPresented: $confirmInstall) {
            Button("Cancelar", role: .cancel) { }
            Button("Instalar y reiniciar") { updater.install() }
        } message: {
            Text("Se cerrarán todas las ventanas de esta instancia y terminarán sus procesos locales. Se guardarán los historiales y las distribuciones antes de reiniciar. Termina primero los trabajos que tengas en marcha.")
        }
    }
}

struct NiaUpdateSettings: View {
    @AppStorage("nia.updates.githubCLI") private var githubCLI = true
    @AppStorage("nia.updates.automatic") private var automatic = true
    @AppStorage("nia.updates.previews") private var previews = true
    @ObservedObject private var updater = NiaUpdater.shared
    var body: some View {
        Form {
            LabeledContent("Versión instalada") { Text(updater.currentVersion) }
            Toggle("Buscar actualizaciones automáticamente", isOn: $automatic)
            Picker("Canal de actualizaciones", selection: $previews) {
                Text("Estables y preliminares").tag(true)
                Text("Solo estables").tag(false)
            }
            Toggle("Usar la sesión de GitHub CLI para repositorios privados", isOn: $githubCLI)
            Text("Si GitHub requiere acceso, nia_ utiliza gh con su sesión existente. No copia ni guarda su token. GitHub CLI debe estar instalado y conectado con gh auth login.")
                .font(.caption).foregroundStyle(.secondary)
            Text("nia_ consulta GitHub Releases una vez al día. La descarga y la instalación requieren tu confirmación.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Buscar actualizaciones…") { updater.check() }.disabled(updater.busy)
            Link("Ver releases en GitHub", destination: URL(string: "https://github.com/vicktor/nia_/releases")!)
        }.formStyle(.grouped)
    }
}
