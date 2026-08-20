## Commit Message Workflow

When creating a commit, first create a temporary file and write the complete commit message
into that file. Then create the commit with `git commit -F path_to_temp_file`. Do not use
`git commit -m`. Remove the temporary file after the commit succeeds.

## Pinned Zig And Target-Specific Validation

Treat `.minimum_zig_version` in `build.zig.zon` as the compiler source of truth
and use `./build.sh` for normal local build and test commands. Do not assume that
`zig` on `PATH` is the pinned compiler.

Host tests are insufficient for code eliminated by target-specific comptime
branches. When changing macOS-only watcher code, use the compiler executable
declared in `build.sh` to run this compile-only check before relying on CI:

```sh
<pinned-zig> test src/cli/serve/watcher/FSEvents.zig \
  -target aarch64-macos -fno-emit-bin
```

This check verifies target-specific semantic analysis but does not replace the
native macOS CI tests for symbol resolution and live-reload behavior. See
`docs/ops-memory/learnings/2026-08-20-macos-target-semantic-check.md`.

## Shared Engineering Memory

`docs/ops-memory/` is durable engineering memory shared by human and AI-assisted
contributors. Before repeating a substantial investigation, or when a task
involves a familiar compiler/build failure, release regression, upstream sync
conflict, or architecture/compatibility question, search it first:

```sh
rg -n "keyword|error|component|dependency" docs/ops-memory docs/plans docs
```

Add or update a concise note when work produces knowledge likely to prevent a
future mistake or repeated investigation, including:

- a consequential architecture, compatibility, dependency, or release decision;
- a recurring build or compiler failure and its verified resolution;
- a significant release-blocking regression;
- an upstream synchronization conflict with a reusable resolution;
- an incorrect LLM assumption that future contributors should avoid.

Do not create memory notes for routine implementation, ordinary one-off fixes,
temporary chat summaries, or details already captured adequately by stable
documentation. Plans belong in `docs/plans/`; current supported behavior and
commands belong in the relevant reference or validation document.

Follow `docs/ops-memory/README.md` for placement and content rules. Never record
secrets, credentials, private data, or lengthy raw logs.
