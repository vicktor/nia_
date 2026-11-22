# Ember Terminal v0.1.4 - correcciones macOS

- Se ha eliminado la rejilla fija de 100 x 28. El área terminal usa todo el espacio central disponible y redimensiona el PTY junto con `vt100`.
- Tab, flechas y Escape mantienen el foco sobre el canvas del terminal mediante `egui::EventFilter`.
- El fondo de la ventana utiliza el nivel de opacidad real. A opacidad 1.0 el color de limpieza es opaco; también se cubre toda el área terminal.
- Zsh publica de forma atómica el directorio de trabajo y el entorno virtual activo al terminar cada comando (`precmd`), y Ember los guarda por ID de sesión en SQLite.
- En reaperturas se utiliza el directorio persistido; si el venv sigue existiendo se activa con su script `bin/activate`.
- Se conservan el esquema SQLite, los registros de salida y los archivos HISTFILE de la versión 0.1.3.

## Prueba manual en macOS

`cargo run --release`

1. Deja la opacidad al 100% y comprueba que no se ve el escritorio a través de la ventana. Ajusta el deslizador y comprueba transparencia.
2. Haz clic en el terminal, escribe `ec` y pulsa Tab repetidas veces; el foco debe permanecer en el terminal.
3. Maximiza/redimensiona la ventana; `stty size` debe cambiar y el terminal cubrir el espacio central.
4. En una sesión, `cd /tmp`, pulsa Enter, espera a ver el prompt, cambia de sesión y vuelve. Cierra Ember, vuelve a abrirlo y comprueba `pwd`.
5. En una sesión, `python3 -m venv /tmp/ember-test-venv; source /tmp/ember-test-venv/bin/activate`, comprueba `$VIRTUAL_ENV`, reinicia Ember y verifica que aparece activado (solo Zsh).

## Límites conocidos

- La ejecución de procesos no sobrevive un reinicio del Mac. Se recuperan directorio, venv y registros.
- El hook de cwd/venv está implementado para Zsh; otras shells aún requieren adaptadores.
- La transparencia macOS depende de la composición de la ventana y falta validación en hardware real.
- La versión aún usa un polling de 30 Hz y un renderer inmediato por celdas, que deberán optimizarse.
- Las rutas que contengan un salto de línea no están contempladas por el formato del estado de shell.
- Las sesiones ya creadas en versiones anteriores solo recuperan el directorio después de ejecutar un comando con este hook habilitado; no se puede reconstruir el cwd anterior si nunca se capturó.
