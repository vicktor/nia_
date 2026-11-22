# Nia 0.5.7 — Corrección de compilación de IA interna

- Desactiva la Web UI de llama.cpp al construir `llama-server` (`LLAMA_BUILD_UI=OFF`, `LLAMA_USE_PREBUILT_UI=OFF`).
- Elimina las carpetas temporales de recursos UI incompatibles de ejecuciones fallidas.
- Conserva la inferencia Metal y el servidor JSON utilizado por Nia.
- Mantiene la publicación atómica de `Nia.app` y la versión anterior si falla la construcción.
- No cambia la base de datos ni las sesiones existentes.

Validación realizada: sintaxis Bash, estructura ZIP y comprobación estática de la modificación. No se ha compilado en macOS.
