// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import AppKit

// Local model downloaded on demand. llama-server is packaged with Nia.app by
// scripts/build-native-macos.sh, and is never run as an always-on daemon.
@MainActor final class NiaInternalAI: ObservableObject {
    static let shared = NiaInternalAI()
    static let modelName = "kitty-bash-llm Q4_K_M · 0.5B"
    static let modelFilename = "kitty-bash-llm-q4_k_m.gguf"
    static let modelURL = URL(string: "https://huggingface.co/sahellx/kitty-bash-llm/resolve/main/kitty-bash-llm-q4_k_m.gguf?download=true")!
    private static let port = 19561

    @Published var isDownloading = false
    @Published var progress = 0.0
    @Published var isReady = false
    @Published var status = "No descargado"
    @Published var failure: String?

    private var process: Process?
    private var secret = UUID().uuidString + UUID().uuidString
    private var idleTask: Task<Void, Never>?
    private var stopObserver: NSObjectProtocol?
    private init() {
        isReady = FileManager.default.fileExists(atPath: modelPath.path)
        status = isReady ? "Modelo instalado" : "No descargado"
        stopObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            // No delayed tasks or network requests here: just terminate the local helper.
            MainActor.assumeIsolated { NiaInternalAI.shared.stop() }
        }
    }
    var modelPath: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Nia/Models", isDirectory: true)
            .appendingPathComponent(Self.modelFilename)
    }
    var modelIsInstalled: Bool { FileManager.default.fileExists(atPath: modelPath.path) }

    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        progress = 0
        failure = nil
        status = "Descargando modelo…"
        defer { isDownloading = false }
        do {
            let directory = modelPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let delegate = NiaDownloadProgress { [weak self] fraction in
                Task { @MainActor in self?.progress = fraction }
            }
            let (temporaryURL, response) = try await URLSession.shared.download(from: Self.modelURL, delegate: delegate)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw NiaLocalError.message("Error HTTP al descargar el modelo.")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 300_000_000 && bytes < 600_000_000 else {
                throw NiaLocalError.message("Tamaño de archivo GGUF inesperado.")
            }
            let f = try FileHandle(forReadingFrom: temporaryURL)
            let header = try f.read(upToCount: 4)
            try f.close()
            guard header == Data([0x47, 0x47, 0x55, 0x46]) else {
                throw NiaLocalError.message("El archivo descargado no parece un GGUF válido.")
            }
            let pending = directory.appendingPathComponent(Self.modelFilename + ".pending")
            try? FileManager.default.removeItem(at: pending)
            try FileManager.default.moveItem(at: temporaryURL, to: pending)
            try? FileManager.default.removeItem(at: modelPath)
            try FileManager.default.moveItem(at: pending, to: modelPath)
            isReady = true
            status = "Modelo instalado · \(Int(bytes / 1_000_000)) MB"
            progress = 1
        } catch {
            failure = error.localizedDescription
            status = "No disponible"
        }
    }

    func removeModel() {
        stop()
        do {
            try FileManager.default.removeItem(at: modelPath)
            isReady = false
            status = "No descargado"
        } catch { failure = error.localizedDescription }
    }

    private var serverURL: URL {
        URL(string: "http://127.0.0.1:\(Self.port)")!
    }
    private func ensureServer() async throws {
        guard modelIsInstalled else { throw NiaLocalError.message("Descarga el modelo desde Preferencias → IA.") }
        if process?.isRunning == true { return }
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("nia-llama-server"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NiaLocalError.message("No se encuentra el motor local. Reconstruye Nia.app con CMake instalado.")
        }
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--model", modelPath.path,
                       "--host", "127.0.0.1", "--port", String(Self.port),
                       "--ctx-size", "2048", "--n-gpu-layers", "all",
                       "--parallel", "1", "--no-webui", "--api-key", secret]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw NiaLocalError.message("No se pudo iniciar el motor local: \(error.localizedDescription)") }
        process = p
        status = "Iniciando motor Metal…"
        for _ in 0..<100 {
            if !p.isRunning { process = nil; throw NiaLocalError.message("El motor local terminó inesperadamente.") }
            var request = URLRequest(url: serverURL.appendingPathComponent("health"))
            request.timeoutInterval = 1
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                status = "Motor activo · Metal"
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stop()
        throw NiaLocalError.message("El motor local no ha arrancado. Comprueba el build de llama.cpp.")
    }
    func stop() {
        idleTask?.cancel()
        idleTask = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        status = modelIsInstalled ? "Modelo instalado (sin cargar)" : "No descargado"
    }
    private func scheduleIdleStop() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
    func generate(_ question: String, systemPrompt: String) async throws -> String {
        idleTask?.cancel()
        try await ensureServer()
        defer { scheduleIdleStop() }
        var request = URLRequest(url: serverURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 80
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.modelFilename,
            "messages": [
                ["role":"system", "content": systemPrompt],
                ["role":"user", "content": question]
            ],
            "stream": false,
            "temperature": 0.1,
            "max_tokens": 120
        ])
        let (data, raw) = try await URLSession.shared.data(for: request)
        guard let http = raw as? HTTPURLResponse, http.statusCode == 200 else {
            throw NiaLocalError.message("El motor interno devolvió un error HTTP.")
        }
        let response = try JSONDecoder().decode(NiaLocalChatResponse.self, from: data)
        guard let command = response.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty, command != "NO_COMMAND", command.count < 4000,
              !command.contains("\n"), !command.contains("\r"), !command.contains("```") else {
            throw NiaLocalError.message("El modelo no devolvió un comando válido de una línea.")
        }
        return command
    }
}

private struct NiaLocalChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}
private enum NiaLocalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
private final class NiaDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    init(_ onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }
}

struct NiaInternalAISettings: View {
    @StateObject private var engine = NiaInternalAI.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Modelo") {
                Text(NiaInternalAI.modelName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Tamaño") { Text("398 MB · GGUF Q4_K_M").foregroundStyle(.secondary) }
            LabeledContent("Inferencia") { Text("llama.cpp · Metal · bajo demanda").foregroundStyle(.secondary) }
            if engine.isDownloading { ProgressView(value: engine.progress) }
            HStack {
                if engine.modelIsInstalled {
                    Label(engine.status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Eliminar modelo") { engine.removeModel() }
                } else {
                    Button("Descargar modelo") { Task { await engine.download() } }
                        .disabled(engine.isDownloading)
                    Text(engine.isDownloading ? "Descargando…" : "Solo se descarga cuando lo solicitas")
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = engine.failure {
                Text(failure).foregroundStyle(.red).font(.caption)
            }
            Text("Modelo de 0,5B especializado en comandos simples Bash/Zsh. No es adecuado para Cloudflare Tunnel, despliegues, instalaciones ni configuraciones complejas. Nia te pedirá usar un modelo más potente en esos casos.")
                .foregroundStyle(.orange)
                .font(.callout)
            Text("Los comandos se generan íntegramente en este Mac. El motor se inicia al consultar y se detiene tras 90 segundos de inactividad.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Modelo y licencia Apache-2.0", destination: URL(string:"https://huggingface.co/sahellx/kitty-bash-llm")!)
        }
    }
}
