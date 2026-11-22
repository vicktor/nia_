# Nia v0.5.10 — Proveedor Local

- Renombrado «Ollama (local)» a «Local · API compatible» en Preferencias → IA.
- Descripciones actualizadas para abarcar Ollama, vLLM, LM Studio y llama.cpp.
- Se mantiene el valor interno `ollama` de `nia.aiProvider` para que la configuración previa siga funcionando.
- Se mantiene el endpoint predeterminado `http://127.0.0.1:11434/v1`, editable.
- Se requiere una API compatible con OpenAI `/v1/chat/completions`; proveedores locales con autenticación obligatoria aún necesitan implementación adicional.
