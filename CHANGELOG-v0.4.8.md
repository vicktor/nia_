# Nia v0.4.8 — Persistencia del workspace dividido

- Se persisten ambos IDs de sesión, orientación y panel enfocado juntos en SQLite.
- La restauración abre primero ambas sesiones guardadas, sin elegir una primera sesión arbitraria.
- Se actualiza el estado al cambiar un panel, activar una sesión, activar/desactivar split o archivar una sesión.
- Se conservan los datos anteriores y se migran una vez los ajustes antiguos de UserDefaults.
- El registro ANSI y el historial paginado de cada sesión permanecen intactos.
- La reproducción del log ANSI nativo usa bloques de 64 KiB y ya no ignora registros mayores de 32 MiB. Para archivos gigantes, los checkpoints serán una futura optimización de velocidad.
- Compilación macOS no verificada en este entorno.
