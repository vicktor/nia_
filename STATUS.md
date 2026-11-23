# nia_ — Estado de la beta / Beta status

Revisión: **23 de noviembre de 2026**. Alcance: documentación conservada desde el primer commit (`98444ad`), notas de versiones, código nativo actual y peticiones de esta sesión. No se conserva aquí una especificación original independiente que permita certificar requisitos adicionales que nunca se documentaron.

La aplicación **ya se compila y se ejecuta en macOS**. Este documento sustituye el estado antiguo de «primer borrador sin compilar». El estado refleja la línea de desarrollo local v0.7.6; no implica que todas las funciones estén integradas en `main` o publicadas como release. En esta revisión, la release publicada era v0.6.4 y la rama de trabajo de la aplicación seguía siendo `fix/responsive-terminal-v0.7.6`.

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
| Entrada, enlaces y utilidades | Implementado: selección/copia, pegado, drop Finder, enlaces, UUID/contraseña, doble Escape. Nuevo toast de copia validado en desarrollo. | Enlaces partidos; doble Escape depende de bindings. Las primitivas MD5/SHA-1 son identificadores heredados, no funciones de seguridad. |
| Confirmación de salida | Implementado antes de `exit`/`logout` exactos en Zsh local. | No cubre Bash, Fish, shells SSH ni salidas internas de programas. |
| Apariencia e idiomas | Implementado: claro/oscuro/sistema, fuente/tamaño/cursor, español/inglés. | Transparencia experimental; ligaduras entre celdas no implementadas. |
| IA integrada | Implementado: `?`, propuestas editables, proveedores externos/locales, GGUF interno opcional, claves en Keychain. `NiaAI.swift`, `NiaInternalAI.swift`, `NiaAIExecutionPolicy.swift`. | Hook solo Zsh local. La ejecución automática limitada por patrones es opcional y no es un sandbox. |
| Resume de agentes | Parcial: se recuerdan comandos exactos `claude --resume ID`, `codex resume ID`, `gemini --resume ID`. `validated_agent_resume` en `src/terminal.rs`. | **Pendiente descubrir automáticamente el ID** cuando se inicia sin resume, con opciones adicionales o desde otro lanzador. Necesita la CLI y sus datos originales. |
| Nia Remote | Experimental: SSH con verificación de host y tmux identificado por sesión; reconexión manual. `README-REMOTE.md`, `Terminal::spawn`. | Sin emparejamiento, descubrimiento/estado remoto completo ni sincronización de metadatos. El host debe seguir vivo; tmux no sobrevive a su reinicio como proceso en ejecución. |
| Backup cifrado | CLI implementada con restic: init, backup, snapshots, check y restore a destino nuevo. `src/bin/nia-backup.rs`, `RECOVERY.md`. | **La pestaña Backup nativa solo informa**; no configura ni ejecuta. Sin programación, UI guiada de recuperación ni prueba reciente documentada de desastre entre dos Macs. SQLite se captura consistentemente, pero logs y DB no forman un punto atómico común. Hay un ZIP temporal local en claro antes del cifrado. |
| Handoff entre Macs | Manual/experimental: `scripts/nia-handoff.sh` y `README-HANDOFF.md`. | Exporta/restaura snapshots; no reconcilia cambios concurrentes, no mueve procesos ni instala rutas, proyectos, venvs o credenciales. |
| Nia Sync | **No implementado.** Las notas de handoff ya lo enumeraban como pendiente. | Identidad de dispositivos, pairing, claves, journal, protocolo de transferencia, conflictos, borrados, UX y validación de fallos. |
| Servicio persistente de sesiones | **No implementado.** Las PTY locales pertenecen al proceso de la app. | Servicio residente, autorización de clientes, reconexión, propiedad y resize. No debe prometer migrar memoria de procesos entre hosts. |
| Acciones configurables | Cargador TOML y prototipo histórico en `src/actions.rs`, `src/main.rs`, `examples/actions.toml`. | **No conectado a la UI nativa actual ni a su FFI.** No confundirlo con Quick Insert ni con el validador de comandos IA. |
| Fuentes descargables | Implementado y validado en desarrollo: cinco familias, integridad/licencias y registro por proceso. `NiaFonts.swift`, `FontCatalog.json`. | Pendiente publicar una release que las incluya. |
| Consumo Claude/Codex | Implementado en desarrollo: consulta Codex real y adaptador Claude probado con datos controlados. `NiaUsage*`, `NiaCodexUsage.swift`, `nia-usage-bridge.rs`. | Claude requiere conexión explícita/reinicio de sesiones y emitir datos; no se validó una lectura real de cuota Claude en esta sesión. Los planes pueden omitir límites. Tokens de cuenta/sesión no equivalen a cuota semanal. |
| Actualizaciones | Implementado en desarrollo: releases, canales, fallback `gh`, hashes, extracción validada e instalador con intercambio atómico. `NiaUpdate*`, `src/update_archive.rs`. | Descarga privada real y recuperación del instalador en pruebas controladas; falta validar el ciclo completo con una futura release más nueva. Sin notarización Apple. |
| Registro, privacidad y distribución | Datos locales y backups cifrados con restic; la app mantiene rutas/ID históricos. | Falta política completa de captura, exclusión, retención y redacción; distribución notarizada y más verificación de accesibilidad/rendimiento. |

### Qué significa continuar en otro ordenador

1. **Mismo proceso remoto, hoy:** ambos Macs acceden al mismo host y sesión tmux. El trabajo y los archivos siguen en ese host. Requiere la misma identidad de sesión y configuración SSH; no hay descubrimiento automático entre Macs.
2. **Estado guardado, hoy de forma manual:** backup y handoff recuperan metadatos e historial en un destino limpio. Deben existir allí las rutas y herramientas. La experiencia no equivale a reanudar un proceso vivo.
3. **Workspace sincronizado, pendiente:** los Macs comparten cambios de sesiones/layouts/historial mediante un protocolo propio. Se debe especificar si los archivos de proyecto quedan a cargo de Git/otra herramienta o se sincronizan también; actualmente no se sincronizan.

### Prioridades propuestas para completar la visión

| Prioridad | Entregable | Criterio de aceptación |
| --- | --- | --- |
| P0 | Consolidar restauración, scroll y foco. | Dos ventanas con dos paneles; cambiar físicamente desde otra app, escribir, desplazarse, redimensionar y reiniciar sin cruzar entradas ni perder la salida persistida. |
| P1 | Backup/restauración nativos, programados y observables. | Crear y verificar una copia desde preferencias; restaurar en una carpeta nueva de otro Mac; comprobar historiales, layouts, cwd y avisos sobre rutas ausentes. |
| P1 | Definir el contrato de continuidad. | Distinguir sesión remota persistente, recuperación de estado y sync; documentar qué ocurre con proyectos, venv, credenciales y procesos. |
| P2 | Primer sync de metadatos entre dos Macs emparejados. | IDs permanentes de dispositivo/sesión, claves recuperables, journal y transporte cifrado; cambios offline, duplicados, reintentos y conflicto concurrente sin pérdida silenciosa. |
| P2 | Historial incremental y borrados. | Bloques inmutables verificados, retención, tombstones y restauración histórica; un borrado o conflicto no destruye la copia recuperable. No copiar SQLite viva. |
| P2 | UI de continuidad. | Ver dispositivos, estado y errores; elegir abrir localmente o reconectar al host; informar si un proyecto/host no está disponible. |
| P3 | Servicio local de PTY persistentes. | Cerrar/reabrir la UI conserva una PTY viva con reconexión autorizada, ownership y resize claros; un reinicio del host tiene un comportamiento definido. |
| P3 | Agentes, shells y acciones. | Detectar IDs de agentes sin ambigüedad ni replay arbitrario; ampliar hooks a Bash/Fish donde proceda; portar acciones TOML si siguen formando parte del producto. |

Este orden es una propuesta de implementación, no un compromiso de fechas. No se han empezado a implementar Nia Sync ni el daemon como parte de la web.

### Verificación disponible

La compilación de desarrollo instalada pasó 72 pruebas Rust, 13 Python y 56 comprobaciones Swift de las nuevas funciones; la firma y la compilación nativas se verificaron. Las pruebas interactivas verificaron fuentes, búsqueda de releases privada y lectura real de Codex. Son evidencias de esa compilación, **no** una certificación de todas las capacidades de la beta ni de continuidad entre dos ordenadores. Las limitaciones del incidente de activación y las comprobaciones físicas pendientes están documentadas en `CHANGELOG-v0.7.6.md` de la rama de desarrollo.

Fuentes: `README.md`, `README.es.md`, `README-HANDOFF.md`, `README-REMOTE.md`, `RECOVERY.md`, `README-QUICK-INSERT.md`, `README-NIA-AI.md`, `README-INTERNAL-AI.md`, changelogs y código indicado arriba. `NATIVE-MIGRATION.md`, los primeros changelogs y la antigua versión de este archivo son notas históricas, no el estado vigente.

## English

The app is now built and running on macOS. This review replaces the obsolete uncompiled-draft status. It covers the documented requirements retained since commit `98444ad`, current native source and requests in this session; no separate complete original specification was available. The inventory describes local v0.7.6 development, which is ahead of the published v0.6.4 release at the review date.

### Built, partial and missing

- **Built in beta:** native SwiftUI/AppKit/Metal terminal and Rust PTY core; named, colored, searchable and reorderable sessions; split panes; persistent history; Zsh command timeline and output anchors; selection/copy, file drops, links, Quick Insert; English/Spanish UI and appearance; optional local/hosted AI and an internal model. Exact local Zsh `exit`/`logout` can request confirmation.
- **Partial/experimental:** multi-window restoration and ownership (coordinated within one process); cwd/venv recovery (Zsh and existing environments); TUI compatibility, reflow and transparency; explicit-ID agent resume; SSH/tmux reconnection; CLI encrypted backups and manual handoff. Local process memory is not restored.
- **Implemented in the local development build, not yet in a published release:** five downloadable font families, optional Claude/Codex quota indicators, GitHub update checks and installation, native copy feedback and recent scrolling fixes. Codex and private release downloads were checked live; Claude's adapter was tested with controlled fixtures and still needs an actual connected-session quota check. The updater still needs a complete end-to-end run with a newer published release.
- **Missing:** automatic bidirectional Nia Sync; device pairing and identity; encrypted incremental change transfer and conflict/deletion policy; a resident local PTY service; automatic agent conversation-ID discovery; backup configuration/execution/scheduling and guided restore in SwiftUI; complete history retention/redaction; broader shell integration; independent-process coordination; Apple notarization and broader accessibility/performance validation.
- **Legacy-only:** configurable TOML actions have a parser and historical UI, but no current native UI/FFI integration. This is distinct from Quick Insert and AI command validation.

### Cross-Mac continuity

**Remote reconnection exists:** both Macs can attach to the same SSH/tmux host/session; processes and files stay on that host, which must remain running. **Manual handoff exists:** encrypted snapshots can restore saved metadata and history on a clean destination, with required projects, tools and paths already installed. **Automatic workspace sync does not exist:** copying live SQLite databases is not a synchronization protocol and does not safely reconcile concurrent edits. Project-file synchronization also remains undefined and unimplemented.

### Proposed sequence and acceptance

1. Stabilize physical focus, scrolling and restoration with two windows/two panes, including input after switching from another app and restarting.
2. Add in-app backup/restore and scheduling; verify recovery on a second Mac into a new directory, with clear missing-path warnings.
3. Specify continuity semantics, including projects, environments, credentials and live processes.
4. Implement paired-device metadata sync: stable IDs, recoverable keys, a journal, encrypted transport, offline/retry/idempotency and visible conflict handling.
5. Add immutable history chunks, tombstones, retention and recoverable versions; never silently discard concurrent work.
6. Add device/status UI and explicit choices between opening locally and reconnecting remotely.
7. Consider a resident authorized PTY service and automatic agent-ID discovery, then broader shell hooks and native configurable actions.

These are proposed priorities, not delivery dates. No synchronization engine or daemon was implemented as part of the website task. Development validation (72 Rust tests, 13 Python tests, 56 Swift feature checks and a signed native build) does not certify cross-Mac synchronization, every terminal feature or the earlier physical-activation incident. See the Spanish evidence table above and the linked repository documents for source locations and precise limits.
