# Nia v0.4.3.1 — Swift build fix

- Corrige la comparación de selección `Optional<(Int, Int)>` que impedía compilar `NiaTerminalView.swift`.
- El script de bundle ahora prepara la aplicación en un directorio temporal y solo publica `dist/Nia.app` cuando Swift y la firma terminan correctamente.
- Conserva el bundle anterior si falla la compilación o la publicación.
- Versiona el `Info.plist` como 0.4.3.

Compilación Swift completa: pendiente de comprobación en macOS.
