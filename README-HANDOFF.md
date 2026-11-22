# Nia 0.4.9 — traspaso cifrado y UI

## Arrastrar sesiones
La fila tiene una vista previa nativa y muestra una línea de inserción por encima o por debajo. El orden se guarda en SQLite en una sola transacción, sin cambiar los IDs ni los logs.

## Transparencia experimental
Preferencias → Apariencia permite opacidad 55–100 %. El área Metal utiliza un clear alpha configurable y la ventana permite composición alfa, manteniendo la barra de título nativa. La apariencia exacta requiere validación macOS: SwiftUI y el sistema de ventanas pueden componer fondos adicionales; la transparencia hacia el escritorio no está garantizada todavía. A 100 % la ventana vuelve a ser opaca.

## Primer traspaso cifrado entre Macs (NO sincronización en vivo)
En el Mac origen, configura `RESTIC_REPOSITORY` (destino SFTP/S3) y `RESTIC_PASSWORD_FILE` o `RESTIC_PASSWORD_COMMAND` según RECOVERY.md y ejecuta:

```bash
./scripts/nia-handoff.sh push
```

En el Mac destino, instala Nia y restic, configura el mismo repositorio, la clave de recuperación y el acceso SSH, y ejecuta:

```bash
./scripts/nia-handoff.sh snapshots
./scripts/nia-handoff.sh pull
```

El resultado se extrae en una carpeta **nueva**. No se sobrescribe la instalación local. Para importarlo, cierra Nia y sigue RECOVERY.md, tras respaldar la instalación de destino. La aplicación restaurará el workspace, siempre que las rutas y proyectos existan. No migra procesos vivos, ni hace reconciliación multi-Mac, ni transmite SSH ni instala los entornos virtuales Python.

## Pendiente para Nia Sync
- Identidad permanente por dispositivo y sesión (UUID), journal de eventos por dispositivo.
- Cifrado y blobs de scrollback inmutables, sincronización incremental.
- Política clara de conflictos y borrados; copias históricas independientes.
- Servicio residente PTY y reconexión remota para continuar procesos vivos.

No sincronices dos archivos SQLite vivos entre dispositivos ni uses GitHub privado como almacén de historiales en claro.
