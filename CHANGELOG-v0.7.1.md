# nia_ v0.7.1 — Session exit confirmation / EN + ES

## English

- Confirm intercepted `exit` and `logout` commands **before** they reach local interactive Zsh; configurable under Settings → General.
- Cancel without closing the shell. On confirmation, exit normally; remove the tab after the PTY exits and its output is flushed.
- Keep the session history and metadata for later reopening.
- Persist and respect English, Spanish or the macOS system language.
- Localize interface text, menus, AI prompts/status, settings and native terminal context menus.
- Include `en.lproj` and `es.lproj` catalogs in the application bundle.

## Español

- Confirmación configurable antes de ejecutar `exit` o `logout` en Zsh local (Preferencias → General).
- Cancelar mantiene la shell; confirmar la cierra y retira la pestaña tras guardar su salida.
- Se conserva el historial para una futura recuperación.
- Idiomas inglés, español o selección automática según macOS.
- Traducción de interfaz, menús, IA, estados, preferencias y menú contextual.
- Los catálogos se empaquetan con la aplicación nativa.

## Limits / Límites

- Interception is limited to local interactive Zsh; remote or other shell exits are detected after they occur.
- Manual macOS build validation is still required. No GitHub Actions used.
