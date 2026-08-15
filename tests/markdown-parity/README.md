# Archived Markdown backend parity record

Phase 6 ran the repository's full test graph through cmark/SuperMD and the
pure-Zig parser and semantic pass. Both implementations reproduced the same
committed snapshots before Phase 7 made the pure-Zig parser authoritative.

The migration-only `test-parser-parity` step and `-Dmarkdown-parser` option no
longer exist. The supported gate is now `./build.sh test`.

The corpus includes every `tests/**/*.smd` content file plus the focused
Markdown and semantic fixtures. Together the gates compare:

- rendered pages, content sections, tables, task lists, and code blocks;
- directive-generated IDs and section selection;
- footnote numbering, reference IDs, backlinks, and separate rendering;
- page-analysis and parse errors, including paths, lines, columns, and source
  selections;
- renderer-independent directive, ID, reference, section, footnote, and error
  state in `tests/markdown-semantic/semantic.snapshot`.

`DIFFERENCES.md` preserves the discrepancies found and resolved during the
migration. No output difference was accepted.
