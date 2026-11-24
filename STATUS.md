# nia_ — Estado de la beta / Beta status

Revisión: **24 de noviembre de 2026**, nia_ **v0.8.0 beta**. Este inventario describe el código incluido en `main`, su validación y las funciones pendientes. La aplicación se compila y ejecuta en macOS; no todas las funciones tienen validación física entre dos ordenadores.

## Español

### Inventario contrastado

| Área | Estado y evidencia | Lo que falta o limita su alcance |
| --- | --- | --- |
| Terminal nativo | Implementado: SwiftUI/AppKit, Metal, PTY Rust, ANSI/Unicode. `native/Sources/NiaTerminalView.swift`, `src/terminal.rs`. | Validación más amplia de TUIs, IME/accesibilidad, emoji y reflow. No se han certificado garantías de latencia o consumo de recursos. |
| Sesiones y organización | Implementado: nombres separados del ID, colores, búsqueda, arrastre, archivado/reapertura, historial independiente. `NiaApp.swift`, `src/storage.rs`. | UX y migraciones siguen en beta. |
| Split y ventanas | Implementado: dos paneles, orientación, tamaños propios, varias ventanas y layouts SQLite. `NiaApp.swift`, `src/lib.rs`. | La asignación de sesiones es por proceso. Falta coordinación entre procesos independientes y recuperación completa de escenas macOS. |
| Restauración local | Parcial: metadatos, salida, shell, cwd y venv existente. `Terminal::spawn`, `snapshot_state`, hooks Zsh. | No restaura RAM ni procesos locales terminados. La detección de cwd/venv depende de Zsh; no migra proyectos ni instala entornos. |
| Scroll e historial | Implementado con límites: ANSI en disco, índice SQLite y scrollback de 1.000–100.000 filas. `src/history.rs`, `src/persistence.rs`, `src/lib.rs`. | Replay inicial de logs grandes; wrapping histórico sin tamaños originales; el índice de texto no reproduce una TUI. Un cierre forzado puede perder salida aún en cola. |
| Historial de comandos | Implementado para Zsh local: duración, resultado, directorio, repeticiones y anclas OSC 133. | Vista limitada a 200 comandos recientes, sin paginación completa de esa lista. Comandos antiguos sin ancla; líneas de edición complejas pueden no reconstruirse en el índice. |
| Entrada, enlaces y utilidades | Implementado: selección/copia, pegado, drop Finder, enlaces, UUID/contraseña, doble Escape. Toast de copia validado. | Enlaces partidos; doble Escape depende de bindings. Las primitivas MD5/SHA-1 son identificadores heredados, no funciones de seguridad. |
| Confirmación de salida | Implementado antes de `exit`/`logout` exactos en Zsh local. | No cubre Bash, Fish, shells SSH ni salidas internas de programas. |
| Apariencia e idiomas | Implementado: claro/oscuro/sistema, fuente/tamaño/cursor, español/inglés. | Transparencia experimental; ligaduras entre celdas no implementadas. |
| IA integrada | Implementado: `?`, propuestas editables, proveedores externos/locales, GGUF interno opcional, claves en Keychain. `NiaAI.swift`, `NiaInternalAI.swift`, `NiaAIExecutionPolicy.swift`. | Hook solo Zsh local. La ejecución automática limitada por patrones es opcional y no es un sandbox. |
| Resume de agentes | Parcial: se recuerdan comandos exactos `claude --resume ID`, `codex resume ID`, `gemini --resume ID`. `validated_agent_resume` en `src/terminal.rs`. | **Pendiente descubrir automáticamente el ID** cuando se inicia sin resume, con opciones adicionales o desde otro lanzador. Necesita la CLI y sus datos originales. |
| Nia Remote | Experimental: SSH con verificación de host y tmux identificado por sesión; reconexión manual. `README-REMOTE.md`, `Terminal::spawn`. | Sin emparejamiento, descubrimiento/estado remoto completo ni descubrimiento directo del host. Nia Sync conserva ahora la identidad tmux al importar. El host debe seguir vivo; tmux no sobrevive a su reinicio como proceso en ejecución. |
| Backup cifrado | CLI implementada con restic: init, backup, snapshots, check y restore a destino nuevo. `src/bin/nia-backup.rs`, `RECOVERY.md`. | **La pestaña Backup nativa solo informa**; no configura ni ejecuta. Sin programación, UI guiada de recuperación ni prueba reciente documentada de desastre entre dos Macs. SQLite se captura consistentemente, pero logs y DB no forman un punto atómico común. Hay un ZIP temporal local en claro antes del cifrado. |
| Handoff entre Macs | Manual/experimental: `scripts/nia-handoff.sh` y `README-HANDOFF.md`. | Exporta/restaura snapshots; no reconcilia cambios concurrentes, no mueve procesos ni instala rutas, proyectos, venvs o credenciales. |
| Nia Sync | **Beta implementada:** Google Drive directo o carpeta iCloud/Drive, OAuth PKCE, cifrado, clave en Keychain, selección, checkpoints incrementales, continuidad explícita y versiones concurrentes. `NiaSync*.swift`, `src/sync_store.rs`, [guía](README-SYNC.md). | Pendiente prueba real en dos Macs, conversaciones internas de agentes, layouts compartidos, retención/borrados, revocación de claves y optimización de historiales grandes. No mueve procesos ni proyectos. |
| Servicio persistente de sesiones | **No implementado.** Las PTY locales pertenecen al proceso de la app. | Servicio residente, autorización de clientes, reconexión, propiedad y resize. No debe prometer migrar memoria de procesos entre hosts. |
| Acciones configurables | Cargador TOML y prototipo histórico en `src/actions.rs`, `src/main.rs`, `examples/actions.toml`. | **No conectado a la UI nativa actual ni a su FFI.** No confundirlo con Quick Insert ni con el validador de comandos IA. |
| Fuentes descargables | Implementado y validado: cinco familias, integridad/licencias y registro por proceso. `NiaFonts.swift`, `FontCatalog.json`. | Registro por proceso; no instala las fuentes globalmente. |
| Consumo Claude/Codex | Implementado: consulta Codex real y adaptador Claude probado con datos controlados. `NiaUsage*`, `NiaCodexUsage.swift`, `nia-usage-bridge.rs`. | Claude requiere conexión explícita/reinicio de sesiones y emitir datos; no se validó una lectura real de cuota Claude en esta sesión. Los planes pueden omitir límites. Tokens de cuenta/sesión no equivalen a cuota semanal. |
| Actualizaciones | Implementado: releases, canales, fallback `gh`, hashes, extracción validada e instalador con intercambio atómico. `NiaUpdate*`, `src/update_archive.rs`. | Descarga privada real y recuperación del instalador en pruebas controladas; falta validar el ciclo completo con una futura release más nueva. Sin notarización Apple. |
| Registro, privacidad y distribución | Datos locales y backups cifrados con restic; la app mantiene rutas/ID históricos. | Falta política completa de captura, exclusión, retención y redacción; distribución notarizada y más verificación de accesibilidad/rendimiento. |

### Qué significa continuar en otro ordenador

1. **Mismo proceso remoto, hoy:** ambos Macs acceden al mismo host y sesión tmux. El trabajo y los archivos siguen en ese host. Requiere la misma identidad de sesión y configuración SSH; no hay descubrimiento automático entre Macs.
2. **Estado guardado, hoy de forma manual:** backup y handoff recuperan metadatos e historial en un destino limpio. Deben existir allí las rutas y herramientas. La experiencia no equivale a reanudar un proceso vivo.
3. **Versiones sincronizadas, beta de desarrollo:** Nia Sync comparte sesiones e historial cifrados mediante Google Drive directo o una carpeta iCloud/Drive y permite continuarlos explícitamente. Conserva ramas concurrentes sin sobrescribir sesiones abiertas. Layouts, procesos, proyectos y conversaciones internas de agentes quedan fuera; [contrato y configuración](README-SYNC.md).

### Prioridades propuestas para completar la visión

| Prioridad | Entregable | Criterio de aceptación |
| --- | --- | --- |
| P0 | Consolidar restauración, scroll y foco. | Dos ventanas con dos paneles; cambiar físicamente desde otra app, escribir, desplazarse, redimensionar y reiniciar sin cruzar entradas ni perder la salida persistida. |
| P1 | Backup/restauración nativos, programados y observables. | Crear y verificar una copia desde preferencias; restaurar en una carpeta nueva de otro Mac; comprobar historiales, layouts, cwd y avisos sobre rutas ausentes. |
| Hecho (beta) | Contrato de continuidad: [README-SYNC.md](README-SYNC.md). | Distinguir sesión remota persistente, recuperación de estado y sync; documentar qué ocurre con proyectos, venv, credenciales y procesos. |
| Beta; falta prueba física | Primer sync de metadatos entre dos Macs emparejados. | IDs permanentes de dispositivo/sesión, claves recuperables, journal y transporte cifrado; cambios offline, duplicados, reintentos y conflicto concurrente sin pérdida silenciosa. |
| Incremental listo; borrados pendientes | Historial incremental y borrados. | Bloques inmutables verificados, retención, tombstones y restauración histórica; un borrado o conflicto no destruye la copia recuperable. No copiar SQLite viva. |
| Hecho (beta) | UI de continuidad. | Ver dispositivos, estado y errores; elegir abrir localmente o reconectar al host; informar si un proyecto/host no está disponible. |
| P3 | Servicio local de PTY persistentes. | Cerrar/reabrir la UI conserva una PTY viva con reconexión autorizada, ownership y resize claros; un reinicio del host tiene un comportamiento definido. |
| P3 | Agentes, shells y acciones. | Detectar IDs de agentes sin ambigüedad ni replay arbitrario; ampliar hooks a Bash/Fish donde proceda; portar acciones TOML si siguen formando parte del producto. |

Este orden es una propuesta, no un compromiso de fechas. La beta de Sync se ha implementado después de la web: cubre claves, identidad, checkpoints incrementales y UI de continuidad. El daemon, retención/borrados y el resto de pendientes siguen abiertos.

### Verificación disponible

La validación automatizada cubre el núcleo Rust, geometría/renderizado, teclado, actualización e instalación, fuentes, indicadores de consumo y sincronización cifrada. La compilación nativa y su firma se verifican en macOS. Las comprobaciones físicas de foco y scroll con varias ventanas, la cuota real de Claude y el intercambio entre dos Macs siguen pendientes. Las pruebas controladas no certifican esas situaciones reales.

Fuentes: las guías `README*.md`, `RECOVERY.md` y el código indicado arriba. `NATIVE-MIGRATION.md` es una nota histórica, no el estado vigente.

## English

This inventory describes nia_ **v0.8.0 beta**, the source included in `main`, available validation and remaining work. The app builds and runs on macOS; real two-Mac validation is still pending.

### Built, partial and missing

- **Built in beta:** native SwiftUI/AppKit/Metal terminal and Rust PTY core; named, colored, searchable and reorderable sessions; split panes; persistent history; Zsh command timeline and output anchors; selection/copy, file drops, links, Quick Insert; English/Spanish UI and appearance; optional local/hosted AI and an internal model. Exact local Zsh `exit`/`logout` can request confirmation.
- **Partial/experimental:** multi-window restoration and ownership (coordinated within one process); cwd/venv recovery (Zsh and existing environments); TUI compatibility, reflow and transparency; explicit-ID agent resume; SSH/tmux reconnection; CLI encrypted backups and manual handoff. Local process memory is not restored.
- **Included in this beta:** five downloadable font families, optional Claude/Codex quota indicators, GitHub update checks and installation, native copy feedback and recent scrolling fixes. Codex and private release downloads were checked live; Claude's adapter was tested with controlled fixtures and still needs an actual connected-session quota check. The updater still needs a complete end-to-end run with a newer published release.
- **New development beta:** Nia Sync shares encrypted incremental checkpoints through direct Google Drive or an iCloud/Drive folder, with explicit selection, recoverable keys, device identities, a continuation UI and retained concurrent branches. See [the setup and limits](README-SYNC.md#english).
- **Missing:** a real two-Mac sync validation; agent conversation transfer, shared layouts, sync retention/deletions, key rotation/revocation; a resident local PTY service; automatic agent conversation-ID discovery; backup configuration/execution/scheduling and guided restore in SwiftUI; complete history retention/redaction; broader shell integration; independent-process coordination; Apple notarization and broader accessibility/performance validation.
- **Legacy-only:** configurable TOML actions have a parser and historical UI, but no current native UI/FFI integration. This is distinct from Quick Insert and AI command validation.

### Cross-Mac continuity

**Remote reconnection exists:** both Macs can attach to the same SSH/tmux host/session; processes and files stay on that host, which must remain running. **Manual handoff exists:** encrypted snapshots can restore saved metadata and history on a clean destination, with required projects, tools and paths already installed. **Encrypted session sync is now a development beta:** direct Google Drive or a provider-managed folder transports immutable checkpoints and deduplicated blocks. Continuation imports a separate local session; parallel branches are preserved. Shared layouts, project files and internal agent conversations remain outside its scope. No live SQLite file is copied.

### Proposed sequence and acceptance

1. Stabilize physical focus, scrolling and restoration with two windows/two panes, including input after switching from another app and restarting.
2. Add in-app backup/restore and scheduling; verify recovery on a second Mac into a new directory, with clear missing-path warnings.
3. Specify continuity semantics, including projects, environments, credentials and live processes.
4. Implement paired-device metadata sync: stable IDs, recoverable keys, a journal, encrypted transport, offline/retry/idempotency and visible conflict handling.
5. Add immutable history chunks, tombstones, retention and recoverable versions; never silently discard concurrent work.
6. Add device/status UI and explicit choices between opening locally and reconnecting remotely.
7. Consider a resident authorized PTY service and automatic agent-ID discovery, then broader shell hooks and native configurable actions.

These are proposed priorities, not delivery dates. Sync was implemented after the website task; the resident PTY daemon is still pending. Automated tests and a signed native build does not certify cross-Mac synchronization, every terminal feature or the earlier physical-activation incident. See the Spanish evidence table above and the linked repository documents for source locations and precise limits.

### Validación de Nia Sync / Nia Sync validation

La beta incorpora pruebas con datos ficticios y almacenes separados para cifrado, conflicto, incremento, idempotencia, interrupción y restauración ANSI/SSH/timeline. La compilación nativa se verifica; no se ha certificado la entrega mediante clientes cloud en dos Macs físicos. Automated isolated-store tests do not certify end-to-end cloud delivery on two physical Macs.

### Google Drive directo / Direct Google Drive

Implementado: cliente de escritorio incorporado al compilar, navegador + PKCE S256/estado/loopback, tokens renovables en Keychain, espacios de nia_ con `drive.file`, espejo cifrado y API paginada, subidas reintentables con ID preasignado, selector de proveedor y mensajes EN/ES. 46 comprobaciones Swift nuevas con API simulada y callback local; no se ha autorizado una cuenta ni subido sesiones reales. Pendientes consentimiento real, distribución/producción de OAuth en Google y prueba de dos Macs físicos.

Implemented: bundled desktop client, browser + PKCE/state/loopback, refreshable Keychain tokens, nia_ spaces with `drive.file`, encrypted mirror and paginated API, uploads with persistent retry IDs, provider picker and EN/ES messages. 46 new Swift fixture checks; live account consent, Google OAuth production distribution and physical two-Mac validation remain pending.
