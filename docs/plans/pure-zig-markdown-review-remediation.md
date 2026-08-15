# Pure-Zig Markdown Review Remediation Plan

## Objective

Resolve the correctness, ownership, rendering, and build-isolation issues found
during review of `feat/pure-zig-markdown-ast` before the branch is merged.

The remediation must preserve the architecture established by the completed
pure-Zig Markdown migration:

```text
Markdown source
  -> syntax parser and compact Document
  -> stable compatibility AST
  -> SuperMD semantic analysis
  -> Zine page analysis
  -> Zine HTML renderer
```

Fix each issue at the layer that owns the relevant invariant. Renderer guards
may provide defense in depth, but they must not replace parser or ownership
fixes.

## Review findings in scope

1. URI autolinks are represented as leaf nodes but exposed as ordinary links,
   causing Zine to emit an opening `<a>` without visible text or a closing tag.
2. An undefined footnote reference is left in the semantic tree without
   footnote metadata, and Zine force-unwraps the missing metadata while
   rendering.
3. `Semantic.Ast.init` retains an `errdefer` for a `Document` after ownership
   has moved into the compatibility AST, allowing a later error to deinitialize
   the document twice.
4. Task-list markers are parsed into sidecar state, but Zine renders the items
   as ordinary list items and loses their checked state.
5. Release archive-tool discovery occurs during build configuration, so a
   compile-only release-target check can require `tar` even though it does not
   package artifacts.

## Success criteria

The work is complete when:

- Angle URI autolinks and plain HTTP(S) autolinks produce complete links with
  visible text in normal page rendering, section rendering, and table-of-
  contents rendering where applicable.
- Undefined footnote syntax is rendered as literal Markdown and never crashes
  page rendering.
- Forward, repeated, and case-insensitive footnote references resolve to the
  correct definition and retain stable numbering and IDs.
- Every allocation-failure point in parser and semantic AST initialization
  cleans up exactly once without leaks, double frees, or use of moved values.
- Task-list items render disabled checkbox controls that preserve checked and
  unchecked state.
- `check-release-targets` configures and runs without discovering or executing
  archive tools.
- Archive-tool failures remain limited to the `release` step.
- Focused Markdown tests, production workflow tests, the full test suite, and
  the release-target compile gate pass.

## Implementation principles

### Preserve the compatibility AST contract

The old cmark-backed pipeline exposed autolinks as link containers with text
children. Reproduce that structure in the syntax parser instead of teaching
every downstream consumer about a special leaf-link exception.

### Resolve syntax when the whole document is known

Footnote references can precede their definitions and the parser supports a
streaming `feedLine` API. Parse references provisionally, then resolve them in
`Parser.endInput()` after all blocks have closed. Do not rely on an input
pre-scan that only works for `Parser.feed()`.

### Make ownership transfer explicit

Cleanup for a value must stop being active at the lexical point where ownership
moves. Prefer a nested scope whose `errdefer` ends after a successful transfer
over flags or cleanup of an `undefined` value.

### Exercise the production renderer

Syntax rendering and semantic traversal are insufficient integration tests.
Every author-visible regression in this plan must pass through the same
`src/render/html.zig` path used by `zine release` and the development server.

### Keep compile and packaging gates independent

Constructing or running compile-only release checks must not inspect host
packaging programs. Host archive tools are an execution-time requirement of
the release packaging step only.

## Phase 1: Correct allocator ownership

### Slice 1.1: Scope `Document` ownership transfer

In `Semantic.Ast.init`, construct the compatibility AST in a nested block:

```zig
const md = blk: {
    var document = try parser.endInput();
    errdefer document.deinit(gpa);
    break :blk try Markdown.Ast.init(gpa, &document);
};

var result: Ast = .{
    .md = md,
    .options = options,
};
errdefer result.deinit();
```

The inner `errdefer` handles failures before ownership transfer. It expires
when the block exits successfully, after which `result` is the sole owner.

Acceptance checks:

- An error before `Markdown.Ast.init` succeeds destroys the standalone
  document once.
- An error during semantic analysis destroys `result` once and does not touch
  the moved-from local document.
- Successful initialization retains the current AST lifetime and API.

### Slice 1.2: Harden partial `Parser.init` failure

Add local cleanup for allocations that succeed before a later initialization
allocation fails. A partially initialized parser must be safe to deinitialize.

Acceptance checks:

- Failure of each initial `ArrayList` allocation leaks no memory.
- Successful initialization is unchanged.

### Slice 1.3: Exhaust allocation-failure paths

Add focused tests using `std.testing.checkAllAllocationFailures` for:

- `Parser.init`, `feed`, and `endInput`;
- `Semantic.Ast.init` with plain Markdown;
- semantic input containing directives, footnotes, and fenced HTML so that
  sidecar, Scripty, and SuperHTML allocations are exercised.

Each test helper must deinitialize a successfully returned parser, document, or
AST. The testing allocator must report no leaks for every injected failure.

Suggested commit boundary:

```text
markdown: harden parser and AST allocation ownership
```

## Phase 2: Restore autolink AST compatibility

### Slice 2.1: Emit a normal link subtree

Change angle and plain-text autolink parsing to emit:

```text
link
  target: normalized URI string
  children:
    text: visible URI string
```

For angle autolinks, the link range includes `<` and `>`, while the text range
covers only the URI. For plain autolinks, both ranges cover the recognized URI
without stripped trailing punctuation.

The visible text must be created directly without smart-punctuation
transformation or backslash unescaping. The URI target and visible text may
reuse the same interned string when their bytes are identical.

Once no parser path emits the compact `.autolink` tag, either remove that tag
and its renderer cases or retain it only if another documented internal use
still requires it. Do not leave a nominally supported tag with incompatible
leaf semantics.

### Slice 2.2: Test all downstream consumers

Add focused tests for:

- `<https://example.com/path>`;
- a non-HTTP scheme accepted by angle autolinks;
- plain `https://example.com/path`;
- stripped trailing punctuation;
- an autolink inside emphasis or a heading;
- source ranges for the link and visible text child;
- semantic analysis with `auto_target_blank` both disabled and enabled.

Add a production rendering fixture which verifies that the resulting anchor:

- has the expected `href`;
- contains the URI as text;
- has a closing `</a>`;
- does not absorb following punctuation or markup.

Exercise table-of-contents rendering with a heading containing an autolink so
that the compatibility child structure is validated outside normal page HTML.

Suggested commit boundaries:

```text
markdown: represent autolinks as link subtrees
render: cover autolinks through Zine workflows
```

## Phase 3: Resolve footnotes before semantic analysis

### Slice 3.1: Finalize references in `Parser.endInput`

After all pending blocks are closed and before buffers are shrunk or moved into
`Document`, run a footnote-resolution pass:

1. Collect footnote definition labels and their existing `StringIndex` values.
2. Visit every provisional footnote-reference node.
3. Match labels using the same case-insensitive policy used by reference links.
4. For a match, replace the reference's label index with the canonical
   definition label index.
5. For no match, convert the node to `.text` and store the reconstructed literal
   `[^label]` as its text content.

Preserve the original source span in both cases. Copy label bytes into scratch
storage before appending a reconstructed string, because growing
`string_bytes` can invalidate slices into that buffer.

Avoid an unbounded quadratic implementation if document-controlled input can
create large numbers of definitions and references. If a map is used, its keys
must have stable backing storage and its equality/hash policy must agree on
case-insensitive matching.

### Slice 3.2: Canonicalize semantic metadata

With resolved reference nodes carrying the definition's canonical label,
`Semantic.buildFootnotes` can continue using exact-key maps. Verify that:

- numbering follows first reference order;
- repeated references share one definition and receive distinct reference IDs;
- definition metadata records the correct reference count;
- unused definitions do not create invalid reference metadata;
- duplicate definitions follow the chosen compatibility rule and have a
  dedicated test.

### Slice 3.3: Make production rendering defensive

Replace the force-unwrapped footnote lookup in `src/render/html.zig` with a safe
fallback. An unexpected unresolved node should render an escaped literal
`[^label]` rather than terminating the process.

The parser resolution pass remains the primary fix. The renderer fallback is
defense against future AST invariant regressions or manually constructed ASTs.

### Slice 3.4: Add parser and workflow regressions

Cover:

- an undefined reference;
- a forward reference;
- a definition before its reference;
- repeated references;
- case differences between definition and reference labels;
- truncated reference syntax;
- a reference inside nested block content;
- valid definitions exposed through `$page.footnotes?()`;
- `zine release` of a page containing an undefined reference.

The undefined-reference workflow snapshot must contain literal `[^missing]`
and must not contain a generated footnote anchor.

Suggested commit boundaries:

```text
markdown: resolve footnote references at end of input
render: make unresolved footnotes non-fatal
```

## Phase 4: Render task-list state

### Slice 4.1: Consume `tasklistItemChecked`

Update the Zine HTML renderer's `.ITEM` enter event:

- `null`: emit an ordinary `<li>`;
- `false`: emit a disabled unchecked checkbox before item content;
- `true`: emit a disabled checked checkbox before item content.

Match the pure Markdown renderer and the committed cmark oracle exactly:

```html
<input type="checkbox" disabled="" />
<input type="checkbox" checked="" disabled="" />
```

Keep the control non-interactive. Do not infer new CSS classes or change list
tightness as part of this remediation.

### Slice 4.2: Add production snapshots

Cover unchecked `[ ]`, lowercase `[x]`, uppercase `[X]`, ordinary list items,
tight lists, loose lists, and nested task lists. Verify that the source marker
is absent from text and that the checkbox appears exactly once.

Suggested commit boundary:

```text
render: preserve Markdown task-list state
```

## Phase 5: Isolate release packaging tools

### Slice 5.1: Remove eager archive discovery

Remove `b.findProgram` for `gtar`/`tar` from build configuration. Packaging
commands may be constructed eagerly as inactive build graph nodes, but archive
tool discovery and execution must occur only when the `release` step runs.

Two acceptable implementations are:

1. Invoke `tar` directly in the release-only system command and allow that
   command to fail if the release host lacks it.
2. Add a release-only wrapper which selects `gtar` and then `tar` at execution
   time, reporting a precise error if neither exists.

Prefer the wrapper if retaining both program names is important. Do not add a
shell dependency to compile-only steps.

### Slice 5.2: Verify build-step isolation

Confirm these behaviors:

- `./build.sh check` does not inspect or execute `tar`, `gtar`, `zip`, or `xz`.
- `./build.sh test` does not inspect or execute archive tools.
- `./build.sh check-release-targets -Dpreview=true` compiles every supported
  target without inspecting or executing archive tools.
- `./build.sh release -Dpreview=true` still creates all expected archives.
- A missing archive tool produces a release-specific error only when release
  packaging is requested.

Suggested commit boundary:

```text
build: isolate release archive tooling
```

## Phase 6: Final integration validation

### Slice 6.1: Run focused gates

```sh
./build.sh test-markdown
./build.sh test-markdown-modes
./build.sh test-markdown-properties
./build.sh test-workflows
```

Extend the property suite so semantic parsing is not the final operation for
all structured malformed cases. At least the undefined-footnote and autolink
cases must reach a production-equivalent rendering path.

### Slice 6.2: Run full and release gates

```sh
./build.sh test
./build.sh check
./build.sh check-release-targets -Dpreview=true
./build.sh release -Dpreview=true
```

Verify that all eight release archives are produced and contain the `zine`
executable expected for their platform.

### Slice 6.3: Review repository state

- Run `git diff --check` for Zine-owned files and remove newly introduced
  whitespace errors.
- Confirm snapshots changed only where the fixes intentionally alter output.
- Confirm no temporary sites, logs, server processes, compiler processes, or
  packaging processes remain.
- Confirm the worktree contains only the intended remediation changes.
- Update `docs/markdown-validation.md` if a new permanent gate or fixture is
  introduced.

Suggested commit boundary:

```text
docs: record Markdown review remediation validation
```

## Completion checklist

- [x] Phase 1: allocator ownership is explicit and failure-injection tested.
- [x] Phase 2: autolinks use a compatibility-correct link subtree.
- [x] Phase 3: footnotes resolve at end of input and cannot crash rendering.
- [x] Phase 4: task-list checked state appears in Zine HTML.
- [x] Phase 5: compile-only gates are independent of archive tools.
- [x] Phase 6: focused, full, workflow, and release validation passes.

The remediation is complete only when every checkbox above is satisfied and
the branch review can be repeated without the original findings.
