# Decision: Develop Native Syntax Highlighting As A Separate Zig Package

## Decision

Native syntax highlighting will be developed in the independent
`zig-native-syntax` Zig package. Zine will own fenced-code language aliases,
CSS integration, unsupported-language behavior, and the transition away from
Tree-sitter, but it will not own reusable language tokenizers or highlighting
adapters.

Tree-sitter remains Zine's temporary compatibility and comparison backend while
the ordered native-language backlog is implemented. Native-only builds render
unsupported languages as escaped plain text, but the dependency will not be
removed merely because the current Zine fixtures no longer need it.

## Date And Status

- Date: 2026-08-20
- Status: accepted
- Owners: fork maintainers

## Context

Zine currently uses `flow-syntax` and Tree-sitter for build-time highlighting
of many languages. Zig's standard-library documentation renderer demonstrates
that native token and AST streams can instead be converted to escaped,
classified HTML. Zine and its dependencies already have native parsing or
tokenizing facilities for Zig, HTML, XML, SuperHTML, CSS, Ziggy, Ziggy Schema,
Scripty, and Markdown. The independent package also owns bounded Bash and Rust
lexical scanners; broader language support requires additional demand-backed
native implementations.

Those implementations have independent API, testing, dependency, and release
concerns and can benefit consumers other than Zine.

## Options Considered

- Implement every native highlighter directly in `src/highlight/`.
- Develop a reusable Zig package and integrate it incrementally with Zine.
- Keep Tree-sitter as the permanent and only highlighting backend.

## Consequences

- Native highlighters can be tested and released independently of Zine.
- Zine can use a local path dependency during experimentation and a pinned Git
  dependency after the package becomes stable.
- The package must expose source-preserving, safely escaped output and tolerate
  malformed or incomplete snippets.
- Language backends should be selectable so consumers do not compile unused
  parsers.
- A reusable parser needed by both Zine and a highlighting adapter must have an
  independent package boundary; adapters must not depend back on Zine-owned
  semantic layers.
- Removing Tree-sitter remains a separate compatibility decision because the
  native package does not initially cover all currently supported languages.
- Explicit `tree-sitter`, `native-first`, `native-only`, and `off` modes keep
  comparisons reproducible without making Tree-sitter the final fallback
  contract. `native-first` remains the default during the comparison period.

## Evidence And Verification

- Initial package: independent `zig-native-syntax` repository.
- Zine experiment branch: `experiment/native-highlighting`.
- Existing Zine integration points: `src/highlight.zig`, `src/worker.zig`,
  `build.zig`, and `build.zig.zon`.
- Initial package verification: `./build.sh test` from the package root.
- The integration routes twenty-four canonical languages natively. Markdown uses
  the independent `zig-markdown-parser` package; Bash and Rust use bounded
  package-owned lexical scanners; JSON uses a source-offset scanner checked
  against the Zig standard scanner on valid corpus input. Zine owns aliases
  and SuperMD semantics.
- Current generated-site fixtures no longer require a Tree-sitter language.
  Phase 12 Slice 12.1 added and validated explicit backend-selection modes on
  the host architecture. Tree-sitter remains available in `tree-sitter` and
  `native-first` modes while additional native backends are implemented and
  compared; `native-only` and `off` compile without importing it.
- Focused commands, first-spike measurements, output checks, and API findings
  are recorded in
  [Native Highlighting Integration Validation](../../native-highlighting-validation.md).

## Revisit When

Revisit the repository boundary if the implementation remains permanently
Zine-specific, or if maintaining a separately versioned package costs more
than the reuse and isolation it provides.

## Search Keywords

native syntax highlighting, zig-native-syntax, Tree-sitter, tree_sitter,
flow-syntax, flow_syntax, src/highlight.zig, syntax highlighting dependency
