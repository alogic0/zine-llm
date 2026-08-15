# Archived Markdown compatibility oracle

This corpus records the behavior of Zine's current cmark-gfm and SuperMD
pipeline before it was replaced by the pure-Zig Markdown implementation.

The retired runner included every `tests/**/*.smd` file after removing its
Ziggy frontmatter. Focused CommonMark, GFM, SuperMD, and diagnostic inputs live
in `fixtures/`. For each input, `snapshot.txt` records the event stream, source
ranges, directive metadata, IDs, footnotes, diagnostics, and cmark HTML.

Phase 7 removed the cmark-backed runner and its build steps. This directory is
kept as a historical compatibility record; `./build.sh test` now validates the
authoritative pure-Zig parser directly and does not regenerate this snapshot.
