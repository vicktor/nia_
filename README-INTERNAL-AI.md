# Nia v0.5.6 · Modelo interno

- Preferencias ampliadas a 830 × 570 puntos ideales.
- IA → Interno utiliza `sahellx/kitty-bash-llm` GGUF Q4_K_M (~398 MB, Apache-2.0).
- El usuario pulsa **Descargar modelo**, no se descarga automáticamente.
- El archivo se guarda en `~/Library/Application Support/Nia/Models/`.
- El script de macOS requiere `cmake` y `git` y compila `llama-server` desde el tag `v1.0.0` de llama.cpp con backend Metal y librerías estáticas. Es una compilación más larga que la versión anterior.
- El servidor se ejecuta bajo demanda, ligado a 127.0.0.1 y protegido por una clave aleatoria de sesión. Se detiene tras 90 segundos sin consultas o al cerrar Nia.
- Las preguntas y respuestas locales no se envían a OpenAI ni a Hugging Face. Solo la descarga del modelo requiere Internet.
- Los comandos deben revisarse antes de ejecutarse. Un modelo de 0.5B puede equivocarse en sintaxis específica de macOS.
- Limitación: compilación SwiftUI/Metal y funcionamiento real necesitan probarse en macOS. Este paquete no incluye los pesos GGUF.

Para redistribución, revisar y adjuntar los avisos de licencia de llama.cpp y sus dependencias, además de la licencia del modelo descargado.
