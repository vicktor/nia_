<p align="center">
  <img src="assets/nia-icon.png" alt="nia_ icon" width="144" />
</p>

# nia_

**Tu terminal. Tu memoria. En todas partes.**

[English](README.md) · [Código / GitHub](https://github.com/vicktor/nia_) · [Licencia (MPL-2.0)](LICENSE) · [Cómo contribuir](CONTRIBUTING.md)

nia_ es un **terminal experimental nativo para macOS** que combina una interfaz SwiftUI/AppKit, renderizado Metal y un núcleo Rust para PTY, sesiones e historial. Está pensado para desarrolladores que buscan sesiones persistentes con nombre, una interfaz ligera y asistencia de IA opcional.

> **Versión de desarrollo, no completamente estabilizada.** Remote, el reflow ANSI y la recuperación de historiales siguen sujetos a pruebas. Haz backup antes de actualizar. No se afirma que la seguridad esté auditada ni se prometen consumos de memoria verificados.

## Idiomas y confirmación de salida (v0.7.1)

- nia_ está localizada en **inglés y español**, incluidos menús, Preferencias, IA, estados del modelo, errores y acciones contextuales.
- Entra en **Preferencias → General → Idioma** para elegir **Automático (macOS)**, **English** o **Español**. La elección queda guardada sin cambiar identificadores ni historiales.
- **Preguntar antes de cerrar una sesión con exit** está activado por defecto. Si escribes exactamente `exit` o `logout` en una shell Zsh local e interactiva, nia_ pide permiso **antes de ejecutar el comando**.
- Cancelar conserva la shell. Confirmar permite el exit y retira la pestaña cuando la PTY ha terminado y su salida se ha guardado; el historial permanece disponible para abrirla de nuevo.
- Si un programa termina por sí solo, nia_ no puede impedir su finalización, pero retira la pestaña local una vez guardada la salida.
- La confirmación previa de `exit` se aplica por ahora solo a **Zsh local**, no a Bash, Fish, SSH remoto ni comandos de salida internos de otras aplicaciones.

## Espacios de trabajo multiventana (experimental)

- **⌘N** (Archivo → Nueva ventana) abre otra ventana nativa de nia_.
- Cada ventana tiene pestañas ordenadas, split, foco y distribución independientes.
- Todas comparten un único motor Rust/PTy; cerrar una pestaña no elimina su historial.
- Usa el botón de carpeta con «+» para recuperar sesiones guardadas.
- Una sesión solo se puede editar en una ventana a la vez para evitar conflictos de tamaño PTY.
- Las distribuciones se guardan en SQLite y se incluyen en los backups cifrados.
- La distribución anterior se migra una sola vez y las nuevas ventanas empiezan vacías.
- La restauración de todas las ventanas tras cerrar nia_ todavía depende del sistema de escenas de macOS.

## Características

| Área | Funcionalidades actuales | Limitaciones |
| --- | --- | --- |
| Interfaz nativa | Barra lateral SwiftUI, preferencias, menú y apariencia claro/oscuro | macOS 14 o superior |
| Terminal | PTY Rust, interpretación VT, Metal, colores, Unicode, fuente monoespaciada, cursor y opacidad configurables | Reflow y ciertas TUI todavía experimentales |
| Sesiones | Identificadores propios, pestañas ordenables, colores, historial independiente y restauración | Un reinicio de Mac no recupera la RAM de procesos terminados |
| Split | Dos terminales lado a lado o apilados, entrada y PTY independientes, layout recordado | Conviene comprobar restauración tras actualizar |
| Historial | Registro ANSI en disco, índice SQLite, scrollback y paginación | El índice textual no reproduce exactamente pantallas TUI antiguas |
| Entrada | Selección/copia, `⌘C`/`⌘V`, palabra/línea/rectángulo, arrastrar archivos desde Finder, doble Escape | Doble Escape depende de atajos habituales Emacs de la shell |
| IA | Consultas `?` en Zsh local, modelos internos/locales/APIs, propuestas editables y autoejecución restringida | Los modelos pueden equivocarse; la política no es un sandbox |
| Remote | Reconexión SSH + tmux a procesos de otro Mac | No sincroniza automáticamente los workspaces |
| Backup | Snapshots cifrados con restic y restauración por CLI | Hay que configurar y probar la recuperación |

## Requisitos

- macOS 14 o posterior, preferentemente Apple Silicon con Metal.
- Xcode Command Line Tools (`swiftc`, `clang`, `sips` e `iconutil`).
- [Rust](https://rustup.rs/) y Cargo.
- Git y CMake (`brew install cmake`) para compilar el motor opcional `llama-server`. Actualmente el empaquetador nativo lo compila incluso si no utilizas IA Interna.
- Conexión a Internet para dependencias del proyecto y, si lo deseas, para descargar modelos GGUF.
- Opcionales: `restic` para copias de seguridad y `tmux` en el equipo remoto.

## Compilar e instalar

En la raíz del repositorio:

```bash
./scripts/build-native-macos.sh
open dist/nia_.app
```

Se genera **`dist/nia_.app`**. El script compila Rust, SwiftUI y el motor local de inferencia; solo publica el bundle cuando terminan la compilación y las comprobaciones. La firma es local de desarrollo, sin notarización pública.

El ejecutable interno se llama `nia`: `nia_.app/Contents/MacOS/nia`. Si deseas un acceso por línea de comandos a la aplicación gráfica:

```bash
mkdir -p "$HOME/.local/bin"
ln -sf "$(pwd)/dist/nia_.app/Contents/MacOS/nia" "$HOME/.local/bin/nia"
```

Asegúrate de que `$HOME/.local/bin` está en tu `PATH`. Este ejecutable abre la app gráfica; no es una CLI específica de gestión de sesiones.

### Backup cifrado y restauración

```bash
brew install restic
export RESTIC_REPOSITORY="$HOME/nia-test-repo"  # solo para probar
# Configura RESTIC_PASSWORD_FILE o RESTIC_PASSWORD_COMMAND de forma segura.
cargo run --release --bin nia-backup -- init
cargo run --release --bin nia-backup -- backup
cargo run --release --bin nia-backup -- snapshots
cargo run --release --bin nia-backup -- check
```

Para sobrevivir a la pérdida de un Mac, utiliza almacenamiento externo SFTP/S3, conserva la contraseña de recuperación fuera de ambos Macs y prueba una restauración real. Consulta [RECOVERY.md](RECOVERY.md).

## Primeros pasos

1. Abre `nia_.app` y crea una sesión con nombre en la barra lateral.
2. Usa `⌘1` a `⌘9` para cambiar de sesión, arrastra para reordenar y `⌘B` para ocultar/mostrar la barra lateral.
3. En el selector de split elige una segunda sesión y orientación lado a lado o apilada. Haz clic en el panel para dirigir allí el teclado.
4. En **nia_ → Preferencias** (`⌘,`) configura fuente monoespaciada, tamaño, cursor, tema, scrollback e IA.
5. Suelta un archivo o carpeta de Finder para insertar su ruta escapada sin ejecutar el comando.
6. Selecciona para copiar automáticamente. Doble clic selecciona palabra, triple clic línea y Shift+arrastre permite seleccionar un rectángulo.

### Comandos con IA

En una sesión **Zsh local** comienza con `?` y pulsa Enter:

```text
?busca los archivos mayores de 1 GB en este directorio
```

nia_ consulta el modelo configurado. Si la ejecución automática está activada, **solo** se ejecutan patrones sencillos aprobados por un validador independiente. Las operaciones complejas o potencialmente destructivas deben revisarse antes de ejecutarse. Que un LLM proponga un comando no significa que sea correcto o seguro.

Hay un modelo Interno pequeño ejecutado bajo demanda con `llama.cpp`, un proveedor **Local** compatible con la API OpenAI (vLLM, Ollama, LM Studio, etc.), y conectores de OpenAI, Anthropic, Gemini y OpenRouter. Las claves de los proveedores se guardan en Keychain. El modelo pequeño solo es apropiado para comandos básicos, no para instalaciones ni configuración de servicios. La interceptación `?` aún se limita a Zsh local; no se garantiza en Bash, Fish ni shells remotas.

Consulta [README-NIA-AI.md](README-NIA-AI.md) y [README-INTERNAL-AI.md](README-INTERNAL-AI.md), teniendo en cuenta que algunos documentos históricos describen versiones anteriores.

### Remote: continuar una sesión de otro Mac

Activa Inicio de sesión remoto en el Mac de origen, configura una clave SSH verificada e instala `tmux` allí. Crea una sesión remota en nia_ usando un alias de `~/.ssh/config`. Los comandos, archivos, CPU y RAM siguen estando en el equipo remoto; SSH transporta la terminal cifrada y autenticada. Cerrar el cliente suele mantener viva la sesión tmux, pero apagar el equipo remoto finaliza sus procesos. Consulta [README-REMOTE.md](README-REMOTE.md).

**Nia Sync bidireccional automático todavía no está implementado.** El traspaso actual utiliza backups cifrados, no fusiona dos bases de datos activas. Consulta [README-HANDOFF.md](README-HANDOFF.md).

## Arquitectura

```text
native/Sources/             SwiftUI/AppKit, MTKView e IA
native/include/             Puente C entre Swift y Rust
src/lib.rs                  FFI y sesiones Rust
src/terminal.rs             PTY y emulación VT
src/storage.rs              SQLite y estado persistente
src/history.rs              Historial indexado paginado
src/bin/nia-backup.rs       Backup/restauración con restic
scripts/build-native-macos.sh  Empaquetador nativo
assets/                     Icono
```

**Compatibilidad de datos:** se conserva deliberadamente `~/Library/Application Support/ember-terminal/` para evitar perder sesiones. **No lo borres ni lo renombres** por el cambio de marca. También se mantiene el identificador del bundle `dev.nia.terminal` para conservar las preferencias y acceso a credenciales existentes.

## Rendimiento, privacidad y seguridad

Metal dibuja el terminal y Rust gestiona PTY y sesiones. La IA Interna se ejecuta bajo demanda y utiliza memoria adicional mientras está cargada. No hay mediciones comparativas verificadas que permitan garantizar un consumo concreto de RAM/CPU. Para medir, separa aplicación, shells hijas, GPU e inferencia.

Los historiales y backups pueden contener secretos. Protege el repositorio restic. Al utilizar APIs externas, las consultas se envían al proveedor correspondiente; con Interno se procesan en tu Mac (salvo la descarga inicial de pesos). La autoejecución de comandos cuenta con una lista limitada, pero no es un sandbox de seguridad.

## Estado del proyecto

nia_ es un prototipo en desarrollo. Sigue pendiente un reflow completo para todas las salidas antiguas, hay comportamientos TUI sin validar, la sincronización bidireccional automática no está implementada y Nia Remote está en fase experimental. Reporta errores con pasos reproducibles y registros anonimizados.

## Licencia y contribuciones

**MPL-2.0**. Permite uso privado, gratuito y comercial, modificación y redistribución. Al distribuir modificaciones de archivos cubiertos por MPL, debes facilitar su código fuente a los destinatarios bajo la misma licencia. **No obliga a publicar cambios privados ni a abrir un PR público.** Consulta [LICENSE](LICENSE), [LICENSE-NOTICE.md](LICENSE-NOTICE.md) y [CONTRIBUTING.md](CONTRIBUTING.md). Las dependencias y los modelos descargados mantienen sus licencias propias: [THIRD_PARTY.md](THIRD_PARTY.md).

Repositorio: **https://github.com/vicktor/nia_**

## Publicar una release en GitHub

Instala y autentica GitHub CLI (`brew install gh && gh auth login`),
guarda tus cambios en un commit y súbelos al repositorio. Después, desde macOS:

```bash
./scripts/release.sh 0.6.1 --prerelease
```

El script exige un árbol Git limpio, un commit ya publicado y la versión
correcta en `Cargo.toml` y en el bundle. Compila `dist/nia_.app`, comprueba
la firma y la arquitectura, crea un ZIP con `ditto`, calcula SHA-256, crea
la etiqueta y publica el ZIP y la suma de comprobación en
`github.com/vicktor/nia_`. También acepta `--stable` y `--draft`.
La firma actual es de desarrollo (*ad hoc*): **no hay notarización de Apple**.
