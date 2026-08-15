# Markdown backend parity gate

Run the complete migration comparison with:

```console
./build.sh test-parser-parity
```

The gate runs the repository's full test graph twice, first with cmark/SuperMD
and then with the pure-Zig parser and semantic pass. Both runs must reproduce
the same committed snapshots. Running sequentially is intentional because the
two backends write to the same snapshot locations.

The normal `./build.sh test` gate uses the pure-Zig backend. Use
`-Dmarkdown-parser=cmark` only for temporary migration comparison.

The corpus includes every `tests/**/*.smd` content file plus the focused
Markdown and semantic fixtures. Together the gates compare:

- rendered pages, content sections, tables, task lists, and code blocks;
- directive-generated IDs and section selection;
- footnote numbering, reference IDs, backlinks, and separate rendering;
- page-analysis and parse errors, including paths, lines, columns, and source
  selections;
- renderer-independent directive, ID, reference, section, footnote, and error
  state in `tests/markdown-semantic/semantic.snapshot`.

An output difference is never accepted by updating an existing shared snapshot
alone. It must have a focused fixture and an entry in `DIFFERENCES.md` that
classifies it as a pure-parser bug, an intentional compatibility change, or a
cmark-dependent quirk preserved during migration.
