# Supported Markdown and SuperMD syntax

Zine uses the independently packaged pure-Zig `zig-markdown-parser` for
Markdown syntax and a separate in-tree semantic pass for SuperMD directives.
The compatibility target is Zine's documented syntax and test corpus; this is
not a claim of complete CommonMark or GFM conformance.

## Block syntax

| Syntax | Supported behavior |
| --- | --- |
| Paragraphs | Blank-line separation, multiline content, and lazy continuation inside lists and block quotes. |
| ATX headings | Levels 1 through 6 using `#` markers followed by a space. |
| Setext headings | One-line level-1 (`=`) and level-2 (`-`) headings. |
| Block quotes | Nested `>` containers and lazy paragraph continuation. |
| Lists | Unordered `-`, `*`, and `+` markers; ordered `.` and `)` markers; nesting; tight/loose rendering; arbitrary ordered-list start values. |
| Task lists | `[ ]`, `[x]`, and `[X]` at the beginning of list items. |
| Fenced code | Backtick and tilde fences, info strings, indentation removal, and closing fences at least as long as the opener. |
| Thematic breaks | Matching `-`, `_`, or `*` markers with optional spaces. |
| Tables | A delimiter row is required; outer pipes are optional; escaped pipes, pipes in code spans, header rows, uneven rows, and left/center/right alignment are supported. |
| Footnotes | Labeled references and definitions, indented continuation blocks, repeated-reference numbering, IDs, and backlinks. |
| Raw HTML blocks | Parsed for source fidelity, then rejected by SuperMD policy. Use a fenced `` ```=html `` block for validated embedded HTML. |

## Inline syntax

| Syntax | Supported behavior |
| --- | --- |
| Text and escapes | UTF-8 input, replacement of invalid bytes, and backslash escapes for punctuation. |
| Emphasis | `*`/`_` emphasis and `**`/`__` strong emphasis, including nesting. |
| Strikethrough | Paired `~~` delimiters with nested inline content. |
| Code spans | Matching backtick runs; Markdown is not interpreted inside. |
| Links and images | Inline destinations, balanced/escaped parentheses, optional titles, and image alt text. |
| Reference links | Full, collapsed, shortcut, image, and forward references. |
| Autolinks | Angle-bracket URI autolinks and plain `http://`/`https://` links with trailing-punctuation handling. |
| Breaks | Soft line breaks and hard breaks introduced by a trailing backslash. |
| Smart punctuation | Contextual quotes/apostrophes, en/em dashes, and ellipses outside code, raw HTML, escapes, and destinations. |
| Inline HTML | Preserved and rendered. SuperMD intentionally rejects block HTML only. |

## SuperMD semantics

Link or image destinations beginning with `$` are evaluated through Scripty.
The semantic pass supports:

- `$section`, `$block`, `$heading`, `$text`, and `$mathtex`;
- `$link` page, sibling, subpage, alternative, fragment, mail, and URL forms;
- `$image`, `$video`, and `$audio` asset directives;
- `$code` site, page, and build assets with line selection;
- directive IDs, attributes, titles, and custom data;
- section indexing and partial-section rendering;
- duplicate-ID, invalid-reference, placement, and heading-order diagnostics;
- footnote IDs, reference indexes, and template-visible metadata.

## Intentional deviations and policy

- Zine targets its declared subset, not every CommonMark/GFM example.
- Indented code blocks are not supported; use fenced code blocks.
- Tabs count as one indentation byte rather than expanding to tab stops, and a
  tab does not satisfy syntax requiring a literal space after a marker.
- ATX headings require a space after the marker run.
- SuperMD documents begin at heading level 1 and report skipped levels.
- A heading used as a content section must have a directive ID.
- Raw HTML blocks are forbidden even though the syntax parser retains them.
  Validated `=html` fences are the supported block-HTML escape hatch.
- Source columns count bytes, not Unicode scalar values, matching the stored
  byte ranges and making invalid UTF-8 positions unambiguous.

The authoritative behavioral coverage is in the parser unit tests,
`tests/markdown-semantic/`, content-scanning snapshots, and rendering
snapshots. Robustness and production gates are documented in
`docs/markdown-validation.md`.
