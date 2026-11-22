# nia_ v0.6.1 — Titlebar & release automation

- Adds a dedicated opaque titlebar backdrop when the Metal terminal is translucent.
- Preserves the native titlebar buttons and ordinary dark/light system colors.
- Preserves transparency in the terminal content area, rather than making the whole window clear.
- Adds `scripts/release.sh` to build, verify, archive and publish a GitHub release.
- Retains the `nia` executable and existing data directory and bundle identifier.

**Testing:** macOS visual validation is still required, including Light/Dark
Mode, window resizing, switching split layouts, and changing opacity repeatedly.
