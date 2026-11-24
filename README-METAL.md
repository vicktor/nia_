# Nia v0.4.0 — Metal preview

Esta versión sustituye la vista AppKit temporal por una vista Metal real con shaders GPU y caché de glifos. El núcleo de sesiones continúa en Rust y el shell sigue funcionando mediante PTY.

### Instalar y ejecutar (macOS 14+)

```sh
./scripts/build-native-macos.sh
open dist/Nia.app
```

Requisitos: Xcode Command Line Tools, Rust y macOS compatible con Metal.

### Nota de compatibilidad

El nuevo protocolo entre Rust y Swift cambia `ScreenSnapshot.rows` por `ScreenSnapshot.cells`: es imprescindible recompilar ambos componentes con el mismo paquete. No mezclar la biblioteca `libnia_core.dylib` de v0.3.1 con esta aplicación.

Datos persistentes: la v0.4.0 sigue utilizando la base de datos existente de las versiones previas. Antes de actualizar, haz una copia recuperable y verifica restauración. No borres `~/Library` ni los historiales de sesiones.

La interfaz nativa se compila y firma en macOS. Consulta [STATUS.md](STATUS.md) para conocer la validación disponible y las limitaciones de la beta.


## v0.4.1
- Cleaner session list styling
- Plain title without bordered capsule
- Cursor row adjustment for blank trailing rows
