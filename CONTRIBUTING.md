# Contributing to nia_ / Contribuir a nia_

Thank you for helping improve nia_! / ¡Gracias por contribuir a nia_!

## English

1. Check existing issues and open a focused issue for major behavior changes before coding.
2. Fork [vicktor/nia_](https://github.com/vicktor/nia_), create a branch, and keep pull requests small and reviewable.
3. Run `cargo fmt --check`, `cargo test` and the macOS native build script when your change affects the app.
4. Include a reproduction procedure for UI and PTY bugs. For session restoration changes, test two terminals in split and restart the app.
5. Do not commit API keys, credentials, raw terminal histories, local models, or personal directories. Sanitize screenshots and logs.
6. Follow MPL-2.0 for changes to covered files; retain notices. By contributing you confirm you have rights to license your contribution under MPL-2.0.
7. Document changes in both English and Spanish when they affect installation, features, or user-visible behavior.

We welcome improvements to Metal efficiency, terminal compatibility, accessibility, session recovery, AI safety, and synchronization. Security issues should be disclosed privately to the maintainers rather than posted with exploit details in public issues.

## Español

1. Consulta las incidencias existentes y abre una propuesta antes de introducir cambios grandes.
2. Haz fork del repositorio, crea una rama y presenta pull requests pequeños y revisables.
3. Ejecuta `cargo fmt --check`, `cargo test` y el script de compilación nativo en macOS cuando corresponda.
4. Incluye pasos para reproducir errores de UI y PTY. Si modificas restauración, prueba dos sesiones en split y reinicia la app.
5. No subas claves, credenciales, historiales privados, modelos ni rutas personales. Anonimiza capturas y registros.
6. Respeta MPL-2.0 en los archivos cubiertos y conserva los avisos. Al contribuir, confirmas que tienes derecho a licenciar tu aportación bajo MPL-2.0.
7. Actualiza la documentación en inglés y español cuando cambien la instalación o las funcionalidades.

Las mejoras voluntarias se agradecen. MPL-2.0 exige compartir ciertos cambios **al distribuirlos**, pero no obliga a publicar cambios privados ni a enviar PR al repositorio original.
