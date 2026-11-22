# Nia v0.2.2 — título opaco e icono propio

- Ventana nativa opaca (`with_transparent(false)`) para impedir la transparencia accidental de la barra de título.
- Fondo central explícitamente opaco y framebuffer con alfa 1.0.
- El ajuste de opacidad queda temporalmente desactivado en Preferencias hasta implementar una solución específica de macOS que no afecte a la barra superior.
- Icono de la aplicación: `assets/nia-icon.png`, una n minúscula blanca sobre azul.
- `scripts/build-macos.sh` genera `dist/Nia.app` con `Nia.icns`, incluye `nia-backup` y firma ad hoc.
- `restic` sigue siendo una dependencia externa, no empaquetada.

## Ejecutar

```bash
cargo run --release
./scripts/build-macos.sh
open dist/Nia.app
```

No hay cambios de esquema en SQLite ni borrado de sesiones. No compilado ni ejecutado en macOS en este entorno.
