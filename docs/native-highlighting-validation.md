# Native Highlighting Integration Validation

This document records the first Zine integration spike for
`zig-native-syntax`. The local path dependency and measurements are
experimental; they are not release policy or portable performance thresholds.

## Integration contract

Zine routes these exact canonical language names through native backends:

- `zig`;
- `ziggy`;
- `ziggy-schema`;
- `scripty`;
- `html`;
- `xml`;
- `css`;
- `superhtml`;
- `markdown`.

Zine also maps the consumer-owned aliases `md`, `smd`, and `supermd` to the
canonical Markdown backend. `zig-native-syntax` exposes only `markdown`.

Every other language continues through the existing `flow-syntax` and
Tree-sitter path. In particular, the rendering fixture retains Rust as
fallback evidence. Alias policy remains Zine-owned; the native package exposes
only canonical backends.

The focused and host-architecture gates are:

```sh
./build.sh test-native-highlighting
./build.sh test
./build.sh test-workflows
```

The rendering snapshot covers fenced blocks for all nine native languages,
including Markdown structural scopes and escaped raw HTML, HTML-sensitive
source bytes, a `$code.siteAsset(...).language('zig')` directive, and
`String.syntaxHighlight('zig')`. A build test also requires the starter
stylesheet to mention every stable native scope class.

## First-spike comparison

The comparison was recorded on 2026-08-20 with the pinned Zig compiler on the
local `x86_64-linux` architecture. The Tree-sitter-only baseline was commit
`78ba553`; the native-first candidate was commit `9ee28e6` with
`zig-native-syntax` at `16ab758`.

Both host executables were built sequentially with separate empty local caches,
the existing shared global dependency cache, ReleaseFast optimization, and
separate install prefixes:

```sh
/usr/bin/time -f 'elapsed_seconds=%e\nmaximum_rss_kib=%M' \
  ./build.sh -Doptimize=fast --cache-dir <empty-cache> --prefix <empty-prefix>
```

| Measurement | Tree-sitter-only | Native-first plus fallback | Change |
| --- | ---: | ---: | ---: |
| Fresh build elapsed time | 95.65 s | 93.04 s | -2.61 s (-2.7%) |
| Fresh build maximum RSS | 1,209,484 KiB | 1,288,632 KiB | +79,148 KiB (+6.5%) |
| Warm build elapsed time | 0.69 s | 0.71 s | +0.02 s |
| Warm build maximum RSS | 38,832 KiB | 38,776 KiB | -56 KiB |
| Installed executable | 156,452,784 B | 157,963,872 B | +1,511,088 B (+0.97%) |
| Loaded ELF sections | 137,639,775 B | 137,856,863 B | +217,088 B (+0.16%) |

One fresh run is suitable for detecting an order-of-magnitude regression, not
for claiming a speedup. File size includes Zig debug information even in this
ReleaseFast host build; the loaded-section comparison indicates that most file
growth is non-loaded metadata.

The same pre-integration rendering fixture was then built once by each
executable. Both completed below the timer's 0.01-second resolution. Maximum
RSS was 12,700 KiB for the baseline and 11,020 KiB for the candidate. This is a
process-level peak-memory observation, not an allocator-count comparison:
Tree-sitter allocates behind a C boundary, and Zine does not currently expose a
common allocation tracker for both paths.

Representative output differs only where intended. Zig uses stable
`syntax-*` classes from the native package, while the Rust section remains
byte-for-byte identical through Tree-sitter. The expanded candidate fixture
exposes hostile source bytes through every Zine entry point, while the package
conformance suite verifies recovery after stripping spans and decoding
entities.

## API findings

The public `Backend`, caller-owned `CaptureSink`, and separate HTML renderer fit
Zine's existing arena and writer lifetimes without an API revision. The spike
did expose these integration constraints:

- HTML, XML, and SuperHTML must share one private markup module in a consumer
  graph. The package build now owns that shared module instead of letting each
  backend import the same implementation under a different module owner.
- Zine must configure and import each selected optional backend explicitly.
  This is consistent with keeping unused parser packages out of core-only
  consumers.
- Markdown highlighting consumes the independent `zig-markdown-parser`
  package through its public read-only traversal API. Zine retains SuperMD
  semantics and aliases, so no dependency path leads back from the highlighter
  into Zine.
- Raw HTML is initially classified as embedded Markdown content, and fenced
  code is classified as one Markdown code region. Nested HTML and language
  composition remain deferred consumer-configuration work.
- Zine's existing `highlight` build option currently enables the combined
  native-plus-Tree-sitter graph. Separating native selection from fallback
  removal belongs to the later backend-selection migration, not this spike.
- End-to-end allocation counts are not directly comparable until both the Zig
  allocator path and Tree-sitter's C allocator are observed by one harness.
  Process maximum RSS is used only as a first-spike proxy.

No Phase 1 ownership or lifetime boundary needs revision before adding more
languages.
