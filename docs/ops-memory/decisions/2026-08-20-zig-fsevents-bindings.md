# Decision: Replace Translate-C With Minimal Zig FSEvents Bindings

## Decision

The macOS live-reload watcher uses a small Zig ABI module that dynamically
loads CoreServices and resolves only the CoreFoundation and FSEvents symbols it
needs. Zine does not vendor or build `translate-c`, Aro, or an Apple framework
SDK bundle for this integration.

## Date And Status

- Date: 2026-08-20
- Status: accepted
- Owners: fork maintainers

## Context

Zine used `translate-c` solely to translate two Apple umbrella headers for the
macOS FSEvents watcher. That introduced a large C parser dependency and a
framework bundle into every dependency graph for a small, stable API surface.

The pinned Zig standard library does not expose a high-level recursive macOS
watcher. A newer Zig source tree contains a native FSEvents watcher and provided
a local reference for the dynamic-loading and ABI patterns used here.

## Options Considered

- Keep translating the Apple headers with vendored `translate-c` and Aro.
- Replace FSEvents with `kqueue`, accepting per-directory watches and additional
  recursive bookkeeping.
- Keep FSEvents and declare its small required ABI surface directly in Zig.

## Consequences

- macOS retains recursive FSEvents behavior without generated Zig or C headers.
- Cross-compiling macOS executables no longer needs the framework SDK package.
- ABI declarations must track the stable Apple API exactly; native macOS tests
  verify context layout, symbol resolution, stream startup, and a real rebuild.
- SuperHTML's separate Tree-sitter `@cImport` usage is unaffected.

## Evidence And Verification

- Implementation: `src/cli/serve/watcher/FSEvents.zig` and
  `src/cli/serve/watcher/MacosWatcher.zig`.
- Reference pattern: Zig standard library `lib/std/Build/Watch/FsEvents.zig`.
- Build and dependency removal: `build.zig`, `build.zig.zon`, and
  `vendor/UPSTREAM.md`.
- Runtime workflow: `build/serve_smoke.sh` and `.github/workflows/ci.yml`.
- Native verification: `./build.sh check`, `./build.sh test`, and
  `./build.sh test-workflows`.
- Cross-target semantic-check lesson:
  `../learnings/2026-08-20-macos-target-semantic-check.md`.
- Authoritative macOS and release-target verification runs in GitHub CI.

## Revisit When

Revisit if Apple removes one of the dynamically resolved symbols, Zig's pinned
standard library gains a suitable public recursive watcher, or Zine changes its
macOS watcher architecture.

## Search Keywords

translate-c, translate_c, Aro, FSEvents, CoreServices, CoreFoundation,
MacosWatcher, dynamic library, macOS live reload
