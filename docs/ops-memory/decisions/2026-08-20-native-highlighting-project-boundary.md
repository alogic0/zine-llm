# Decision: Develop Native Syntax Highlighting As A Separate Zig Package

## Decision

Native syntax highlighting will be developed in the independent
`zig-native-syntax` Zig package. Zine will own fenced-code language aliases,
CSS integration, and unsupported-language behavior, but it will not own
reusable language tokenizers or highlighting adapters.

Zine uses native highlighting by default and renders unsupported languages as
escaped plain text. The completed compatibility audit covers every former Flow
file type, so Flow and Tree-sitter are no longer Zine dependencies. An `off`
mode remains available for builds that disable highlighting.

## Date And Status

- Date: 2026-08-20
- Status: accepted
- Owners: fork maintainers

## Context

Zine previously used `flow-syntax` and Tree-sitter for build-time highlighting
of many languages. Zig's standard-library documentation renderer demonstrates
that native token and AST streams can instead be converted to escaped,
classified HTML. Zine and its dependencies already have native parsing or
tokenizing facilities for Zig, HTML, XML, SuperHTML, CSS, Ziggy, Ziggy Schema,
Scripty, and Markdown. The independent package now owns parser-backed adapters
and bounded lexical scanners for the complete supported language inventory.

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
- Tree-sitter removal required a separate compatibility decision after the
  ordered native roadmap: aliases, intentional grammar reuse, unsupported
  labels, build modes, generated-site rendering, and host build behavior all
  needed explicit evidence.
- The temporary `tree-sitter`, `native-first`, and `native-only` comparison
  modes were removed after that audit. `native` is now the default and `off`
  is the only alternative.

## Evidence And Verification

- Initial package: independent `zig-native-syntax` repository.
- Zine experiment branch: `experiment/native-highlighting`.
- Existing Zine integration points: `src/highlight.zig`, `src/worker.zig`,
  `build.zig`, and `build.zig.zon`.
- Initial package verification: `./build.sh test` from the package root.
- The integration routes eighty-eight canonical languages natively. Markdown uses
  the independent `zig-markdown-parser` package; Bash and Rust use bounded
  package-owned lexical scanners; JSON uses a source-offset scanner checked
  against the Zig standard scanner on valid corpus input. Zine owns aliases
  and SuperMD semantics.
- The final inventory test covers all 93 former Flow file-type names: 87 direct
  native routes and six intentional reused backends. Scripty is an additional
  Zine-only native language.
- Generated-site fixtures cover all 88 canonical native languages. Focused
  tests verify aliases, malformed input, unsupported-language escaping, and
  both supported build modes on the host architecture.
- The final ReleaseFast host comparison reduced the installed executable from
  156,455,424 bytes to 16,044,032 bytes and the loaded ELF sections from
  137,639,775 bytes to 3,970,099 bytes. These single-run measurements support
  dependency removal but are not portable performance thresholds.
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
