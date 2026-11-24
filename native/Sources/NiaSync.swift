// SPDX-License-Identifier: MPL-2.0
import AppKit
import SwiftUI
import Security

private enum NiaSyncKeychain {
    static func save(_ key: String, account: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.nia.terminal.sync",kSecAttrAccount as String:account]
        let values: [String:Any] = [kSecValueData as String:Data(key.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary,values as CFDictionary)
        if status == errSecItemNotFound {
            let add = SecItemAdd(query.merging(values) { _,new in new } as CFDictionary,nil)
            guard add == errSecSuccess else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(add)) }
        } else if status != errSecSuccess { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
    }
    static func read(account: String) throws -> String {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"dev.nia.terminal.sync",kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&value)
        guard status == errSecSuccess, let data = value as? Data, let key = String(data:data,encoding:.utf8) else { throw NSError(domain:NSOSStatusErrorDomain,code:Int(status)) }
        return key
    }
}

private struct NiaSyncLocal: Decodable, Identifiable, Sendable { let id: String; let title: String; let cwd: String }
private struct NiaSyncFailure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
private enum NiaSyncBridge {
    static func request(_ values: [String:String]) throws -> Data {
        let input = String(decoding:try JSONEncoder().encode(values),as:UTF8.self)
        guard let pointer = input.withCString({ nia_sync_request($0) }) else { throw NiaSyncError.invalid }
        defer { nia_string_free(pointer) }
        let data = Data(String(cString:pointer).utf8)
        if let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], let error = object["error"] as? String { throw NiaSyncFailure(message:error) }
        return data
    }
    static func export(_ id: String) throws -> NiaSyncSnapshot {
        let data = try request(["operation":"export","id":id])
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], let metadata = object["metadata"] else { throw NiaSyncError.invalid }
        func file(_ name: String) throws -> NiaSyncFile? {
            guard let value = object[name], !(value is NSNull) else { return nil }
            return try JSONDecoder().decode(NiaSyncFile.self,from:JSONSerialization.data(withJSONObject:value))
        }
        return try NiaSyncSnapshot(metadata:JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys]),transcript:file("transcript"),history:file("history"))
    }
}

@MainActor final class NiaSync: ObservableObject {
    static let shared = NiaSync()
    @Published private(set) var connected = !UserDefaults.standard.string(forKey:"nia.sync.space").orEmpty.isEmpty
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey:"nia.sync.enabled")
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var items: [NiaSyncItem] = []
    @Published fileprivate var local: [NiaSyncLocal] = []
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var directoryRequest: NiaSyncItem?
    private var timer: Timer?
    private var catalogBusy = false
    private var pendingGoogleCreation: (id:String,name:String,key:String)?
    var folderPath: String { UserDefaults.standard.string(forKey:"nia.sync.folder") ?? "" }
    var isGoogleDrive: Bool { UserDefaults.standard.string(forKey:"nia.sync.provider") == "googleDrive" }
    var locationLabel: String { isGoogleDrive ? "Google Drive · " + (UserDefaults.standard.string(forKey:"nia.sync.google.name") ?? "Nia Sync") : folderPath }
    private var selectedKey: String { "nia.sync.selected." + (UserDefaults.standard.string(forKey:"nia.sync.space") ?? "") }
    private static var cache: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("ember-terminal/sync",isDirectory:true) }
    private func configuration() throws -> (URL,String,String?) {
        guard connected, let space = UserDefaults.standard.string(forKey:"nia.sync.space") else { throw NiaSyncError.invalid }
        let drive = isGoogleDrive ? UserDefaults.standard.string(forKey:"nia.sync.google.folder") : nil
        if isGoogleDrive && (drive == nil || !NiaGoogleDriveAPI.validID(drive!)) { throw NiaSyncError.invalid }
        return (URL(fileURLWithPath:folderPath,isDirectory:true),try NiaSyncKeychain.read(account:space),drive)
    }
    func start() {
        guard timer == nil else { return }
        selected = Set(UserDefaults.standard.stringArray(forKey:selectedKey) ?? [])
        timer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { _ in Task { @MainActor in if self.enabled { self.synchronize() } } }
        if enabled { synchronize() }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value,forKey:"nia.sync.enabled")
        if value { synchronize() }
    }
    func select(_ id: String, _ value: Bool) {
        if value { selected.insert(id) } else { selected.remove(id) }
        UserDefaults.standard.set(Array(selected),forKey:selectedKey)
    }
    func refreshCatalog() {
        guard !catalogBusy else { return }; catalogBusy = true
        Task {
            defer { catalogBusy = false }
            do { local = try await Task.detached(priority:.utility) { try JSONDecoder().decode([NiaSyncLocal].self,from:NiaSyncBridge.request(["operation":"catalog"])) }.value }
            catch { message = error.localizedDescription }
        }
    }
    func connect(folder: URL, key: String, create: Bool) {
        guard !busy else { return }; busy = true; message = NiaL10n.string("Preparando sincronización…")
        let cache = Self.cache
        Task {
            defer { busy = false }
            do {
                let space = try await Task.detached(priority:.utility) {
                    if create { try NiaSyncEngine.create(folder:folder,key:key) }
                    return try NiaSyncEngine(folder:folder,key:key,cache:cache).spaceID
                }.value
                try finishConnection(folder:folder,key:key,space:space,drive:nil,name:nil)
            } catch { message = NiaL10n.string(error.localizedDescription) }
        }
    }
    private func finishConnection(folder: URL, key: String, space: String, drive: String?, name: String?) throws {
        try NiaSyncKeychain.save(key.trimmingCharacters(in:.whitespacesAndNewlines),account:space)
        UserDefaults.standard.set(folder.path,forKey:"nia.sync.folder")
        UserDefaults.standard.set(space,forKey:"nia.sync.space")
        UserDefaults.standard.set(drive == nil ? "folder" : "googleDrive",forKey:"nia.sync.provider")
        UserDefaults.standard.set(drive,forKey:"nia.sync.google.folder")
        UserDefaults.standard.set(name,forKey:"nia.sync.google.name")
        UserDefaults.standard.set(true,forKey:"nia.sync.enabled")
        connected = true; enabled = true; items = []
        selected = Set(UserDefaults.standard.stringArray(forKey:selectedKey) ?? [])
        message = NiaL10n.string("Carpeta conectada. Selecciona las sesiones que quieres compartir.")
        refreshCatalog()
    }
    func connectGoogle(folder: NiaDriveFile?, name: String, key: String) {
        guard !busy else { return }; busy = true; message = NiaL10n.string("Preparando sincronización…")
        let cache = Self.cache, cleanKey = key.trimmingCharacters(in:.whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                // Validate the recovery key before creating anything in Drive.
                guard Data(base64Encoded:cleanKey)?.count == 32 else { throw NiaSyncError.key }
                let api = NiaGoogleDriveAPI()
                let selectedFolder: NiaDriveFile
                if let folder { selectedFolder = folder }
                else {
                    let id: String
                    if let pending = pendingGoogleCreation, pending.name == name, pending.key == cleanKey { id = pending.id }
                    else { id = try await api.generateID(); pendingGoogleCreation = (id,name,cleanKey) }
                    selectedFolder = try await api.createSpace(id:id,name:name.trimmingCharacters(in:.whitespacesAndNewlines))
                }
                let mirror = cache.appendingPathComponent("drive/" + selectedFolder.id,isDirectory:true)
                let creating = folder == nil
                let space = try await Task.detached(priority:.utility) {
                    let transport = try NiaGoogleDriveTransport(api:api,folderID:selectedFolder.id,mirror:mirror)
                    return try await transport.locked {
                        if creating {
                            if !FileManager.default.fileExists(atPath:mirror.appendingPathComponent("space.json").path) { try NiaSyncEngine.create(folder:mirror,key:cleanKey) }
                            try await transport.push(key:cleanKey,cache:cache)
                        } else { try await transport.pull(key:cleanKey,cache:cache) }
                        return try NiaSyncEngine(folder:mirror,key:cleanKey,cache:cache).spaceID
                    }
                }.value
                try finishConnection(folder:mirror,key:cleanKey,space:space,drive:selectedFolder.id,name:selectedFolder.name)
                pendingGoogleCreation = nil
                NiaGoogleDriveAccount.shared.refresh()
            } catch { message = NiaL10n.string(error.localizedDescription) }
        }
    }
    func copyKey() {
        do {
            let (_,key,_) = try configuration()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key,forType:.string)
            message = NiaL10n.string("Clave copiada. Guárdala en un lugar seguro para conectar el otro Mac.")
        } catch { message = error.localizedDescription }
    }
    func disconnect() {
        guard !busy else { return }
        setEnabled(false)
        UserDefaults.standard.removeObject(forKey:"nia.sync.space")
        UserDefaults.standard.removeObject(forKey:"nia.sync.folder")
        UserDefaults.standard.removeObject(forKey:"nia.sync.provider")
        UserDefaults.standard.removeObject(forKey:"nia.sync.google.folder")
        UserDefaults.standard.removeObject(forKey:"nia.sync.google.name")
        connected = false; items = []; selected = []; message = NiaL10n.string("Este Mac está desconectado. Las copias compartidas se conservan.")
    }
    func synchronize() {
        guard connected, !busy, !isGoogleDrive || !NiaGoogleDriveAccount.shared.busy else { return }
        let config: (URL,String,String?)
        do { config = try configuration() } catch { message = error.localizedDescription; return }
        let ids = Array(selected), cache = Self.cache, name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        busy = true; message = NiaL10n.string("Sincronizando…")
        Task {
            defer { busy = false }
            do {
                items = try await Task.detached(priority:.utility) {
                    if let id = config.2 {
                        let transport = try NiaGoogleDriveTransport(folderID:id,mirror:config.0)
                        return try await transport.locked {
                            try await transport.pull(key:config.1,cache:cache)
                            let items = try NiaSyncEngine(folder:config.0,key:config.1,cache:cache).synchronize(selected:ids,deviceName:name,export:NiaSyncBridge.export)
                            try await transport.push(key:config.1,cache:cache)
                            return items
                        }
                    }
                    return try NiaSyncEngine(folder:config.0,key:config.1,cache:cache).synchronize(selected:ids,deviceName:name,export:NiaSyncBridge.export)
                }.value
                message = NiaL10n.string(config.2 == nil ? "Carpeta actualizada. La entrega al otro Mac depende de iCloud Drive o Google Drive." : "Sincronización con Google Drive completada.")
                refreshCatalog()
            } catch { message = NiaL10n.string(error.localizedDescription) }
        }
    }
    func resume(_ item: NiaSyncItem, directory: URL? = nil, opened: @escaping (String) -> Void) {
        guard !busy else { return }
        let config: (URL,String,String?)
        do { config = try configuration() } catch { message = error.localizedDescription; return }
        let cache = Self.cache
        busy = true; directoryRequest = nil; message = NiaL10n.string("Preparando sesión en este Mac…")
        Task {
            defer { busy = false }
            do {
                let id = try await Task.detached(priority:.utility) {
                    try NiaSyncEngine(folder:config.0,key:config.1,cache:cache).restore(item) { stage,revision in
                        var request = ["operation":"import","stage":stage.path,"revision":revision]
                        if let directory { request["directory"] = directory.path }
                        let response = try JSONDecoder().decode([String:String].self,from:NiaSyncBridge.request(request))
                        guard let id = response["id"] else { throw NiaSyncError.invalid }; return id
                    }
                }.value
                select(id,true); refreshCatalog(); opened(id)
                message = NiaL10n.string("Sesión añadida a este Mac. Sus cambios también se compartirán.")
            } catch {
                if error.localizedDescription.contains("SYNC_DIRECTORY_REQUIRED") {
                    directoryRequest = item
                    message = NiaL10n.string("El directorio original no existe aquí. Elige la carpeta del proyecto en este Mac.")
                } else { message = NiaL10n.string(error.localizedDescription) }
            }
        }
    }
    func chooseDirectory(opened: @escaping (String) -> Void) {
        guard let item = directoryRequest else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = NiaL10n.string("Elige la carpeta del proyecto en este Mac.")
        panel.begin { response in
            if response == .OK, let url = panel.url { self.resume(item,directory:url,opened:opened) }
        }
    }
}
private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

struct NiaSyncSettings: View {
    @ObservedObject private var sync = NiaSync.shared
    @ObservedObject private var google = NiaGoogleDriveAccount.shared
    @State private var folder: URL?
    @State private var key = ""
    @State private var create = false
    @State private var provider = "folder"
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Label("Nia Sync · beta",systemImage:"icloud").font(.title2.bold())
                Text("Continúa tus sesiones en otro Mac mediante una carpeta de iCloud Drive o Google Drive. nia_ cifra el contenido antes de guardarlo.")
                if sync.connected {
                    Text(sync.locationLabel).font(.caption).textSelection(.enabled)
                    Toggle("Sincronizar automáticamente cada minuto",isOn:Binding(get:{sync.enabled},set:sync.setEnabled))
                    HStack {
                        Button("Sincronizar ahora",action:sync.synchronize)
                        Button("Copiar clave para otro Mac",action:sync.copyKey)
                        Button("Desconectar este Mac",action:sync.disconnect)
                    }.disabled(sync.busy)
                    if sync.isGoogleDrive {
                        HStack {
                            Button("Reconectar Google",action:google.connect).disabled(sync.busy || google.busy)
                            if google.busy { Button("Cancelar",action:google.cancel) }
                            else { Button("Desconectar Google",action:google.disconnect).disabled(sync.busy) }
                        }
                        Text(google.message).font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Sesiones que se comparten desde este Mac").font(.headline)
                    Text("Selecciona solo las sesiones que quieras compartir. El historial puede contener información privada. Desmarcar una sesión detiene nuevos envíos; las copias existentes se conservan.").font(.caption).foregroundStyle(.secondary)
                    ForEach(sync.local) { session in
                        Toggle(isOn:Binding(get:{sync.selected.contains(session.id)},set:{sync.select(session.id,$0)})) {
                            VStack(alignment:.leading) { Text(session.title); Text(session.cwd).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }.disabled(sync.busy)
                    }
                } else {
                    Picker("Servicio de sincronización",selection:$provider) {
                        Text("iCloud Drive / carpeta local").tag("folder")
                        Text("Google Drive directo").tag("googleDrive")
                    }.pickerStyle(.segmented).disabled(sync.busy)
                    if provider == "googleDrive" { NiaGoogleDriveSetup() }
                    else {
                        Button("Elegir carpeta compartida…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                            panel.message = NiaL10n.string("Elige iCloud Drive, Google Drive o una carpeta que ya se sincronice entre tus Macs. Se usará una subcarpeta Nia Sync.")
                            panel.begin { response in
                                guard response == .OK, let picked = panel.url else { return }
                                folder = picked.lastPathComponent == "Nia Sync" ? picked : picked.appendingPathComponent("Nia Sync",isDirectory:true)
                                key = ""; create = false
                            }
                        }.disabled(sync.busy)
                        if let folder {
                            Text(folder.path).font(.caption).textSelection(.enabled)
                            Toggle("Crear un espacio nuevo (solo en el primer Mac)",isOn:$create)
                                .onChange(of:create) { _, value in if value { key = NiaSyncEngine.newKey() } else { key = "" } }
                            if create {
                                Text("Copia esta clave y guárdala antes de continuar. El otro Mac necesitará la misma carpeta y la misma clave.").font(.caption)
                                HStack { SecureField("Clave de sincronización",text:$key); Button("Copiar clave") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key,forType:.string) } }
                            } else { SecureField("Pega la clave del primer Mac",text:$key) }
                            Button(LocalizedStringKey(create ? "Crear y conectar" : "Conectar con la clave")) { sync.connect(folder:folder,key:key,create:create) }.disabled(key.isEmpty || sync.busy)
                        }
                    }
                }
                if sync.busy { ProgressView().controlSize(.small) }
                Text(sync.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                Text(LocalizedStringKey(sync.isGoogleDrive || provider == "googleDrive" ? "nia_ debe estar abierta para sincronizar. La conexión directa sube y descarga las versiones cifradas mediante la API de Google Drive." : "nia_ debe estar abierta para sincronizar. En Google Drive, mantén esta carpeta disponible sin conexión. Espera a que el proveedor termine de sincronizar antes de cambiar de Mac.")).font(.caption)
                Text("Se comparten el historial ANSI, los comandos, el nombre, el color, el directorio y la identidad SSH/tmux. Los procesos locales, los proyectos, las credenciales y las conversaciones internas de Claude/Codex no se transfieren.").font(.caption).foregroundStyle(.secondary)
                Text("Si ambos Macs trabajan a la vez, se conservan sus versiones. Continuar crea una sesión local; no sustituye una sesión abierta. En esta beta, los borrados y la disposición de ventanas no se sincronizan.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.onAppear { sync.start(); sync.refreshCatalog() }
    }
}

struct NiaSyncBrowser: View {
    @ObservedObject private var sync = NiaSync.shared
    @Environment(\.dismiss) private var dismiss
    let opened: (String) -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Label("Sesiones compartidas",systemImage:"icloud").font(.title2.bold())
                Spacer()
                Button("Actualizar",action:sync.synchronize).disabled(sync.busy || !sync.connected)
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !sync.connected { NiaSyncSettings() }
            else {
                Text("Continúa una versión en este Mac. Las sesiones abiertas se conservan.").foregroundStyle(.secondary)
                if sync.items.isEmpty { Text("Todavía no hay versiones disponibles. Selecciona sesiones en Preferencias → Sync y sincroniza ambos Macs.").padding(.vertical) }
                List(sync.items) { item in
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(item.summary.title).font(.headline)
                            Text(item.summary.cwd).font(.caption).lineLimit(1)
                            HStack { Text(item.revision.deviceName); Text(item.revision.created,style:.date); Text(item.revision.created,style:.time) }.font(.caption).foregroundStyle(.secondary)
                            if item.hasConflict { Label("Hay versiones paralelas; se conservan ambas.",systemImage:"arrow.triangle.branch").font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button("Continuar aquí") { sync.resume(item) { id in opened(id); dismiss() } }.disabled(sync.busy)
                    }.padding(.vertical,5)
                }
                if sync.busy { ProgressView().controlSize(.small) }
                Text(sync.message).font(.caption).textSelection(.enabled)
                if sync.directoryRequest != nil { Button("Elegir carpeta del proyecto…") { sync.chooseDirectory { id in opened(id); dismiss() } } }
                SettingsLink { Text("Configurar sincronización en Preferencias → Sync") }
            }
        }.padding(20).frame(width:740,height:570)
            .onAppear { sync.start(); sync.refreshCatalog(); if sync.connected { sync.synchronize() } }
    }
}
