# Markdown compatibility oracle

This corpus records the behavior of Zine's current cmark-gfm and SuperMD
pipeline before it is replaced by the pure-Zig Markdown implementation.

The runner automatically includes every `tests/**/*.smd` file after removing
its Ziggy frontmatter. Focused CommonMark, GFM, SuperMD, and diagnostic inputs
live in `fixtures/`. For each input, the snapshot records the event stream,
source ranges, directive metadata, IDs, footnotes, diagnostics, and cmark HTML.

Print the oracle without changing the baseline:

```sh
./build.sh markdown-oracle
```

Regenerate the checked-in baseline after intentionally changing a fixture or
the current parser behavior:

```sh
./build.sh update-markdown-oracle
```

`./build.sh test` regenerates the oracle and includes it in the repository's
existing snapshot diff check. Review changes to `snapshot.txt`; they define the
compatibility contract for the replacement parser.
