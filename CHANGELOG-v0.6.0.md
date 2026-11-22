# nia_ v0.6.0 — Brand and documentation

- Application and macOS bundle renamed from Nia to **nia_** (`dist/nia_.app`).
- The macOS executable is `nia`; the repository remains `https://github.com/vicktor/nia_`.
- `CFBundleIdentifier` and the existing legacy session storage location are kept to protect user preferences and history.
- About dialog shows `nia_` and reads its version from the app bundle rather than a hard-coded stale string.
- The legacy build script delegates to the maintained native build.
- Replaced stale README with detailed bilingual documentation (`README.md`, `README.es.md`).
- Added MPL-2.0, contribution instructions, licensing explanation, and third-party notices.
- No session database migration, terminal rendering, or AI behavior changed.
