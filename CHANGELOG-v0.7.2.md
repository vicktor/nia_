# nia_ v0.7.2 — Command Timeline / Historial de comandos

## English
- Local Zsh now records each **completed command** with start time, directory, elapsed time and exit code.
- Open the latest 200 commands with **⌘⇧H** or right-click a session in the sidebar.
- Search by command or working directory, copy text or insert it into the PTY **without pressing Return**.
- Lightweight implementation: built-in `preexec`/`precmd` shell hooks, NUL-framed append-only journal, and indexed SQLite table. No new daemon or model.
- Data is stored on-device; command strings might include passwords or tokens, so protect the database and backups.

## Español
- Zsh local registra cada **comando completado** con hora de inicio, directorio, duración y código de salida.
- Abre los últimos 200 comandos con **⌘⇧H** o clic derecho sobre una sesión.
- Busca por texto o directorio, copia el comando o insértalo en la PTY **sin pulsar Intro**.
- Diseño ligero: hooks `preexec`/`precmd` de Zsh, registro incremental separado por NUL y tabla SQLite indexada. Sin demonios ni modelos adicionales.
- Los comandos podrían contener contraseñas o tokens; protege SQLite y sus copias cifradas.

## Limits / Límites
- Only completed commands in local Zsh are captured in this preview. Other shells, remote tmux and commands killed before reaching a prompt may not be logged.
- This is a searchable command timeline, not yet navigation to exact VT scrollback offsets.
- Manual macOS build and functional verification are required. No GitHub Actions.
