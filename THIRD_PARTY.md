# Third-party components / Componentes de terceros

nia_ is built using third-party software with independent licenses. The project's MPL-2.0 applies to nia_-owned source code, **not** to unrelated third-party works.

| Component | Role | Licensing note |
| --- | --- | --- |
| Rust crates (`portable-pty`, `vt100`, `rusqlite`, `zip`, etc.) | Terminal, storage and recovery | Check each crate's license and Cargo.lock before distribution. |
| Apple SwiftUI, AppKit, Metal, CoreText | macOS UI and rendering | Provided by Apple subject to Apple's SDK/platform terms. |
| `llama.cpp` | Optional local model runner | Independently licensed; include upstream copyright notices when redistributing its binaries. |
| `sahellx/kitty-bash-llm` | Optional downloaded GGUF model | The model is downloaded separately; verify model card, weights, and license prior to redistributing. |
| `restic` | Backup utility installed separately | Governed by restic's own license. |
| OpenAI, Anthropic, Gemini, OpenRouter and compatible services | Optional remote AI | Subject to provider terms and privacy policies, not bundled software licenses. |

**Release checklist / Antes de publicar:** run `cargo license` or equivalent dependency-license analysis, inspect the exact pinned revisions, preserve notices in the distributable, and obtain rights for any contributed assets. Source code is not a blanket license for fonts, trademarks, or model weights.
