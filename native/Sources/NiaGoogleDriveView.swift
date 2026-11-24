// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI

@MainActor final class NiaGoogleDriveAccount: ObservableObject {
    static let shared = NiaGoogleDriveAccount()
    @Published private(set) var authorized = UserDefaults.standard.bool(forKey:"nia.google.authorized")
    @Published private(set) var busy = false
    @Published private(set) var spaces: [NiaDriveFile] = []
    @Published private(set) var message = ""
    private var login: Task<Void,Never>?
    private var loopback: NiaGoogleLoopback?
    var configured: Bool { Bundle.main.url(forResource:"GoogleOAuthClient",withExtension:"json") != nil }
    func connect() {
        guard !busy, !NiaSync.shared.busy else { return }
        busy = true; message = NiaL10n.string("Autoriza a nia_ en el navegador y vuelve a esta ventana.")
        login = Task {
            defer { busy = false; login = nil; loopback = nil }
            do {
                let client = try NiaGoogleClient.bundled(), pkce = NiaGooglePKCE()
                let receiver = NiaGoogleLoopback(pkce:pkce); loopback = receiver
                defer { receiver.cancel() }
                let redirect = try await receiver.start()
                try Task.checkCancellation()
                guard NSWorkspace.shared.open(try pkce.authorizationURL(clientID:client.clientID,redirect:redirect)) else { throw NiaDriveError.response }
                let code = try await receiver.code()
                try Task.checkCancellation()
                try await NiaGoogleAuthorization.shared.authorize(client:client,code:code,verifier:pkce.verifier,redirect:redirect)
                authorized = true; UserDefaults.standard.set(true,forKey:"nia.google.authorized")
                spaces = try await NiaGoogleDriveAPI().spaces()
                message = NiaL10n.string("Google conectado. Elige un espacio existente o crea uno nuevo.")
            } catch { message = NiaL10n.string(error is CancellationError ? NiaDriveError.cancelled.rawValue : error.localizedDescription) }
        }
    }
    func cancel() { loopback?.cancel(); login?.cancel() }
    func refresh() {
        guard authorized, !busy else { return }; busy = true
        login = Task {
            defer { busy = false; login = nil }
            do { spaces = try await NiaGoogleDriveAPI().spaces(); message = "" }
            catch { message = NiaL10n.string(error.localizedDescription) }
        }
    }
    func disconnect() {
        guard !busy, !NiaSync.shared.busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await NiaGoogleAuthorization.shared.disconnect()
                if NiaSync.shared.isGoogleDrive { NiaSync.shared.disconnect() }
                authorized = false; spaces = []; UserDefaults.standard.set(false,forKey:"nia.google.authorized")
                message = NiaL10n.string("Google se ha desconectado de este Mac. Las copias en Drive se conservan.")
            } catch { message = error.localizedDescription }
        }
    }
}

struct NiaGoogleDriveSetup: View {
    @ObservedObject private var account = NiaGoogleDriveAccount.shared
    @ObservedObject private var sync = NiaSync.shared
    @State private var chosen = ""
    @State private var newSpace = false
    @State private var name = "Nia Sync"
    @State private var key = ""
    @State private var keyCopied = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Conecta Google y comparte sesiones sin instalar Drive para escritorio. nia_ accede únicamente a los archivos que utiliza con tu autorización.")
            if !account.configured { Text("Esta compilación no incluye la configuración de Google Drive.").foregroundStyle(.secondary) }
            HStack {
                Button(LocalizedStringKey(account.authorized ? "Reconectar Google" : "Conectar con Google"),action:account.connect)
                    .disabled(account.busy || sync.busy || !account.configured)
                if account.busy { Button("Cancelar",action:account.cancel).disabled(sync.busy) }
                if account.authorized {
                    Button("Actualizar carpetas",action:account.refresh).disabled(account.busy || sync.busy)
                    Button("Desconectar Google",action:account.disconnect).disabled(account.busy || sync.busy)
                }
            }
            if account.busy { ProgressView().controlSize(.small) }
            if !account.message.isEmpty { Text(account.message).font(.caption).foregroundStyle(.secondary) }
            if account.authorized {
                Toggle("Crear un espacio nuevo en Google Drive",isOn:$newSpace)
                    .onChange(of:newSpace) { _,value in key = value ? NiaSyncEngine.newKey() : ""; keyCopied = false }
                if newSpace {
                    TextField("Nombre de la carpeta",text:$name)
                    Text("Copia esta clave y guárdala antes de continuar. El otro Mac necesitará la misma carpeta y la misma clave.").font(.caption)
                    HStack {
                        SecureField("Clave de sincronización",text:$key)
                        Button("Copiar clave") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key,forType:.string); keyCopied = true
                        }
                        if keyCopied { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Clave copiada") }
                    }
                    Button("Crear espacio y conectar") { sync.connectGoogle(folder:nil,name:name,key:key) }
                        .disabled(key.isEmpty || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || account.busy || sync.busy)
                } else {
                    Picker("Carpeta de sincronización",selection:$chosen) {
                        Text("Selecciona un espacio").tag("")
                        ForEach(account.spaces) { Text($0.name).tag($0.id) }
                    }
                    if account.spaces.isEmpty { Text("No hay espacios de nia_ en esta cuenta. Crea uno en el primer Mac.").font(.caption).foregroundStyle(.secondary) }
                    SecureField("Pega la clave del primer Mac",text:$key)
                    Button("Conectar con la clave") {
                        if let folder = account.spaces.first(where:{$0.id == chosen}) { sync.connectGoogle(folder:folder,name:folder.name,key:key) }
                    }.disabled(chosen.isEmpty || key.isEmpty || account.busy || sync.busy)
                }
                Text("Se muestran las carpetas de sincronización creadas por nia_. Usa la misma cuenta de Google y la misma clave en el otro Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { if account.authorized { account.refresh() } }
            .disabled(sync.busy)
    }
}
