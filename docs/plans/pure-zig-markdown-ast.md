# Pure-Zig Markdown AST Producer Plan

## Objective

Replace SuperMD's cmark-gfm-backed CommonMark/GFM parsing with a pure-Zig AST producer derived from Zig `0.17.0-dev.1756+613c03321`'s documentation Markdown implementation:

```text
~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown.zig
~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown/Parser.zig
~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown/Document.zig
~/.zig/0.17.0-dev.1756+613c03321/files/lib/docs/wasm/markdown/renderer.zig
```

The resulting module must preserve Zine's author-facing SuperMD behavior, diagnostics, page analysis, and rendered output while removing cmark-gfm and its C build dependencies.

The copied files are a starting point, not a dependency imported from the installed Zig toolchain. Zine is pinned to the same Zig version, so the sources must be vendored, attributed, and maintained as project code without a separate compiler-API port in the initial import.

## Success criteria

The migration is complete when:

- Existing `.smd` files produce equivalent AST semantics and unchanged HTML snapshots.
- Existing SuperMD directives, content sections, IDs, footnotes, links, assets, code includes, math, and media behave as before.
- Parse and semantic diagnostics retain accurate source locations.
- All existing content-scanning, rendering, draft, and multilingual tests pass.
- The new parser is safe to instantiate independently in concurrent worker jobs.
- The parser and AST have explicit, tested allocator ownership and no leaks under `std.testing.allocator`.
- Zine no longer imports or links cmark-gfm.
- The `supermd` package dependency is either removed or replaced by a pure-Zig package that contains no cmark dependency.
- Cross-target release builds do not compile or link cmark C sources.

## Non-goals for the initial migration

- Reproducing every undocumented cmark implementation quirk.
- Exposing the internal AST as a stable third-party API before Zine compatibility is established.
- Reusing Zig's installed `docs/wasm/markdown` files at build time.
- Replacing Scripty, SuperHTML, syntax highlighting, page resolution, or asset resolution.
- Redesigning the `.smd` authoring language during parser migration.

## Current pipeline and coupling

The current pipeline is:

```text
.smd source
  -> Ziggy frontmatter parser
  -> supermd.Ast.init()
  -> cmark-gfm AST
  -> SuperMD directive analysis and AST mutation
  -> Zine page/asset/link analysis
  -> Zine HTML renderer
  -> SuperHTML layout
```

The cmark boundary is wider than `Ast.init()`:

- `supermd.Node` wraps a `*cmark_node`.
- Node types use cmark enum values.
- Parent, child, and sibling navigation calls cmark.
- Source ranges come from cmark nodes.
- Directives are attached through cmark user data.
- Footnote metadata comes from cmark.
- Table metadata comes from cmark-gfm extension APIs.
- `Ast.Iter` wraps `cmark_iter` and supports enter/exit traversal and reset.
- Worker threads own reusable cmark parser instances.

The migration therefore needs a compatible AST producer and node facade, not merely a call to Zig's default Markdown HTML renderer.

## Target architecture

```text
Vendored Markdown parser
  block parser + inline parser + source tracking
                    |
                    v
Owned Markdown document store
  nodes + strings + relations + ranges
                    |
                    v
SuperMD semantic pass
  directives + IDs + references + footnotes + validation
                    |
                    v
Zine analysis
  pages + assets + locales + languages
                    |
                    v
Existing custom HTML renderer
```

### Stable node handles

Zine stores nodes in ID maps, error records, footnote records, and content-section values. Handles must remain valid if the outer `Ast` value moves.

Use an arena-owned, stable store and index-based handles:

```zig
pub const Node = struct {
    store: *Store,
    index: Index,
};

pub const Ast = struct {
    store: *Store,
    ids: std.StringArrayHashMapUnmanaged(Node),
    footnotes: std.StringArrayHashMapUnmanaged(Footnote),
    errors: []const Error,
    arena: std.heap.ArenaAllocator.State,
};
```

Do not let `Node` point at an `Ast` value stored by value in `Page`; that pointer would be invalidated if the page or AST moves.

### Document storage

Retain the useful compact representation from Zig's docs parser:

- `MultiArrayList` for node tags and node-specific data.
- Packed child index lists.
- Interned/null-terminated string storage.

Add parallel metadata indexed by node index:

```zig
const Store = struct {
    document: Document,
    relations: []Relation,
    ranges: []Range,
    directives: []?*Directive,
};

const Relation = struct {
    parent: ?Index,
    first_child: ?Index,
    previous_sibling: ?Index,
    next_sibling: ?Index,
};
```

The relation table can be built in one linear pass after parsing. It preserves the navigation operations currently used by SuperMD and Zine without bloating every parser node.

### Source locations

Source tracking must be designed into the parser before adding more syntax. Retrofitting ranges after strings have been normalized or copied will produce inaccurate diagnostics.

Track:

- Absolute byte offsets into the Markdown portion of the `.smd` source.
- Start and end line/column positions, either stored directly or derived from a line-start table.
- Opening and closing spans for containers when needed.
- Exact link destination spans for Scripty diagnostics.
- Exact fenced-code content and info-string spans.

Prefer byte offsets as the canonical representation and derive line/column through a line index. Preserve Zine's existing `Range` interface at the node facade.

### Directives as sidecar data

Do not add every SuperMD directive kind to the Markdown syntax node union. Markdown should parse links, images, headings, paragraphs, blockquotes, and code blocks. The semantic pass should recognize special link destinations and attach `Directive` values in the sidecar array.

This preserves separation between Markdown syntax and SuperMD semantics while retaining `Node.getDirective()` and `Node.setDirective()` behavior.

### Traversal

Implement a pure-Zig enter/exit iterator using the relation table. It must support:

- Starting at the document root or an arbitrary node.
- `.enter` and `.exit` events.
- Resetting to an arbitrary node/direction.
- Skipping a subtree.
- Traversing detached footnote definitions on demand.

With parent and sibling relations, traversal can be allocation-free and O(1) per event.

## Required Markdown and GFM feature scope

### Already present in the selected Zig 0.17 source

- ATX headings
- Paragraphs
- Ordered and unordered lists
- Nested and loose/tight lists
- Blockquotes
- Thematic breaks
- Backtick fenced code blocks and info strings
- Links and images
- Autolinks, including plain HTTP(S) links
- Emphasis and strong emphasis
- Inline code
- Hard line breaks
- HTML escaping
- A compact AST and customizable recursive renderer
- Tables, with syntax restrictions that differ from GFM

### Must be added or made compatible

- Soft-break representation compatible with Zine's rendering behavior.
- Strikethrough nodes.
- Task-list parsing and metadata.
- Footnote definitions, references, numbering, and repeated-reference IDs.
- Full GFM table recognition, including optional leading/trailing pipes.
- Tilde fenced code blocks.
- Setext headings if required for CommonMark compatibility.
- Reference and shortcut links if required for CommonMark compatibility.
- Link titles or an explicit diagnostic matching SuperMD's current behavior.
- Smart punctuation behavior currently enabled through `CMARK_OPT_SMART`.
- Raw HTML recognition so SuperMD can reject it with a diagnostic instead of silently escaping it.
- Null-byte and invalid UTF-8 handling compatible with the chosen source policy.
- Correct parsing of angle-bracket link destinations used by SuperMD directives.

The first compatibility target is the existing Zine and SuperMD corpus. Broader CommonMark/GFM conformance follows once Zine behavior is preserved.

## SuperMD semantic behavior to preserve

The pure-Zig AST producer must support the existing semantic pass for:

- `$section`, `$block`, `$heading`, `$text`, and `$mathtex`.
- `$link`, including page, sibling, subpage, alternative, fragment, and unsafe fragment behavior.
- `$image`, `$video`, and `$audio`.
- `$code`, including site, page, and build assets and line selection.
- Directive IDs, attributes, titles, and custom data.
- Duplicate ID detection.
- Invalid reference detection.
- Directive placement validation for headings, paragraphs, and blockquotes.
- Section boundaries and rendering a single content section.
- Collapsible block behavior.
- Footnote extraction and separate template rendering.

The Zig parser preserves `$...` link targets, but angle-bracket destinations currently include their surrounding `<` and `>` in the stored target. Normalize these delimiters before invoking Scripty, while retaining the original span for diagnostics.

## Implementation phases

### Phase 0: Capture the compatibility baseline

Status: implemented on `2026-08-15`. Provenance is recorded in
`src/markdown/UPSTREAM.md`; the reproducible compatibility runner, focused
fixtures, and generated baseline live in `tests/markdown-oracle/`. The
unmodified source import required by step 3 remains the first Phase 1 change
and must be kept separate from adaptation work.

1. Record the exact provenance of the four Zig `0.17.0-dev.1756+613c03321` source files:
   - Zig version.
   - Upstream repository commit when available.
   - Original paths.
   - License and copyright notice.
   - SHA-256 hashes of the copied originals.
2. Add an `UPSTREAM.md` beside the vendored code.
3. Preserve an unmodified copy or a clearly reviewable import commit before adapting it.
4. Add a fixture runner that captures current cmark/SuperMD behavior for:
   - Node/event structure.
   - Node source ranges.
   - Directive metadata.
   - IDs and footnotes.
   - Rendered HTML.
   - Diagnostics.
5. Include every current `.smd` fixture and focused cases for supported GFM constructs.

Deliverable: a reproducible oracle corpus against which the pure-Zig implementation can be compared.

### Phase 1: Vendor the Zig parser

1. Copy the four source files into a dedicated module, tentatively:

   ```text
   src/markdown.zig
   src/markdown/Parser.zig
   src/markdown/Document.zig
   src/markdown/renderer.zig
   src/markdown/UPSTREAM.md
   ```

2. Preserve the upstream tests and make them runnable through `zig build test`.
3. Confirm the imported files compile without compatibility edits under the pinned Zig version.
4. Keep any necessary import adjustments separate from functional parser changes.
5. Expose the module through `build.zig` without reading from the installed Zig library directory.

Deliverable: the original parser tests pass from vendored source on Zine's pinned compiler version.

### Phase 2: Define the Zine AST contract

1. Introduce the stable `Store`, `Ast`, `Node`, `Index`, `Range`, and `Iter` types.
2. Add relation and source-range sidecars.
3. Implement the subset of the current node facade used by Zine:
   - Type/tag lookup.
   - Literal, link target, code info, heading level, and list metadata.
   - Parent, child, and sibling navigation.
   - Enter/exit traversal and reset.
   - Plain-text inline rendering.
   - Directive get/set.
   - Table header and alignment access.
4. Audit structural mutation operations such as `unlink`, `prependChild`, and `replaceWithChild`.
5. Prefer representing semantic transformations in sidecars and renderer rules. Implement tree mutation only where the existing behavior cannot be expressed otherwise.
6. Add ownership and move-safety tests for node handles stored outside the immediate traversal.

Deliverable: Zine-facing code can be compiled against the new node facade in isolated tests.

### Phase 3: Add source tracking

1. Change `feedLine` to know the line's absolute starting offset.
2. Carry source positions through pending block records and inline tokens.
3. Emit a range for every node.
4. Build a line-start index for offset-to-line/column conversion.
5. Add focused tests for multibyte UTF-8, CRLF input, nested blocks, escaped punctuation, multiline links, and fenced code.
6. Compare diagnostic selections against the existing SuperMD corpus.

Deliverable: every node used in a diagnostic has an accurate range.

### Phase 4: Reach required CommonMark/GFM syntax coverage

Implement missing features one at a time, each with parser, AST, renderer, and differential tests:

1. Soft breaks and raw HTML recognition.
2. Strikethrough.
3. GFM-compatible tables.
4. Task lists.
5. Footnotes.
6. Tilde fences.
7. Reference links and Setext headings if included in the compatibility contract.
8. Smart punctuation or a documented compatible replacement.

Do not combine all extensions into one patch. Each syntax feature should have isolated tests and a clear node representation.

Deliverable: the agreed Zine/CommonMark/GFM feature matrix is green.

### Phase 5: Port the SuperMD semantic pass

1. Run semantic analysis over the pure-Zig document.
2. Recognize directive-bearing link/image destinations.
3. Normalize angle-bracket destinations without losing source spans.
4. Evaluate directive expressions with the existing Scripty context.
5. Attach directives to nodes through the sidecar.
6. Build ID, referenced-ID, section, and footnote maps.
7. Preserve validation errors and their source ranges.
8. Preserve special transformations for section headings, collapsible block headings, captions, and inline math.
9. Add semantic snapshots showing directives and errors independent of HTML rendering.

Deliverable: pure-Zig `Ast.init()` produces the semantic data currently consumed by Zine.

### Phase 6: Integrate behind a temporary parser switch

1. Add a temporary build/test option selecting `cmark` or `zig` parsing.
2. Keep both implementations available only during migration.
3. Run the complete content corpus through both parsers.
4. Compare:
   - Rendered output.
   - IDs and sections.
   - Footnote numbering and links.
   - Page-analysis errors.
   - Parse error locations.
5. Classify every difference as:
   - A new-parser bug.
   - An intentional compatibility change.
   - An existing cmark-dependent quirk that should be preserved temporarily.
6. Require an explicit fixture and rationale for every accepted difference.

Deliverable: the Zig parser is the default in tests with no unexplained differences.

### Phase 7: Remove cmark coupling from Zine

1. Change `Page.parse()` so each job creates or uses the pure-Zig parser without a cmark parser argument.
2. Remove thread-local cmark parser initialization and cleanup from `worker.zig`.
3. Update imports in:
   - `src/root.zig`
   - `src/worker.zig`
   - `src/context/Page.zig`
   - `src/render/html.zig`
   - `src/wuffs.zig`
4. Replace the external `supermd` dependency or update it to the pure-Zig implementation.
5. Remove cmark registration and extension initialization.
6. Remove cmark libraries and C compilation from native and release build paths.
7. Remove the temporary parser switch after one implementation is authoritative.

Deliverable: no cmark types, symbols, headers, libraries, or build steps remain.

### Phase 8: Performance and release validation

1. Benchmark parsing, semantic analysis, rendering, peak memory, and allocations on representative sites.
2. Check that parallel builds do not share mutable parser state.
3. Run debug and optimized builds.
4. Run the full test suite and rendering snapshots.
5. Exercise development serving and disk release modes.
6. Exercise supported cross-compilation release targets.
7. Fuzz or property-test inline parsing, nested delimiters, malformed links, tables, and footnotes.
8. Document the supported Markdown/SuperMD syntax and intentional deviations.

Deliverable: the pure-Zig parser is production-ready and the migration documentation is complete.

## Test strategy

### Unit tests

- One parser test per block and inline construct.
- Range tests for every construct.
- Relation-table and iterator event tests.
- Ownership, deinitialization, and out-of-memory cleanup tests.
- Plain-text rendering tests.
- Directive normalization and Scripty evaluation tests.
- Duplicate-ID and invalid-reference tests.

### Differential tests

During migration, use cmark/SuperMD as the oracle for the compatibility corpus. Serialize both ASTs into a parser-independent form containing:

```text
tag
range
literal or destination
block metadata
directive metadata
ordered children
```

Compare that representation rather than internal pointers or storage layouts.

### Integration tests

- Existing content-scanning snapshots.
- Existing page-analysis diagnostics.
- Existing rendering snapshots.
- Draft handling.
- Multilingual page and asset URLs.
- Alternative output layouts.
- Development server in-memory rendering.
- Release output to disk.

### Conformance tests

After Zine compatibility is green, add pinned CommonMark and GFM spec fixtures for the declared supported feature set. Keep Zine-specific directive tests separate so failures clearly identify syntax parsing versus semantic analysis.

## Build and dependency strategy

The initial import belongs in Zine for rapid integration, but the module boundary should permit extraction into a standalone pure-Zig SuperMD package once stable.

During migration:

- Keep the vendored Markdown module independent of Zine page/build types.
- Keep SuperMD semantics in a layer above the Markdown document.
- Allow the semantic layer to depend on Scripty and Ziggy as it does today.
- Do not let the low-level Markdown parser depend on SuperHTML, Zine context, assets, or site configuration.
- Keep cmark only in the temporary oracle path.

At completion, choose between:

1. Publishing the parser and SuperMD semantic layer as an updated standalone `supermd` dependency; or
2. Keeping both as local Zine modules if their API is too application-specific.

The standalone package is preferred if the boundary remains clean.

## Risks and mitigations

### Incomplete CommonMark/GFM behavior

The Zig docs parser was designed for Zig documentation rather than full CommonMark conformance.

Mitigation: define the feature matrix, use differential fixtures, and add extensions incrementally.

### Incorrect source ranges

The source parser currently normalizes and copies content without retaining full provenance.

Mitigation: add canonical byte offsets before semantic features or parser refactors.

### Invalid node handles after moves

Index-only nodes need access to their owning storage, while pointers to an outer value can become stale.

Mitigation: allocate a stable store and test moving/copying the outer `Ast` handle.

### Directive parsing differences

Angle-bracket destinations, nested parentheses, quoting, and malformed expressions may be tokenized differently from cmark.

Mitigation: build a directive-specific corpus from current content and error fixtures before porting semantics.

### Footnote ordering differences

Footnote definitions and repeated references affect generated IDs and template-visible ordering.

Mitigation: snapshot the footnote map and rendered reference/definition IDs.

### Performance regressions

Parent/sibling metadata and source ranges increase memory, and building sidecars adds passes.

Mitigation: use compact indices, parallel arrays, linear finalization passes, and benchmarks before removing cmark.

### Toolchain-source drift

The source originates from an internal docs module in the exact Zig development build to which Zine is pinned.

Mitigation: vendor with provenance, own the API, and never import it from the user's toolchain path.

## Suggested commit sequence

1. `build: pin Zig 0.17.0-dev.1756`
2. `markdown: vendor Zig docs parser sources`
3. `markdown: add source ranges and stable node handles`
4. `markdown: add relations and enter-exit iterator`
5. `markdown: add required GFM syntax extensions`
6. `supermd: port directives and semantic indexes to Zig AST`
7. `tests: add cmark versus Zig differential corpus`
8. `zine: integrate pure-Zig AST behind parser switch`
9. `zine: make pure-Zig parser authoritative`
10. `build: remove cmark-gfm and temporary compatibility path`

Each commit should compile and should keep the smallest relevant test gate green.

## First implementation milestone

The first milestone should stop before adding SuperMD semantics. It should contain:

- A provenance-preserving vendored import.
- A successful Zig 0.17 port.
- Upstream parser tests in Zine's build.
- Source ranges for headings, paragraphs, links, code blocks, and text.
- Stable node handles and relation tables.
- A pure-Zig enter/exit iterator.
- A parser-independent AST dump format.
- Differential fixtures for basic Markdown nodes.

This establishes the hardest architectural invariants—ownership, identity, traversal, and source mapping—before directive and GFM feature work begins.
