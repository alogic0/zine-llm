# Accepted Markdown backend differences

There are currently no accepted output or semantic differences. Both backends
must reproduce the same committed corpus snapshots exactly.

## Resolved during Phase 6

| Observed discrepancy | Classification | Resolution and fixture |
| --- | --- | --- |
| Pure Zig rejected inline HTML such as `<ctx>`, while current SuperMD only rejects block HTML. | Existing cmark-dependent quirk to preserve temporarily. | The semantic pass now preserves the current policy. Covered by `Semantic.test.cmark compatibility permits inline HTML but rejects HTML blocks` and `tests/rendering/simple/content/context.smd`. |
| A destination followed by a quoted link title was passed to Scripty as one expression. | New-parser bug. | Semantic preprocessing now separates the destination and title before evaluation. Covered by `Semantic.test.link titles are separated before Scripty evaluation` and `tests/content-scanning/page-analysis/content/parse.smd`. |
| Pure-Zig diagnostics selected one fewer byte for fenced HTML and initially emitted generic messages without cmark notes. | New-parser/integration bug. | Absolute HTML spans and the compatibility error formatter now reproduce cmark selections, messages, and notes. Covered by `tests/content-scanning/page-analysis/content/code.smd`, `heading.smd`, `ids.smd`, and `parse.smd`. |

No discrepancy was classified as an intentional compatibility change. No
unresolved difference is accepted by the parity gate.
