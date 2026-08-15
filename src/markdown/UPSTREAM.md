# Zig Markdown upstream provenance

The Markdown implementation planned for vendoring in this directory comes from
the Zig compiler distribution identified below. Phase 0 records the untouched
inputs before Phase 1 copies them into the repository.

- Zig version: `0.17.0-dev.1756+613c03321`
- Zig commit: `613c03321a0970cce3a5d04ede04ab4a24ac1dbb`
- Commit date: `2026-08-12`
- Commit subject: `langref: fix typos`
- Installed source root: `~/.zig/0.17.0-dev.1756+613c03321/files`
- Upstream repository: `https://codeberg.org/ziglang/zig`
- License: MIT (Expat), copyright Zig contributors
- License SHA-256: `5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`
- Provenance recorded: `2026-08-15`

The four source files do not carry separate copyright headers. They are covered
by Zig's repository-level MIT license, reproduced in `LICENSE`.

## Original files

| Future repository path | Original path under the installed source root | SHA-256 |
| --- | --- | --- |
| `src/markdown.zig` | `lib/docs/wasm/markdown.zig` | `c46ef5738f5ad768a6a3b83284cd346e52ac5255bf4ebf1c3db27067c5a258ad` |
| `src/markdown/Parser.zig` | `lib/docs/wasm/markdown/Parser.zig` | `598e3dfe25e469a4b26de971f167c974b5e5e578abbe45b90d679864fc083116` |
| `src/markdown/Document.zig` | `lib/docs/wasm/markdown/Document.zig` | `873cc539d8f42d49edcddfdbef4bcdf8cbdb2805d8e487d5102e8b9db8c62268` |
| `src/markdown/renderer.zig` | `lib/docs/wasm/markdown/renderer.zig` | `dbb45186d0a7a3271140a23f50160d93e7e32997c1784f39729ca1b29065b2ef` |

Verify the installed inputs with:

```sh
sha256sum \
  ~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown.zig \
  ~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown/Parser.zig \
  ~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown/Document.zig \
  ~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown/renderer.zig
```
