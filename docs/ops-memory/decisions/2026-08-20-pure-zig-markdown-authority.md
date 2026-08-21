# Decision: Pure-Zig Markdown Parser Is Authoritative

## Decision

Use the independently packaged pure-Zig `zig-markdown-parser` as Zine's only
production parser. Do not restore cmark-gfm as a selectable fallback or use
undocumented cmark quirks as the definition of correctness.

The compatibility target is the syntax and behavior declared in
`src/markdown/FEATURES.md` and covered by Zine's tests. The retained vendored
SuperMD code owns directive and Scripty context; it no longer owns a cmark AST
or the low-level Markdown parser.

## Date And Status

- Date: 2026-08-20
- Status: accepted
- Owners: fork maintainers

## Context

Original Zine used SuperMD's cmark-gfm-backed AST, which widened the C boundary
across parsing, nodes, traversal, source ranges, extensions, directives, and
worker-owned parser state. It also added translated headers, compiled C
libraries, and cross-target build inputs.

The migration first used cmark as a temporary differential oracle, then
removed the fallback after the compatibility corpus, semantic behavior,
snapshots, robustness tests, workflows, and release targets passed.

## Options Considered

- Keep cmark-gfm as the production implementation.
- Maintain permanent `cmark` and `zig` backends behind a build option.
- Make the pure-Zig parser authoritative after a bounded differential
  migration and document its supported surface explicitly.

## Consequences

- Zine has one parser implementation and no cmark runtime/build dependency.
- Low-level Markdown syntax, source ranges, rendering, and parser tests belong
  to `zig-markdown-parser`; Zine owns the compatibility AST facade and SuperMD
  semantic pass.
- CommonMark/GFM compatibility claims are limited to the documented and tested
  feature set; complete specification conformance is not implied.
- Intentional deviations—such as no indented code blocks and byte-oriented
  source columns—remain part of the declared contract until changed with tests
  and documentation.
- Parser changes must preserve the stable compatibility AST and SuperMD
  semantic boundary rather than couple syntax parsing to layouts, assets,
  Scripty, or SuperHTML.
- Broader CommonMark/GFM support should be added directly to the Zig parser
  with fixtures, not by reintroducing a fallback.

## Evidence And Verification

- Supported behavior: `src/markdown/FEATURES.md`
- Migration rationale and phases: `docs/plans/pure-zig-markdown-ast.md`
- Production gates: `docs/markdown-validation.md`
- Parser provenance: `zig-markdown-parser`'s `docs/UPSTREAM.md`
- Migration completion commit: `535dbe9`
- Standalone parser extraction: the `zig-markdown-parser` repository

Verification commands:

```sh
./build.sh test-markdown
./build.sh test-markdown-concurrency
./build.sh test-markdown-modes
./build.sh test-markdown-properties
./build.sh test
./build.sh test-workflows
./build.sh check-release-targets -Dpreview=true
```

## Revisit When

Revisit the documented syntax surface when users need additional CommonMark or
GFM behavior. Reconsider the single-parser decision only if evidence shows the
Zig implementation cannot meet a required behavior or safety constraint.

## Search Keywords

Markdown, CommonMark, GFM, SuperMD, cmark-gfm, pure Zig, parser backend,
compatibility AST, directives, Scripty, source ranges
