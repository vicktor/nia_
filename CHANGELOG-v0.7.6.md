# nia_ v0.7.6 — Responsive typing and stable cursor rendering

## English

### Causes found

Ordinary key events were written to the PTY immediately, but Swift only collected and presented the shell's echo every 120 ms. Each window owned a timer while all windows shared the same core. Every tick also queried session metadata and serialized a complete cell grid to JSON. A larger correctly sized pane increased the amount of work on the UI thread.

The Rust refresh path waited for raw-log `sync_data` before updating the VT parser, then committed the text index to SQLite. The Metal cursor renderer also moved the cursor up to two rows above the parser position when the real row was empty. These are separate scheduling, persistence and visual problems.

### Output scheduling and snapshots

- One main-run-loop timer serves the process at a target interval of 1/60 second. Core calls remain serialized on the main actor; extra windows do not multiply PTY polling.
- Session metadata, command notifications and AI/exit requests are maintained separately every 500 ms. Unchanged session lists are not republished to SwiftUI.
- Visible panes request versioned binary snapshots using their last known terminal revision. An unchanged pane returns without allocating or decoding a full grid. The legacy JSON screen ABI remains available.
- The native decoder validates lengths, dimensions, UTF-8 and flags before constructing an owned snapshot. Resize, scroll and session changes invalidate the appropriate generation.

This interval removes the intentional 120 ms batching delay. It does not establish the total key-to-pixel latency, which also includes shell processing, scheduling, snapshot work and rendering.

### Input without UI waits

Each PTY has an ordered input writer with a bounded 2 MiB queue, counting the write currently in progress. The main actor enqueues complete input events; the writer handles partial, nonblocking Unix PTY writes outside the UI thread. Readiness waits check cancellation at most 50 ms apart. A full or disconnected input queue reports a failure instead of silently accepting an event.

This also prevents a deadlock found during review: a program could fill the bounded output reader before reading a large paste, while the UI was blocked writing that paste and could no longer drain output. The regression is exercised with a real PTY that outputs and then consumes 1 MiB. Closing a terminal cancels its unsent input; it cannot run later in a different session.

### Ordered history persistence

A single background worker writes raw output and the derived text index in order, using its own SQLite connection and cached log handles. The live parser can show echoed input without waiting for durable disk sync. The 8 MiB queue reserves 1 MiB for control metadata; queue limits apply backpressure instead of dropping output. AI and exit requests are serviced independently of persistence capacity. Read/navigation barriers make pending output available before a history query or index repair; normal termination explicitly flushes accepted output.

Raw logs still precede their derived index, and SQLite durability settings remain enabled. Retry handling preserves raw byte offsets and index state so a failed write does not duplicate history. Persistence errors are surfaced by maintenance instead of silently reporting successful recording.

The live screen may now precede durable storage. A forced termination or power loss can lose output that is still queued. Normal Quit explicitly flushes accepted output; an I/O error or a five-second flush deadline records a failure instead of hanging indefinitely. The separate backup executable can only copy data already persisted by the app. Very large first-time history repairs and explicit barriers may still take time.

### Cursor and Metal

- Cursor placement uses the parser's row and column, bounded to the visible grid. Empty rows are valid positions and no longer cause a jump to earlier text.
- User input and actual cursor movement restart the blink phase. A pending timer tick cannot immediately hide a newly active cursor.
- New glyphs publish an immutable atlas texture. Previously submitted command buffers retain their own texture, avoiding CPU writes into a texture still being sampled by the GPU. Cached glyphs reuse the existing texture.
- Drawable acquisition follows CPU geometry and atlas preparation. No blocking GPU completion wait is introduced.

Apple documents that [`MTLTexture.replace`](https://developer.apple.com/documentation/metal/mtltexture/replace(region:mipmaplevel:withbytes:bytesperrow:)) does not synchronize with GPU operations; the earlier in-place atlas update therefore required a lifetime fix.

### Validation

Validated on Linux with Rust 1.100.0 and Swift 6.4.3:

- `cargo test --locked --all-targets`: 58 Rust tests passed. This includes history navigation, durable ordering/retry, queue saturation, metadata capacity, control requests and seven input-writer regressions. The real-PTY cancellation test stops the writer before terminating the still-running child.
- `python3 -m unittest discover -s tests -p 'test_*.py' -v`: 13 tests passed. Five cover build environment detection; eight compile and exercise the actual Swift refresh coordinator with 48 assertions, real Foundation timers and termination notifications.
- Standalone Swift checks passed: 23 geometry assertions, 22 cursor/blink assertions and 186 binary-decoder assertions.
- `tests/check_native_snapshot.py` passed eight real Rust-to-Swift cases against the final release library. Binary snapshots exactly match the legacy JSON for Unicode, combining/wide characters, cell attributes, cursor visibility, pending wrap, scrollback and resizing. Unchanged revisions return `NULL` with length zero.
- Release Rust library compilation, native Swift syntax parsing, bridge pointer/signature typechecking, shell syntax and `git diff --check` passed. Full AppKit/Metal SDK typechecking, GPU presentation and macOS bundle compilation remain unverified in this Linux environment.

Component timing on the same Linux machine, using actual Rust-produced ASCII screen snapshots, optimized Swift, 10 warm-up iterations and the median of 80 measured decodes:

| Rows × columns | JSON bytes | Binary bytes | Swift JSON decode | Swift binary decode |
| --- | ---: | ---: | ---: | ---: |
| 30 × 100 | 210,195 | 39,031 | 8.353 ms | 0.036 ms |
| 50 × 160 | 560,236 | 104,031 | 30.307 ms | 0.120 ms |
| 80 × 240 | 1,344,296 | 249,631 | 53.648 ms | 0.223 ms |

For the 80 × 240 screen, Rust serialization measured 3.098 ms for JSON and 0.482 ms for binary; an unchanged binary snapshot call measured 0.0018 ms. These are component measurements, not macOS frame rates or complete keyboard-to-pixel latency. Unicode correctness is covered separately from this ASCII timing fixture.

To rerun the binary bridge integration on Linux after compiling the release library:

```bash
swiftc -O native/Sources/NiaScreenDecoder.swift native/Tests/NiaScreenDecoderTests.swift -o /tmp/nia-screen-tests
python3 tests/check_native_snapshot.py --library target/release/libnia_core.so --decoder /tmp/nia-screen-tests
```

The integration harness refuses to run on macOS because its temporary data isolation uses Linux's `XDG_DATA_HOME`. The standalone Swift checks and native application verification below are the appropriate macOS paths.

### macOS verification

Follow-up validation on macOS 27.2.1 (Apple Silicon): the complete native build
passes, including SwiftUI/AppKit/Metal compilation, bundle creation, localization
validation and `codesign --verify --deep --strict`. The 58 Rust tests, 13 Python
tests and standalone Swift checks (23 geometry, 22 cursor, 186 decoder) also pass.
The interactive-history test now drains PTY output and closes its slave handle;
the old harness could hang during Zsh exit on macOS because it never read output.
Its timeout no longer enters an unbounded child wait. Repository-wide
`cargo fmt --check` still reports pre-existing formatting differences.

GPU presentation and end-to-end typing latency still require the following
interactive checks; the successful build does not measure those properties.

1. Build the updated app with `bash scripts/build-native-macos.sh`, quit the previous app normally and launch the rebuilt bundle.
2. In a large window, type quickly, hold a repeat key, edit with arrows/backspace and paste multiline text. Repeat with two split panes and several windows. Characters should follow the shell echo without 120 ms batches.
3. Run `cat`, press Return on an empty line, then type. The cursor must stay on the empty input row before the first character. Exit with Ctrl-D.
4. Test accented text, combining characters and wide glyphs with a font that supports them. Repeat after a font/scale change and watch for corruption or cursor jumps.
5. Keep output running in another session while typing in the focused pane. Confirm output order and history retention after normal Quit/relaunch.
6. Use **View output** on short, long and historical commands, including while fresh output arrives. Confirm the v0.7.5 command anchor and startup-size fixes still work.

## Español

### Causas encontradas y corrección

Las teclas normales se enviaban a la PTY de inmediato, pero el eco de la shell se recogía y mostraba cada 120 ms. Cada ventana repetía el sondeo del mismo motor; en cada ciclo también se consultaban metadatos y se convertía toda la rejilla a JSON. Además, la pantalla esperaba a sincronizar el registro en disco y el cursor se dibujaba hasta dos filas por encima de su posición real cuando la fila estaba vacía.

Ahora hay un único reloj de salida por proceso, con intervalo objetivo de 1/60 de segundo, y mantenimiento de metadatos cada 500 ms. Los paneles visibles reciben capturas binarias solo cuando cambia su revisión. Los accesos al motor siguen serializados, y las listas de sesiones sin cambios no provocan publicaciones en SwiftUI. Cada PTY tiene además una cola de entrada de 2 MiB: el hilo principal entrega los eventos completos y otro hilo los escribe en orden. Esto evita el bloqueo cruzado entre una salida llena y un pegado grande. Si la cola no puede aceptar un evento, informa del error.

La escritura y la lectura Unix usan operaciones no bloqueantes y esperas cancelables de hasta 50 ms. Cerrar una sesión cancela la entrada todavía pendiente sin esperar a que el proceso la consuma.

Un trabajador en segundo plano guarda la salida original y su índice de texto en orden, conservando la sincronización duradera del archivo y de SQLite. La cola de 8 MiB reserva 1 MiB para metadatos de control; las colas frenan la lectura si se llenan. Las solicitudes de IA y salida se atienden independientemente de la capacidad de guardado. Las consultas de historial esperan a las escrituras pendientes; el cierre normal de la aplicación vacía la cola. Los reintentos conservan los bytes ya escritos y el estado del indexador para evitar duplicados.

La pantalla puede mostrar bytes que todavía no han llegado al almacenamiento duradero. Un cierre forzado o corte de corriente puede perder ese tramo pendiente; el cierre normal intenta vaciarlo y registra un fallo si hay un error de disco o se alcanza el plazo de cinco segundos. El ejecutable de backup independiente solo puede copiar datos ya guardados. Las primeras reparaciones de historiales grandes y las esperas explícitas de guardado pueden tardar.

El cursor utiliza las coordenadas reales del parser y reinicia el parpadeo al escribir o moverse. Las letras nuevas se publican en una textura Metal inmutable, sin sobrescribir la que utiliza un frame anterior. No se añaden esperas bloqueantes de GPU.

La validación final pasa 58 tests Rust, 13 tests Python (incluidas 48 comprobaciones del coordinador Swift), 23 comprobaciones de geometría, 22 de cursor y 186 del decodificador. También pasan ocho casos reales Rust→Swift contra la biblioteca release final, con equivalencia exacta respecto al JSON anterior. La sección **Validation** detalla la cobertura y los comandos.

En la prueba de decodificación de una pantalla de 50 filas × 160 columnas, la mediana pasa de 30,307 ms con JSON a 0,120 ms con la captura binaria. Es una medición de ese componente en Linux, no de la latencia total de escritura ni de los FPS en tu Mac.

La validación posterior en macOS 27.2.1 (Apple Silicon) completa la compilación de SwiftUI/AppKit/Metal, la creación del bundle y la verificación de firma. También pasan las 58 pruebas Rust, las 13 Python y las comprobaciones Swift (23 de geometría, 22 de cursor y 186 del decodificador). Se corrige el arnés de historial interactivo para consumir la salida de la PTY y cerrar su descriptor esclavo: antes podía quedarse bloqueado al terminar Zsh en macOS. El timeout ya no espera indefinidamente al proceso. `cargo fmt --check` sigue señalando diferencias de formato preexistentes.

El objetivo de 1/60 de segundo elimina la espera deliberada de 120 ms, pero no equivale a medir la latencia total de teclado a pantalla. Quedan pendientes las comprobaciones visuales de **macOS verification**: escritura rápida, splits, varias ventanas, filas vacías, Unicode, salida simultánea, persistencia y «Ver salida».
