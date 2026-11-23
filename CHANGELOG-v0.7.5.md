# nia_ v0.7.5 — Terminal startup, shell environment and command navigation

## English

### Terminal dimensions at startup and session changes

Each PTY starts with a provisional 30-row × 100-column grid. Previously, the Metal view remembered only its last dimensions. When SwiftUI reused that view for another session at the same pane size, it skipped the resize notification and left the new PTY at its provisional size. Resizing the window manually changed the cached dimensions, which explains why that action repaired both width and height.

The view now synchronizes dimensions with the current session, checks the grid returned by the backend and records a size only after a successful resize. Attachment, session changes, final layout, font changes and display-scale changes all revalidate the dimensions. Unattached and zero-sized views are ignored. A coalesced main-queue callback reads the current session and bounds after the SwiftUI update, avoiding model publication during that update. The panel explicitly fills the available width and height.

### Cargo and the local shell environment

Local Zsh, Bash and Fish now start as interactive login shells. Zsh forwards the user's startup files in their normal order, follows `ZDOTDIR` changes between phases and installs nia_'s integration after the user profiles. Session history, command hooks and virtualenv restoration remain attached to the same session. Child shells receive the user's final `ZDOTDIR`, avoiding recursive loading of nia_'s generated wrappers.

The build script preserves the `cargo` selected by `PATH`. If none is found, it checks the existing `${CARGO_HOME:-$HOME/.cargo}/bin` installation before reporting a missing tool. A lookup failure no longer states that Rust must be installed without explaining the path issue. Existing shell processes keep their original environment; test the updated startup in a fresh session.

### View output

The text index now preserves normal CRLF lines, including when CR and LF arrive in separate reads. ANSI escapes and command markers between those bytes do not erase the text. Bare-CR progress updates replace the pending progress line when new text arrives.

Command navigation uses an absolute indexed line instead of an offset measured backward from the current end. A recent command, including one with no output, can remain at the top of the history view. Additional output and pane resizing keep that position. Explicit scrolling toward live output returns to the current terminal and resets its in-memory scrollback position.

Older indexes are repaired lazily, once per session and index version, from the retained raw byte log in a transaction. This rebuild changes only the derived text, anchors and counters; command IDs and raw logs remain intact. The live indexer resumes from the rebuilt partial-line state. A missing or unreadable log produces an error instead of replacing the existing index or silently returning to the live screen. A new session with no recorded history is treated as empty. The first repair runs synchronously and may take time for very large logs; subsequent operations use the repaired index without rescanning it.

The text view remains an index, not a replay of full-screen applications. The current pre-execution marker identifies the preceding indexed command line; exact first-line navigation for commands entered over multiple hard lines requires additional prompt-start markers. Commands recorded before navigation markers existed cannot gain a reliable anchor retroactively.

### Validation

Result on the completed patch: **39 Rust tests passed, 23 Swift geometry checks passed and 5 Python build-preflight tests passed**. Swift source parsing, shell syntax and `git diff --check` also passed. The Python cases stop before compilation and do not claim to build a macOS app.

Automated checks cover session-aware geometry, acknowledged and failed resize delivery, real PTY/parser dimensions, login profiles and redirected `ZDOTDIR`, session history and virtualenv restoration, Cargo lookup, streaming CRLF, legacy index recovery and command navigation.

```bash
cargo test --locked --all-targets
swiftc native/Sources/NiaTerminalGeometry.swift native/Tests/NiaTerminalGeometryTests.swift -o /tmp/nia-geometry-tests
/tmp/nia-geometry-tests
swiftc -frontend -parse native/Sources/*.swift
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p test_build_environment.py -v
bash -n scripts/build-native-macos.sh
git diff --check
```

`cargo fmt --check` was also run against this change and the original base: repository-wide formatting differences already exist in the base. New helpers/tests use rustfmt; unrelated files are not reformatted.

The automated checks were run on Linux. The complete macOS bundle build, AppKit/Metal type checking and visual verification require macOS and remain pending.

### macOS verification

1. Build this first update from iTerm or another terminal where the toolchain already works: `bash scripts/build-native-macos.sh`. Launch the rebuilt app and open a fresh session for the environment checks.
2. Start with a large window and run `stty size` before moving a window edge. Switch between two sessions at the same pane size, then restore a workspace. Each PTY should report the rows and columns available to its own panel.
3. Press Return repeatedly: the cursor should reach the last complete row. Test both split orientations, closing the split, font-size changes and moving between displays with different scales.
4. In a fresh local session, run `command -v cargo` and `cargo --version`, then run the build script. Check the expected shell history and restored virtualenv too.
5. Run a command with short output, one with no output and one with output longer than the panel. Use **View output** for each; the command line should be visible at the top. Resize while reading and let another command produce output; the history position should remain stable.
6. Open an older command with a navigation marker to exercise index repair. Scroll back toward live output and confirm the current prompt is shown. Restart with two split sessions and confirm their layout and identities persist.

## Español

### Dimensiones al abrir y cambiar de sesión

Cada PTY arranca con una rejilla provisional de 30 filas × 100 columnas. La vista Metal recordaba únicamente su última medida. Si SwiftUI reutilizaba esa vista para otra sesión con el mismo tamaño de panel, omitía la notificación y la nueva PTY conservaba el tamaño provisional. Redimensionar manualmente la ventana cambiaba la medida almacenada y por eso corregía tanto el ancho como el alto.

Ahora se sincroniza la medida con la sesión actual, se comprueba la rejilla que devuelve el motor y solo se recuerda una medida aceptada por la PTY. Se vuelve a validar al adjuntar la vista, cambiar de sesión, completar el layout, cambiar la fuente o cambiar la escala de pantalla. Se ignoran las vistas sin ventana o con tamaño cero. La notificación se agrupa en el siguiente turno de la cola principal y lee la sesión y las dimensiones vigentes, evitando publicar cambios durante la actualización de SwiftUI. El panel ocupa explícitamente todo el ancho y alto disponible.

### Cargo y entorno de la shell local

Zsh, Bash y Fish locales arrancan como shells de inicio de sesión interactivas. Zsh carga los archivos del usuario en su orden habitual, respeta los cambios de `ZDOTDIR` entre fases e instala después la integración de nia_. Se conservan el historial por sesión, los hooks de comandos y la restauración del virtualenv. Las shells hijas reciben el `ZDOTDIR` final del usuario, evitando recursiones con los archivos generados por nia_.

El script de compilación respeta el `cargo` elegido en `PATH`. Si no lo encuentra, comprueba la instalación existente en `${CARGO_HOME:-$HOME/.cargo}/bin` antes de informar del problema. El mensaje explica la búsqueda fallida y la posibilidad de que falte cargar la ruta. Las shells ya abiertas conservan su entorno anterior; comprueba el nuevo arranque en una sesión nueva.

### Ver salida

El índice de texto conserva las líneas CRLF normales aunque CR y LF lleguen en lecturas separadas. Las secuencias ANSI y marcas de comando intermedias no borran el texto. Una actualización de progreso con CR sustituye la línea pendiente cuando llega texto nuevo.

El salto utiliza una línea absoluta del índice. Los comandos recientes y los que no producen salida pueden permanecer al principio de la vista de historial. La llegada de más salida y los cambios de tamaño mantienen esa posición. Desplazarse explícitamente hacia la salida en vivo muestra la terminal actual y restablece su posición de scrollback en memoria.

Los índices antiguos se reconstruyen cuando se necesitan, una vez por sesión y versión del índice, leyendo el registro original de bytes dentro de una transacción. Solo cambian el texto derivado, sus anclajes y sus contadores; se conservan los IDs de comandos y los registros originales. El indexador activo continúa desde el estado de línea parcial reconstruido. Si falta el registro o no se puede leer, se informa del error y se conserva el índice existente. Una sesión nueva sin historial registrado se trata como vacía. La primera reparación es síncrona y puede tardar si el registro es muy grande; las siguientes consultas utilizan el índice reparado sin volver a recorrerlo.

La vista de texto sigue siendo un índice: las aplicaciones de pantalla completa no se reproducen con fidelidad visual. La marca actual, emitida antes de ejecutar, identifica la línea indexada inmediatamente anterior; localizar con precisión la primera línea de un comando introducido en varias líneas requiere marcas adicionales de comienzo de prompt. Los comandos anteriores a la incorporación de marcas de navegación no pueden obtener un anclaje fiable de forma retroactiva.

### Pruebas y comprobación en macOS

Resultado del parche completo: **39 pruebas de Rust, 23 comprobaciones de geometría Swift y 5 pruebas Python de detección de herramientas correctas**. También pasan la revisión de sintaxis Swift, la sintaxis del script y `git diff --check`. Las pruebas Python se detienen antes de compilar y no equivalen a una compilación de macOS.

Se ejecutan las órdenes de la sección **Validation** para comprobar geometría por sesión, tamaños reales de PTY, arranque de Zsh, historial, virtualenv, detección de Cargo, CRLF, reparación de índices y navegación. `cargo fmt --check` detecta diferencias de formato que ya existen en la base; se formatea el código nuevo sin reformatear archivos ajenos.

La validación automatizada se realiza en Linux. Quedan pendientes la compilación completa del bundle, la comprobación de tipos de AppKit/Metal y la prueba visual en macOS. Los seis pasos de **macOS verification** cubren ventana grande desde el arranque, pestañas sin resize, restauración, ambos splits, fuente/escala, Cargo en una sesión nueva y **Ver salida** con resultados cortos, vacíos, largos e históricos.
