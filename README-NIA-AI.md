# Nia v0.5.5 — Natural-language commands

## Uso

En una sesión local **Zsh** de Nia, escribe una línea que empiece por `?` y pulsa Enter:

```text
?quiero buscar los archivos mayores de 1mb
```

La línea se intercepta en el widget `accept-line` de Zsh. **No se ejecuta en la shell** y no se añade al historial normal de comandos. El widget la escribe transitoriamente a un archivo privado (permisos `0600`) en el directorio de sesión; Rust lo lee y borra, y la entrega a SwiftUI.

El asistente devuelve solo un comando, nunca lo ejecuta automáticamente. Nia muestra el resultado editable, con acciones **Insertar en terminal** y **Cancelar**. La inserción no incluye Enter.

## Configuración

Nia → Preferencias → **IA**:

- **Ollama**: endpoint `http://127.0.0.1:11434/v1` y modelo instalado (por ejemplo `qwen2.5-coder:7b`). No requiere API key.
- **OpenAI**: endpoint `https://api.openai.com/v1`, modelo configurado y API key.
- **OpenRouter**: endpoint `https://openrouter.ai/api/v1`, modelo y API key.
- **Compatible con OpenAI**: endpoint propio compatible con `/chat/completions` y API key.

El campo endpoint es una URL base: Nia añade `/chat/completions`.
Solo se acepta HTTPS para hosts externos; HTTP se permite exclusivamente en `localhost`, `127.0.0.1` o `::1`.

Las API keys se guardan en Keychain mediante Security.framework; nunca en SQLite, preferencias ni archivos de Nia.

## Prueba manual

1. Compila y abre `Nia.app`; crea una sesión local Zsh nueva o reinicia una existente para cargar el hook.
2. Verifica que `echo hola` continúa funcionando y el autocompletado con Tab no cambia.
3. Configura proveedor y modelo en Preferencias → IA.
4. Teclea `?quiero buscar los archivos mayores de 1mb` y pulsa Enter.
5. Comprueba que aparece una propuesta de un solo comando (por ejemplo `find . -type f -size +1M`), pero **no se ejecuta**.
6. Pulsa Insertar; el comando debe aparecer en la sesión correspondiente. Pulsa Enter para ejecutarlo voluntariamente.
7. Repite con dos sesiones en split, asegurándote de insertar en la sesión que originó la consulta.

## Alcance inicial

- Interceptación en la shell local **Zsh**. Las sesiones SSH/tmux remotas, Bash y Fish necesitan integración específica para garantizar el mismo comportamiento; en ellas el prefijo `?` todavía podría ser tratado por la shell y no debe utilizarse como comando de IA.
- Las consultas simultáneas se encolan en memoria y se muestran una detrás de otra; no se conservan tras cerrar Nia.
- El modelo puede equivocarse y generar comandos peligrosos; **revisar siempre antes de ejecutar**. Nia no ejecuta la propuesta y rechaza respuestas multilínea o con caracteres de control.
- La consulta se envía al proveedor elegido, que aplicará su política de tratamiento de datos. Si necesitas máxima privacidad, usa Ollama local.
- Las consultas no entran al historial de comandos de Zsh, pero el prompt puede permanecer en la salida visual capturada hasta que se borre la pantalla.

## Arquitectura

- `src/terminal.rs`: widget `zle -N accept-line`, archivo `ai-request` privado por sesión.
- `src/lib.rs`: lectura de requests y puente FFI `nia_take_ai_queries`.
- `native/Sources/NiaApp.swift`: recepción y ruteo a sesión correcta.
- `native/Sources/NiaAI.swift`: proveedor, Keychain, prompt, validación de respuesta y UI.
