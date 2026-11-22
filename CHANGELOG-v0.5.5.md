# Nia 0.5.5 — AI command generation

- Línea que comienza por `?` en Zsh local se intercepta antes de ejecutarse.
- Configuración de proveedor IA desde Preferencias (Ollama/OpenAI/OpenRouter/OpenAI-compatible).
- API keys en Keychain; Ollama local sin clave.
- System prompt para responder con un único comando de shell macOS.
- Vista previa editable antes de insertar sin Enter ni ejecución automática.
- Consulta ligada a su sesión original, también en split.
- Restricción de endpoints remotos a HTTPS.
- Limitaciones: sesión local Zsh solamente; sin cola para consultas simultáneas; sin prueba macOS completa en este entorno.
