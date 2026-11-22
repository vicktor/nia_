# Nia v0.5.3 — Quick Insert

- Doble Escape en 320 ms: `Ctrl+A`, `Ctrl+K` para limpiar la línea editable en shells con combinaciones Emacs por defecto.
- Escape simple se transmite después de 320 ms (importante para Vim/menus interactivos).
- Menú contextual nativo con UUID v4, SHA-1 y MD5 de 64 bytes aleatorios CSPRNG, y contraseña aleatoria de 28 caracteres.
- Los valores se insertan en el panel de destino sin Enter; las funciones generan datos de prueba o identificadores, no firmas de seguridad.
- Contraseña: aleatoriedad de Security/SecRandomCopyBytes y muestreo sin sesgo.
- No se añaden dependencias Rust ni se cambian los historiales.
- Requiere validar compilación y comportamiento en macOS.
