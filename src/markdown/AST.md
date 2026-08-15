# Markdown AST contract

`Ast.zig` is the stable handle layer between the compact parser `Document` and
Zine/SuperMD semantics. It does not replace the parser document or copy its
strings. Instead, it owns the document and adds indexed sidecars for relations,
source ranges, directives, and metadata.

Instantiate the contract with the caller's directive type:

```zig
const Markdown = markdown.Ast.Contract(Directive);
```

This keeps the Markdown package independent of SuperMD while preserving typed
`Node.getDirective()` and `Node.setDirective()` access for the semantic pass.

## Ownership

`Markdown.Ast.init` takes ownership of a `Document` on success. The document
must have been allocated with the allocator passed to `init`. The AST owns a
stable arena object; `Node` handles contain a `*Store` and an index, so moving
the outer `Ast` value does not invalidate them. Handles remain valid until
`Ast.deinit`.

Plain-text rendering and copied directive sidecars should use
`Ast.allocator()`. Their memory is then released with the AST. Source strings
returned by node accessors borrow from the owned parser document.

## Structural mutation audit

The compact parser document remains immutable after construction. Structural
changes affect only the relation sidecar used by traversal and rendering:

- `unlink` is required today to remove the code child consumed by `$mathtex`.
- `prependChild` is currently unused; it exists for facade compatibility and
  rejects foreign stores, invalid parents, and cycles.
- `replaceWithChild` is currently unused; it requires exactly one child and
  leaves the replaced node detached but valid.

Semantic transformations should prefer directive and metadata sidecars. New
tree mutation should be added only when rendering rules cannot express the
same result.

## Source ranges

Every parser node has a canonical half-open byte span in the original Markdown
source. `Document` also owns a line-start index, and `Ast.init` uses it to fill
the range sidecar for every node. `start_byte` is inclusive and `end_byte` is
exclusive, which makes ranges directly usable for slicing and diagnostics.

Rows and columns are one-based and the displayed end position is inclusive,
matching the cmark/SuperMD source-position convention. Columns count source
bytes rather than Unicode scalar values. This intentionally preserves the
behavior of cmark and makes UTF-8 and invalid source bytes unambiguous.

`Parser.feedLine` accepts the absolute line start and the original line-ending
width. `Parser.feed` is the preferred whole-buffer entry point because it
recognizes LF and CRLF without normalizing away their byte widths. Multiline
inline buffers retain a parallel per-byte source map, so links, escapes, and
hard breaks continue to select the original bytes after parsing.
