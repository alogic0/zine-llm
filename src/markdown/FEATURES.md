# Markdown syntax compatibility

The pure-Zig parser implements the CommonMark/GFM syntax required by Zine's
migration corpus. This matrix records the Phase 4 boundary; Zine-specific
directives and semantic indexes remain Phase 5 work.

| Syntax | Phase 4 behavior |
| --- | --- |
| Soft and hard breaks | Separate ranged nodes; CRLF widths are preserved. |
| Raw HTML | Standard block-tag families and inline tags/comments are retained as raw nodes so the semantic pass can reject them. |
| Strikethrough | Paired `~~` delimiters with nested inline children. |
| Tables | A delimiter row is required; outer pipes are optional; escaped pipes, code spans, header cells, and alignment are supported. |
| Task lists | `[ ]`, `[x]`, and `[X]` at the start of a list item, with checked state on the item. |
| Footnotes | Labeled references and definitions with indented continuation blocks. Semantic IDs, repeated-reference indexes, and backlinks remain Phase 5 responsibilities. |
| Fenced code | Backtick and tilde fences, info strings, and closing fences at least as long as the opener. |
| Reference links | Full, collapsed, shortcut, image, and forward references. Destinations are retained; title semantics remain in the AST sidecar for Phase 5. |
| Setext headings | One-line level-one and level-two headings with underline-inclusive ranges. |
| Smart punctuation | Contextual single/double quotes, apostrophes, en/em dashes, and ellipses in normal text. Code, raw HTML, escaped punctuation, and link destinations are unchanged. |

The parser intentionally exposes syntax rather than Zine policy. For example,
raw HTML is retained by the baseline renderer, while the Phase 5 SuperMD pass
will turn it into the same validation diagnostic produced by the current
cmark-based implementation.
