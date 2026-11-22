# Nia v0.2.1 — Preferencias de backup SFTP (prototipo)

- Nueva sección **Preferencias → Backup** para introducir servidor, usuario, ruta remota y ruta del archivo de contraseña de restic.
- La configuración NO contiene la contraseña y se guarda en `~/Library/Application Support/ember-terminal/backup.toml` (se mantiene la ruta heredada para evitar perder sesiones).
- Botones: guardar, inicializar repositorio nuevo, copia inmediata, listar snapshots, comprobar integridad y restaurar en directorio vacío.
- Operaciones en un hilo de trabajo para no bloquear el dibujo del terminal. Los mensajes detallados de restic se muestran en la salida de la aplicación iniciada por Cargo; la ventana muestra el estado final.
- `nia-backup` puede leer preferencias si `RESTIC_REPOSITORY` no está definido; las variables de entorno explícitas siguen sirviendo para recuperar datos desde un Mac nuevo.
- El aviso `block 0.1.6` procede de `wgpu-hal → metal` y continúa pendiente de resolución aguas arriba.

## Configuración de servidor

1. `brew install restic`.
2. Prepara acceso SSH por clave al servidor y verifica `ssh usuario@servidor` (idealmente sin preguntas interactivas).
3. Crea una carpeta para el repositorio en el servidor, por ejemplo `/srv/backups/nia` (accesible por tu usuario SSH).
4. Crea un archivo **local** de contraseña restic con permisos `0600` (nunca lo subas a Git). Guarda la misma contraseña en un gestor de contraseñas independiente del Mac.
5. Abre Nia → **⌘, → Backup**, rellena campos y guarda. `Inicializar` solo en repositorios completamente nuevos; después pulsa `Crear copia` y `Verificar integridad`.
6. Para probar recuperación, indica un directorio **vacío** en «Restaurar copia». No sobreescribe la base de datos de Nia.

## Limitaciones

- **Sin compilación ni pruebas de ejecución macOS en este entorno.** Verificar `cargo check` y luego `cargo run --release` en un Mac.
- Sin programación automática de copias ni sincronización bidireccional todavía. Tampoco hay explorador de snapshots en la ventana: se imprime el listado en la consola de lanzamiento.
- La configuración SFTP requiere autenticación SSH operativa. No implementa onboarding de SSH ni almacena credenciales SSH.
- Para una recuperación en otro equipo hace falta recordar servidor, usuario, ruta y contraseña; el archivo `backup.toml` se encuentra en el Mac perdido, por lo que los datos de conexión deben conservarse también fuera de él.
- El ZIP temporal se guarda sin cifrar en un directorio temporal hasta que restic lo cifra. Esto debe sustituirse por streaming antes de prometer cero rastros locales de los historiales.
- Las llamadas a restic usan variables de entorno de proceso en el prototipo de UI. Antes de introducir backups concurrentes o más proveedores, debemos aislar la configuración por proceso hijo.
