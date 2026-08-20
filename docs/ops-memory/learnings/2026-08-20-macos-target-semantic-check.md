# Learning: Compile Target-Gated Zig Code For Its Target

## Lesson

A passing host test does not prove that code behind a target-specific comptime
branch compiles. Compile macOS-only Zig modules for a macOS target with the
repository's pinned compiler before relying on native CI for runtime coverage.

## Context And Symptom

The Zig-only FSEvents replacement passed the Linux development test gate, but
the macOS GitHub Actions runner failed while compiling
`src/cli/serve/watcher/FSEvents.zig` with Zig
`0.17.0-dev.1756+613c03321`:

```text
error: no field named 'fields' in struct 'lang.Type.Struct'
```

The failure prevented the native FSEvents ABI and live-reload tests from
running.

## Cause Or Explanation

The non-macOS test path returns `error.SkipZigTest` from a comptime-known target
condition. Zig's lazy semantic analysis therefore did not analyze the call to
`Api.init` on the Linux host. The pinned Zig reflection API represents struct
fields as parallel `field_names`, `field_types`, and `field_attrs` arrays, not
as a `.fields` array.

## Check First

- Read `.minimum_zig_version` in `build.zig.zon` and the compiler path in
  `build.sh`; do not use an unrelated `zig` from `PATH`.
- Inspect the pinned standard library's `lib/std/lang.zig` before assuming a
  reflection layout from another Zig version.
- Check whether an OS or architecture condition lets the host compiler avoid
  analyzing the changed code.

## Verified Approach

Iterate `@typeInfo(Symbols).@"struct".field_names` and `.field_types` together.
Then run a compile-only check for the affected target with the Zig executable
declared in `build.sh`:

```sh
<pinned-zig> test src/cli/serve/watcher/FSEvents.zig \
  -target aarch64-macos -fno-emit-bin
./build.sh test -Dno-git-version
```

Both commands passed after the reflection loop was corrected. Native macOS CI
remains authoritative for loading CoreServices, resolving symbols, starting an
FSEvents stream, and exercising a real live-reload rebuild.

## Avoid

- Do not treat a skipped platform test as semantic coverage of its dead branch.
- Do not infer pinned-nightly APIs from Zig 0.16 or another 0.17 development
  build.
- Do not move this repository-specific compiler and CI workflow into a general
  Zig skill.

## References

- `AGENTS.md`
- `build.sh`
- `build.zig.zon`
- `src/cli/serve/watcher/FSEvents.zig`
- `docs/ops-memory/decisions/2026-08-20-zig-fsevents-bindings.md`

## Search Keywords

FSEvents, MacosWatcher, no field named fields, lang.Type.Struct, field_names,
field_types, aarch64-macos, fno-emit-bin, target-specific comptime, skipped
test, Zig 0.17
