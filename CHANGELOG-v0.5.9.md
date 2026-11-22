# Nia 0.5.9 — AI capability guardrails and official providers

- Nia Internal (0.5B) explicitly limited to simple Bash/Zsh commands.
- Complex/ambiguous requests (e.g. Cloudflare Tunnel) are declined *before* model invocation; no automatic execution.
- Uses official OpenAI Responses, Anthropic Messages and Gemini generateContent APIs.
- All keys stored per provider in macOS Keychain; configured model per provider.
- Ollama, OpenRouter and OpenAI-compatible endpoints retained.
- Existing independent execution allowlist still governs automatic execution.

Note: heuristic capability routing is intentionally conservative. It is not a safety boundary; command authorization remains in NiaAIExecutionPolicy.
The full macOS application must still be built and tested on a Mac.
