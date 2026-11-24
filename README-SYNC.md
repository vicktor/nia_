# Nia Sync — beta

[English](#english)

Nia Sync comparte **versiones cifradas de sesiones** entre Macs mediante Google Drive conectado directamente o una carpeta que iCloud Drive, Drive para escritorio u otro servicio ya sincronice. Está implementado en la rama de desarrollo; requiere la nueva compilación en ambos equipos. No usa una base de datos SQLite compartida.

## Configuración

1. En el primer Mac, abre **Preferencias → Sync → Elegir carpeta compartida**. Elige iCloud Drive, Google Drive o una carpeta sincronizada. nia_ utiliza una subcarpeta `Nia Sync`.
2. Marca **Crear un espacio nuevo**, copia la clave y guárdala en tu gestor de contraseñas; pulsa **Crear y conectar**. Selecciona explícitamente las sesiones que quieres compartir y pulsa **Sincronizar ahora**.
3. Espera a que el proveedor entregue la carpeta al segundo Mac. En Google Drive, márcala como **disponible sin conexión** en ambos equipos.
4. En el segundo Mac, selecciona esa misma carpeta, **sin crear otro espacio**, pega la clave y conecta. No crees dos espacios independientes antes de que llegue `space.json`.
5. Pulsa el **botón de nube** de la barra del terminal, actualiza y elige **Continuar aquí**. Si no existe el directorio original, elige la copia local del proyecto. La sesión importada se añade a las sesiones compartidas desde ese Mac.

Con la sincronización automática activa, nia_ revisa la carpeta cada minuto mientras la app está abierta. El mensaje «Carpeta actualizada» confirma la escritura/lectura local, no que el proveedor haya entregado los archivos al otro equipo. Espera a que iCloud/Drive finalice antes de cambiar de Mac. **Sincronizar ahora** también funciona con el temporizador desactivado.

## Google Drive directo

La nueva compilación permite conectar Google **sin instalar Drive para escritorio**:

1. Abre **Preferencias → Sync → Google Drive directo → Conectar con Google**. Autoriza nia_ en el navegador y vuelve a la app.
2. En el primer Mac, marca **Crear un espacio nuevo en Google Drive**, elige el nombre, copia y guarda la clave y pulsa **Crear espacio y conectar**. La carpeta se crea en tu Drive.
3. Selecciona las sesiones y pulsa **Sincronizar ahora**. No se selecciona ninguna por defecto.
4. En el otro Mac, utiliza una compilación con el mismo cliente OAuth, conecta la misma cuenta de Google, elige ese espacio y pega la clave; no crees otro espacio. Actualiza desde el botón de nube y pulsa **Continuar aquí**.

Solo se muestran espacios creados por nia_, no todas las carpetas de tu Drive. El permiso limitado `drive.file` evita pedir acceso general al disco. OAuth utiliza el navegador del sistema, PKCE S256, estado aleatorio y una respuesta local en `127.0.0.1`. Los tokens se guardan en el Keychain de este Mac (`ThisDeviceOnly`), separados de la clave de cifrado, y se renuevan cuando es necesario. **Desconectar Google** elimina los tokens locales y desconecta Sync; no borra los archivos de Drive ni revoca por sí mismo el consentimiento en la cuenta de Google.

El archivo inicial `space.json` puede figurar en Drive como JSON o binario: nia_ acepta ambos tipos y verifica su contenido. Si v0.8.0 muestra «archivos incompatibles» justo después de conectar, actualiza a v0.8.1; no borres la carpeta ni generes otra clave.

La app descarga a un espejo local cifrado y verifica los archivos antes de utilizarlos. El mensaje «Sincronización con Google Drive completada» confirma el ciclo de API; el segundo Mac debe actualizar para recibir los cambios. Las subidas utilizan IDs persistidos antes del envío para reintentar sin duplicados tras perder una respuesta. Los bloques preceden al checkpoint. Además de los límites por versión, este transporte admite hasta 20.000 archivos y 4 GiB de datos cifrados reconocidos por espacio; no incluye limpieza automática.

### Configuración de distribución

El mantenedor registra una sola vez un cliente OAuth de tipo **aplicación de escritorio**, habilita Google Drive API y configura el consentimiento. El JSON se proporciona al compilador con `NIA_GOOGLE_OAUTH_CLIENT_FILE=/ruta/cliente.json` o se guarda localmente en `.build/google-oauth-client.json` (ignorado por Git). El empaquetador incluye únicamente la identidad del cliente en `GoogleOAuthClient.json`. **No se incluyen tokens personales ni claves de sincronización.** Los usuarios no necesitan un JSON propio. Sin esta configuración, el build mantiene la sincronización por carpeta y muestra que la conexión directa no está configurada.

El identificador y el secreto de un cliente de escritorio son información distribuible: no autentican el ejecutable. Copiarlos no da acceso a los tokens de otros usuarios. Mientras el proyecto de Google esté en **Testing**, añade las cuentas de prueba; con este permiso los refresh tokens de pruebas normalmente caducan a los siete días, por lo que habrá que reconectar. Pasar a producción y completar los requisitos de marca/verificación de Google son tareas de distribución pendientes. La implementación no certifica que Google haya aprobado la app. [OAuth para aplicaciones nativas](https://developers.google.com/identity/protocols/oauth2/native-app), [permisos de Drive](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

## Qué continúa

- Nombre, color, directorio, historial ANSI y comandos de la sesión. El directorio de inicio se adapta al usuario del Mac receptor; un venv solo se reutiliza si ya existe.
- Historial de comandos Zsh. No se ejecutan automáticamente los comandos importados ni se copian scripts de arranque.
- En SSH se conserva el host y la identidad de tmux del origen. Con la misma configuración SSH y el host disponible, se conecta a la misma sesión remota, aunque el identificador local sea nuevo.
- Cada continuación crea una sesión local separada. Repetir la misma importación devuelve esa sesión, sin duplicarla ni sobrescribirla. Las sesiones abiertas permanecen intactas.
- Si dos Macs siguen trabajando desde una versión común, se conservan ambas ramas y se indica que hay versiones paralelas. No hay fusión automática de historiales.

**No se transfieren** la memoria o los procesos locales, proyectos, instalaciones, entornos virtuales, archivos de configuración SSH, Keychain ni almacenes internos de Claude/Codex. Un ID `resume` por sí solo no transporta una conversación de un agente. Las ventanas y los splits siguen siendo locales. Para un proceso que deba seguir vivo mientras cambias de equipo, usa SSH/tmux en un host que permanezca encendido.

## Privacidad, conservación y fallos

La función está desactivada inicialmente y ninguna sesión se selecciona por defecto. El historial elegido puede contener secretos que hayan aparecido en el terminal; no hay redacción automática. El contenido, títulos, rutas y nombres de dispositivo viajan cifrados con AES-256-GCM. La clave aleatoria de 256 bits se guarda en el Keychain local con protección `ThisDeviceOnly`; se introduce explícitamente en el otro Mac. La nube ve identificadores opacos, tamaños, fechas de archivos y el identificador/formato del espacio, pero no sus textos. No pierdas la clave: nia_ no puede recuperarla del servicio cloud.

Desmarcar una sesión detiene nuevas exportaciones; **no borra las versiones compartidas**. Desconectar un Mac desactiva el enlace local y conserva las copias y la clave en el Keychain. Esta beta no tiene revocación de dispositivos, rotación de claves, retención automática ni propagación de borrados. Para retirar el acceso de quien conoce la clave, crea otro espacio con una clave nueva; eliminar archivos cloud depende también de la papelera/retención del proveedor.

Los bloques son inmutables, autenticados y deduplicados; el checkpoint se escribe al final. Una descarga incompleta o dañada no se importa. La lectura se reintenta en el siguiente ciclo o manualmente. Los errores se muestran en Sync. Las importaciones son transacciones locales; después de un cierre abrupto puede quedar un archivo huérfano privado, que se conserva y no impide reintentar. La salida aún no persistida en el momento de exportar se incluirá en una versión posterior: el log y los metadatos no son un snapshot transaccional conjunto.

Límites de esta beta por versión: 2 GiB de salida, 64 MiB de historial de shell, 16 MiB de metadatos y 100.000 comandos; hasta 10.000 archivos en el directorio de revisiones. Superar un límite produce un error; no se trunca el contenido en silencio. Los bloques de 1 MiB se reutilizan. Las sesiones cuyos archivos y metadatos no han cambiado se omiten; al cambiar un archivo se vuelve a leer para verificar sus bloques. Los almacenes grandes requieren trabajo de rendimiento y retención antes de ampliar estos límites.

## Verificación

```sh
cargo test --locked --all-targets
swiftc native/Sources/NiaSyncEngine.swift native/Tests/NiaSyncTests.swift -o /tmp/nia-sync-tests
/tmp/nia-sync-tests
swiftc native/Sources/NiaSyncEngine.swift native/Sources/NiaGoogleOAuth.swift native/Sources/NiaGoogleDrive.swift native/Tests/NiaGoogleDriveTests.swift -o /tmp/nia-google-drive-tests
/tmp/nia-google-drive-tests
./scripts/build-native-macos.sh /tmp/nia-sync-beta.app
```

Las pruebas usan carpetas temporales y datos ficticios: dos almacenes de dispositivo, cifrado, clave equivocada, incrementalidad, ramas concurrentes, reinicio antes/después de publicar, descargas parciales, alteración, symlinks, privacidad, importación idempotente, recuperación tras interrupciones, selección de directorio y conservación ANSI/SSH/timeline. Las 46 comprobaciones de Drive usan respuestas API simuladas y un callback OAuth real en localhost; cubren PKCE/estado/cancelación, renovación, límites, IDs de reintento, cifrado, ramas y corrupción. **No equivalen a autorizar una cuenta real ni a una prueba real con dos Macs.**

Prueba manual pendiente: crea dos sesiones de ejemplo en un split, sincronízalas, continúa ambas en otro Mac, escribe cambios distintos sin conexión, vuelve a conectar y comprueba las dos ramas, los colores y el historial. Reinicia las apps y verifica que repetir una importación no duplique sesiones. Los splits se eligen localmente. Comprueba también una sesión SSH con un host de prueba.

## English

**Direct Google Drive:** open **Settings → Sync → Direct Google Drive → Connect with Google**, authorize in your system browser, then create a Nia Sync space on your first Mac. Save the recovery key, select sessions and sync. On your other Mac, use a build with the same OAuth client, sign in to the same Google account, choose the existing space and paste the same key. Use **Continue here** from the cloud button. Drive for desktop is not required. Only nia_-created spaces are listed, using the limited `drive.file` scope.

OAuth uses PKCE S256, random state and a loopback callback; personal tokens stay in local Keychain (`ThisDeviceOnly`). Disconnecting Google removes local tokens and the Sync connection, retaining cloud copies; it does not revoke Google account consent. Encrypted files are authenticated before use. Persistent preallocated IDs make upload retries idempotent, and blocks upload before checkpoints. Direct sync completion confirms the API cycle; the receiving Mac still needs to refresh. The direct transport also limits each space to 20,000 files and 4 GiB of recognized encrypted data.

The initial `space.json` header may have JSON or binary MIME metadata; both are accepted and its contents are authenticated. If v0.8.0 reports incompatible files immediately after connecting, update to v0.8.1; keep the existing folder and recovery key.

**Distribution setup:** enable Drive API, register a desktop OAuth client, and build with `NIA_GOOGLE_OAUTH_CLIENT_FILE=/path/client.json` or the ignored `.build/google-oauth-client.json`. The build embeds only desktop client identity, never personal tokens or recovery keys. End users do not import JSON. Builds without this configuration retain folder sync. Desktop client identity is public and does not authenticate executable identity or disclose existing user tokens. In Google's Testing mode, allow test accounts and expect test refresh tokens to expire after seven days. Production publishing and any required Google branding/verification remain distribution tasks; live account consent and real two-Mac validation are still pending.

Nia Sync shares **encrypted session checkpoints** through direct Google Drive or a folder already synchronized by iCloud Drive, Drive for desktop or another file provider. Both Macs need this development build. Live SQLite databases are never shared.

On the first Mac, open **Settings → Sync**, choose a synced folder, create a space, save its recovery key and select the sessions to share. Sync now and wait for the provider to deliver the folder. On the other Mac, choose the same folder and paste the key without creating another space. Keep Google Drive files available offline. Use the terminal's **cloud button → Continue here** to import a version. If needed, choose the local project folder.

Automatic sync runs every minute while nia_ is open. A successful local folder update does not confirm delivery by the cloud provider. Manual sync also works when automatic sync is paused. Continuing creates a separate local session and enables sharing for it; repeated imports reuse its ID. Existing live sessions are never replaced. Concurrent branches remain visible; histories are not merged automatically.

Names, colors, cwd, ANSI transcripts and command history are included. Home paths are remapped; virtual environments must already exist. SSH sessions retain the original tmux identity and require your local SSH configuration. Imported commands and startup scripts are not executed. Local processes, project files, environments, credentials, agent conversation stores and window/split layouts are not transferred. A Claude/Codex resume ID alone cannot move its conversation to another computer.

Sharing is off initially and requires explicit session selection. Terminal history can contain private data; there is no automatic redaction. AES-256-GCM encrypts content and metadata; the 256-bit recovery key stays in local Keychain (`ThisDeviceOnly`) and is entered manually on the other Mac. File sizes, timestamps, opaque identifiers and the space format remain visible to the provider. Deselecting sessions or disconnecting does not erase existing shared copies. Device revocation, key rotation, tombstones and retention are not implemented; use a new space/key to revoke old-key access. Losing the key makes encrypted data unrecoverable.

Immutable authenticated 1 MiB blocks are deduplicated and uploaded before each checkpoint. Partial/corrupt downloads never reach the importer. Retries are automatic or manual; local imports are transactional and idempotent. A crash may leave private orphan files, which are retained without blocking retries. Export captures committed data; transcript and database metadata do not form a single atomic snapshot. Pending output appears in a later checkpoint.

Limits per version: 2 GiB transcript, 64 MiB shell history, 16 MiB metadata, 100,000 commands; up to 10,000 revision-directory entries. Limits fail explicitly instead of silently truncating. Unchanged sessions are skipped using local metadata and file stamps; changed files are reread to verify and reuse their chunks. Retention and further large-history optimization remain pending.

Automated checks use fictional data and two independent temporary device stores; they cover encryption, wrong keys, incremental chunks, parallel branches, restart before/after publication, interrupted delivery, tampering, symlinks, privacy, idempotent import, orphan recovery, missing directories, and ANSI/SSH/timeline preservation. 46 additional Drive checks use mocked API responses and a real localhost OAuth callback, testing authorization state/cancellation, retry IDs, quotas, bounds, encryption and independent device mirrors. Live Google consent and a real two-Mac iCloud/Google Drive test remain necessary; use two split test sessions, offline changes on both Macs, reconnect and restart, then verify retained versions and repeated imports. Split layout remains local.
