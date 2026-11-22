// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import AppKit
import Foundation
import Security

// This capability is intentionally separate from the renderer. No model or
// networking service runs while AI is unused.
private enum NiaAIKeychain {
    static let service = "dev.nia.terminal.ai"

    static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ password: String, account: String) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if password.isEmpty {
            return SecItemDelete(match as CFDictionary) == errSecSuccess
                || read(account: account).isEmpty
        }
        let data = Data(password.utf8)
        let updated = SecItemUpdate(match as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var created = match
        created[kSecValueData as String] = data
        created[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(created as CFDictionary, nil) == errSecSuccess
    }
}

private struct NiaAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

private struct NiaClaudeResponse: Decodable {
    struct Block: Decodable { let type: String; let text: String? }
    let content: [Block]
}

private struct NiaGeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

private struct NiaOpenAIResponse: Decodable {
    struct Item: Decodable {
        struct Piece: Decodable { let type: String; let text: String? }
        let content: [Piece]?
    }
    let output: [Item]?
}

private enum NiaAIError: LocalizedError {
    case invalidEndpoint, missingKey, invalidAnswer, response(String), internalTooSmall
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "La URL debe ser HTTPS, o HTTP en localhost para un modelo local."
        case .missingKey: return "Configura la API key en Preferencias → IA."
        case .invalidAnswer: return "No se obtuvo un único comando fiable. Prueba un modelo más capaz y revisa manualmente la tarea."
        case .internalTooSmall: return "El modelo Interno (0,5B) solo crea comandos simples Bash/Zsh. Esta petición requiere un modelo mayor: selecciona Local con un modelo más capaz, OpenAI, Claude o Gemini en Preferencias → IA. No se ejecutó nada."
        case .response(let description): return description
        }
    }
}

// Fail closed: the tiny shell fine-tune is not a general assistant. This
// classification is for capability routing, never a security authorization.
// NiaAIExecutionPolicy remains the only auto-execution gate.
private enum NiaAICapability {
    static func internalCanAttempt(_ input: String) -> Bool {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
        guard !q.isEmpty, q.count <= 240 else { return false }
        let complex = ["cloudflare", "tunnel", "tunel", "proxy", "dns", "dominio",
                       "configura", "configurar", "instala", "instalar", "despliega",
                       "deploy", "docker compose", "kubernetes", "certificado", "ssh key",
                       "autenticacion", "firewall", "permiso", "script completo", "paso a paso",
                       "explica", "como creo", "como hago", "como configurar", "ayudame a"]
        if complex.contains(where: { q.contains($0) }) { return false }
        let simple = ["busca ", "buscar ", "encuentra ", "encontrar ", "lista ", "listar ",
                      "muestra ", "mostrar ", "cuantos ", "cuenta ", "archivos mas ",
                      "archivos mayores", "archivos grandes", "directorio actual",
                      "carpeta actual", "servidor web", "http server", "puerto ",
                      "find ", "ls ", "pwd", "du ", "grep "]
        return simple.contains(where: { q.contains($0) })
    }
}

private enum NiaAIClient {
    static let systemPrompt = """
        Eres Nia, un asistente que convierte peticiones en español o inglés en comandos de terminal para macOS.
        Devuelve UNICAMENTE un comando de shell, en una sola línea.
        No incluyas Markdown, explicaciones, comentarios, prefijos ni el signo del prompt.
        Usa utilidades macOS/BSD. No inventes opciones ni programas.
        No propongas comandos destructivos si existe una alternativa de lectura.
        Para un servidor HTTP local usa python3 -m http.server PUERTO --bind 127.0.0.1.
        No uses sudo, tuberías, sustitución de comandos, redirecciones ni encadenamientos.
        Si la petición requiere instalación, configuración de servicios, varios pasos,
        o no sabes el comando exacto, responde NO_COMMAND.
        """

    private static func modelName(_ provider: String, _ defaults: UserDefaults) -> String {
        let configured = defaults.string(forKey: "nia.aiModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty { return configured }
        switch provider {
        case "ollama": return "qwen2.5-coder:7b"
        case "anthropic": return "claude-sonnet-4-5"
        case "gemini": return "gemini-2.5-flash"
        default: return "gpt-4.1-mini"
        }
    }

    private static func validatedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else { throw NiaAIError.invalidEndpoint }
        return url
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (body, raw) = try await URLSession.shared.data(for: request)
        guard let response = raw as? HTTPURLResponse else {
            throw NiaAIError.response("No se recibió respuesta HTTP.")
        }
        guard (200..<300).contains(response.statusCode) else {
            // Do not expose upstream response bodies: they can contain secrets.
            throw NiaAIError.response("El proveedor devolvió HTTP \(response.statusCode). Comprueba modelo, endpoint y API key.")
        }
        return body
    }

    static func generate(_ question: String) async throws -> String {
        let settings = UserDefaults.standard
        let provider = settings.string(forKey: "nia.aiProvider") ?? "ollama"
        if provider == "internal" {
            guard NiaAICapability.internalCanAttempt(question) else { throw NiaAIError.internalTooSmall }
            let answer = try await NiaInternalAI.shared.generate(question, systemPrompt: systemPrompt)
            return try validate(answer)
        }
        let key = provider == "ollama" ? "" : NiaAIKeychain.read(account: provider)
        if provider != "ollama" && key.isEmpty { throw NiaAIError.missingKey }
        let model = modelName(provider, settings)
        let custom = (settings.string(forKey: "nia.aiBaseURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: String
        var payload: [String: Any]
        switch provider {
        case "anthropic":
            endpoint = "https://api.anthropic.com/v1/messages"
            payload = ["model": model, "max_tokens": 256,
                       "system": systemPrompt,
                       "messages": [["role": "user", "content": question]]]
        case "gemini":
            let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent"
            payload = ["systemInstruction": ["parts": [["text": systemPrompt]]],
                       "contents": [["role": "user", "parts": [["text": question]]]],
                       "generationConfig": ["maxOutputTokens": 256]]
        case "openai":
            endpoint = "https://api.openai.com/v1/responses"
            payload = ["model": model, "instructions": systemPrompt, "input": question,
                       "max_output_tokens": 256, "store": false]
        default:
            let defaultBase = provider == "ollama" ? "http://127.0.0.1:11434/v1" :
                              provider == "openrouter" ? "https://openrouter.ai/api/v1" : "https://api.openai.com/v1"
            let base = custom.isEmpty ? defaultBase : custom
            _ = try validatedURL(base)
            endpoint = base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
            payload = ["model": model, "stream": false,
                       "messages": [["role": "system", "content": systemPrompt],
                                    ["role": "user", "content": question]]]
        }
        let url = try validatedURL(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch provider {
        case "anthropic":
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case "gemini": request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case "ollama": break
        default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let body = try await send(request)
        let text: String
        switch provider {
        case "anthropic":
            text = try JSONDecoder().decode(NiaClaudeResponse.self, from: body)
                .content.filter { $0.type == "text" }.compactMap(\.text).joined()
        case "gemini":
            text = try JSONDecoder().decode(NiaGeminiResponse.self, from: body)
                .candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        case "openai":
            text = try JSONDecoder().decode(NiaOpenAIResponse.self, from: body)
                .output?.flatMap { $0.content ?? [] }.filter { $0.type == "output_text" }
                .compactMap(\.text).joined() ?? ""
        default:
            text = try JSONDecoder().decode(NiaAIChatResponse.self, from: body)
                .choices.first?.message.content ?? ""
        }
        return try validate(text)
    }

    private static func validate(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "NO_COMMAND", text.count <= 4000,
              !text.contains("\n"), !text.contains("\r"), !text.contains("```"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw NiaAIError.invalidAnswer }
        return text
    }
}

struct NiaAICommandSheet: View {
    let query: NiaAIQuery
    let onInsert: (String) -> Void
    let onAutoExecute: (String) -> Void
    let canAutoExecute: () -> Bool
    @AppStorage("nia.aiAutoExecuteReadOnly") private var autoExecute = true
    @Environment(\.dismiss) private var dismiss
    @State private var proposedCommand = ""
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Nia AI · \(query.session_id)", systemImage: "sparkles")
                .font(.headline)
            Text(query.question).font(.subheadline).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if loading {
                HStack(spacing: 10) { ProgressView(); Text("Generando comando…") }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                Text("Comando propuesto · editable").font(.caption).foregroundStyle(.secondary)
                TextField("Comando", text: $proposedCommand, axis: .vertical)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                if NiaAIExecutionPolicy.automaticCommand(proposedCommand) != nil {
                    Text("Comando permitido para ejecución automática; puedes ejecutarlo o insertarlo.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Acción no autorizada para ejecución automática. Revísala antes de ejecutarla.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insertar en terminal") {
                    guard !proposedCommand.isEmpty,
                          !proposedCommand.contains("\n"), !proposedCommand.contains("\r") else { return }
                    onInsert(proposedCommand)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || failure != nil || proposedCommand.isEmpty || proposedCommand.contains("\n"))
            }
        }
        .padding(22)
        .frame(width: 560)
        .task(id: query.id) {
            do {
                let generated = try await NiaAIClient.generate(query.question)
                proposedCommand = generated
                // Never execute a model result directly: classify it using an
                // independent, exact allowlist. Autoexecute only in the pane that
                // still owns the request, and never execute multiple lines.
                if autoExecute, canAutoExecute(),
                   let approved = NiaAIExecutionPolicy.automaticCommand(generated) {
                    onAutoExecute(approved)
                    dismiss()
                    return
                }
            } catch { failure = error.localizedDescription }
            loading = false
        }
    }
}

struct NiaAISettings: View {
    @AppStorage("nia.aiProvider") private var provider = "ollama"
    @AppStorage("nia.aiBaseURL") private var baseURL = ""
    @AppStorage("nia.aiModel") private var model = ""
    @State private var key = ""
    @State private var saved = false
    @AppStorage("nia.aiAutoExecuteReadOnly") private var autoExecute = true

    var body: some View {
        Form {
            Picker("Proveedor", selection: $provider) {
                Text("Interno · Nia (Metal)").tag("internal")
                Text("Local · API compatible").tag("ollama")
                Text("OpenAI · API oficial").tag("openai")
                Text("Claude (Anthropic) · API oficial").tag("anthropic")
                Text("Gemini (Google) · API oficial").tag("gemini")
                Text("OpenRouter").tag("openrouter")
                Text("API compatible con OpenAI").tag("compatible")
            }
            if provider == "internal" {
                NiaInternalAISettings()
            } else {
                if ["ollama", "openrouter", "compatible"].contains(provider) {
                    LabeledContent("Endpoint base") {
                        TextField("URL base", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    if provider == "ollama" {
                        Text("Compatible con Ollama, vLLM, LM Studio y llama.cpp si exponen /v1/chat/completions. URL predeterminada: http://127.0.0.1:11434/v1. Puedes cambiarla por la de tu servidor local.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Modelo") {
                    TextField(provider == "anthropic" ? "claude-sonnet-4-5" :
                              provider == "gemini" ? "gemini-2.5-flash" :
                              provider == "ollama" ? "qwen2.5-coder:7b" : "gpt-4.1-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if provider != "ollama" && provider != "internal" {
                LabeledContent("API key") {
                    SecureField("API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Guardar API key en Keychain") {
                        saved = NiaAIKeychain.save(key, account: provider)
                        if saved { key = "" }
                    }
                    if saved { Label("Guardada", systemImage: "checkmark.circle.fill") }
                }
            }
            Toggle("Ejecutar automáticamente comandos de lectura permitidos", isOn: $autoExecute)
            Text("Solo se ejecutan patrones permitidos y verificados, como find/ls/du. Los demás se revisan. El servidor HTTP interno se limita a localhost.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Escribe ? al comienzo de una línea de Zsh y pulsa Enter. Nia generará el comando.")
                .font(.caption).foregroundStyle(.secondary)
            Text(provider == "internal" ? "Modelo limitado: solo creación y ejecución de comandos simples Bash/Zsh. Para configuraciones, túneles, instalaciones o tareas de varios pasos, utiliza un modelo más grande (Local, OpenAI, Claude o Gemini). No inventaremos comandos para esas peticiones." : "Las consultas se envían únicamente al proveedor elegido. Las claves se guardan en Keychain, no en SQLite.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: provider) { _, _ in
            saved = false; key = ""; baseURL = ""; model = ""
        }
    }
}
