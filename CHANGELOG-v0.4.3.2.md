# Nia 0.4.3.2 — Limpieza de avisos de compilación

- Se conservan con anotaciones **puntuales** los métodos de almacenamiento que usa la interfaz antigua egui, pero no la biblioteca de SwiftUI.
- Se documenta del mismo modo `BackupConfig::save`, utilizado por la interfaz antigua y no por el CLI de backups.
- Se eliminan `LiveTerminal.id` y `LiveTerminal.record`, campos redundantes cuya información sigue existiendo en el gestor de sesiones y SQLite.
- Sin cambios en el esquema SQLite, formato de historial, API FFI, renderer Metal o atajos.
- El aviso de compatibilidad futura de `block 0.1.6` es de una dependencia transitiva de `wgpu-hal`/Metal. No se oculta globalmente: requiere una actualización del stack gráfico, con pruebas reales en macOS.

Verificación en este entorno: revisión estática del código y archivo ZIP. Sin compilación Rust/macOS disponible aquí.
