# Native Highlighting Integration Validation

This document records the first Zine integration spike for
`zig-native-syntax`. The local path dependency and measurements are
experimental; they are not release policy or portable performance thresholds.

## Integration contract

Zine routes these exact canonical language names through native backends:

- `asm`;
- `astro`;
- `bash`;
- `c`;
- `cmake`;
- `c-sharp`;
- `cpp`;
- `diff`;
- `dockerfile`;
- `go`;
- `hcl`;
- `json`;
- `javascript`;
- `java`;
- `jsdoc`;
- `kotlin`;
- `lua`;
- `make`;
- `nasm`;
- `objc`;
- `php`;
- `powershell`;
- `proto`;
- `regex`;
- `ruby`;
- `rust`;
- `toml`;
- `swift`;
- `typescript`;
- `yaml`;
- `vue`;
- `zig`;
- `ziggy`;
- `ziggy-schema`;
- `scripty`;
- `sql`;
- `html`;
- `xml`;
- `css`;
- `superhtml`;
- `markdown`;
- `python`;
- `kdl`;
- `nix`;
- `fish`;
- `nu`;
- `awk`;
- `ssh-config`;
- `gitcommit`;
- `git-rebase`;
- `po`;
- `rst`;
- `latex`;
- `typst`;
- `org`;
- `dtd`;
- `mail`;
- `hurl`;
- `ninja`;
- `rpmspec`;
- `rpmbash`;
- `gdscript`;
- `perl`;
- `elixir`;
- `fsharp`;
- `ocaml`;
- `haskell`;
- `gleam`;
- `commonlisp`;
- `scheme`;
- `julia`;
- `elm`;
- `purescript`;
- `nim`;
- `d`;
- `v`;
- `odin`;
- `c3`;
- `systemverilog`;
- `llvm`;
- `openscad`;
- `nickel`;
- `hare`;
- `agda`;
- `query`;
- `vim`;
- `uxntal`;
- `comment`.

Zine maps the consumer-owned aliases `sh` and `shell` to `bash`, `patch` to
`diff`, `js` to `javascript`, `ts` to `typescript`, and `md`, `smd`, and
`supermd` to `markdown`; `yml` maps to `yaml`; `cs` and `csharp` map to
`c-sharp`; `c++` maps to `cpp`; `kt` maps to `kotlin`; `rb` maps to `ruby`;
`assembly` maps to `asm`; `objective-c` maps to `objc`; and `protobuf` maps to
`proto`. `nushell` maps to `nu`; `sshconfig` maps to `ssh-config`;
`git-commit` maps to `gitcommit`; `gitrebase` maps to `git-rebase`; `gettext`
maps to `po`; `restructuredtext` maps to `rst`; `tex` maps to `latex`;
`orgmode` maps to `org`; `email` maps to `mail`; `rpm-spec` maps to `rpmspec`;
`rpm-bash` maps to `rpmbash`; `f#` maps to `fsharp`; `lisp` maps to
`commonlisp`; and `purs` maps to `purescript`.
`dlang` maps to `d`; `vlang` maps to `v`; `system-verilog` and `sv` map
to `systemverilog`; `llvm-ir` and `ll` map to `llvm`; `scad` maps to
`openscad`; `tree-sitter-query` and `tsquery` map to `query`; `vimscript`
maps to `vim`; and `comment-tags` maps to `comment`.

Flow file types that intentionally reuse another grammar also reuse the
corresponding native backend: `conf` maps to Fish, `glsl` to C, `nimble` to
TOML, `csproj` and `props` to XML, and `markdown-inline` to Markdown.
`zig-native-syntax` exposes only canonical backend names.

The default `native-first` mode sends every other language through the existing
`flow-syntax` and Tree-sitter path. The focused routing test uses the
deliberately unsupported `shtml` label as fallback evidence; the current
generated-site rendering fixture no longer requires a Tree-sitter language.
Alias policy remains Zine-owned.

Zine exposes four build-time modes:

| `-Dhighlight-mode` | Native backends | Tree-sitter | Unsupported language |
| --- | --- | --- | --- |
| `tree-sitter` | No | Yes | Existing unknown-language diagnostic |
| `native-first` | Yes | Fallback | Existing unknown-language diagnostic |
| `native-only` | Yes | No | Safely escaped plain text |
| `off` | No | No | Safely escaped plain text |

`native-first` remains the default while new language backends are compared
against Tree-sitter. The legacy `-Dhighlight=true` and `-Dhighlight=false`
options select `native-first` and `off`, respectively, unless
`-Dhighlight-mode` is also supplied. Tree-sitter removal is deferred while the
ordered native-language backlog is implemented and compared; it is not the
immediate result of introducing `native-only`.

The focused and host-architecture gates are:

```sh
./build.sh test-native-highlighting
./build.sh test-highlight-modes
./build.sh test
./build.sh test-workflows
```

The host compilation checks for the selection modes are:

```sh
./build.sh check -Dhighlight-mode=tree-sitter
./build.sh check -Dhighlight-mode=native-first
./build.sh check -Dhighlight-mode=native-only
./build.sh check -Dhighlight-mode=off
```

The `native-only` and `off` builds do not import `flow-syntax` or `treez`.
Zine now links libc explicitly because its Linux watcher uses libc independently
of Tree-sitter; this also restores the legacy `-Dhighlight=false` build.

The rendering snapshot covers fenced blocks for all eighty-eight native languages,
including bounded Bash and Rust scanners, Markdown structural scopes and
escaped raw HTML, and HTML-sensitive source bytes. JSON additionally covers
complete, malformed, and incomplete fences, imported source through
`$code.siteAsset(...).language('json')`, and `String.syntaxHighlight('json')`.
Zig retains matching directive and string-helper coverage. A build test also requires the starter
stylesheet to mention every stable native scope class.

The focused JSON comparison test runs the same complete, malformed, and
newline-terminated incomplete inputs through both native highlighting and
Tree-sitter. Complete input retains equivalent semantic coverage under the
stable native taxonomy. For malformed `\\u12`, native highlighting preserves a
bounded property, string, and escape classification while Tree-sitter's
highlight query retains generic string and escape captures but loses the
property-specific capture. For `tru` before the fence's trailing newline,
native recovery emits a boolean prefix while Tree-sitter emits no
`constant.builtin` capture. These are intentional recovery improvements, not
parity failures.

Diff comparison covers complete, malformed, and incomplete unified-patch
lines. The native backend intentionally classifies patch structure only and
leaves changed payload plain, avoiding false claims about the embedded source
language.

TOML comparison covers complete tables and scalars, an unterminated table and
string with a partial escape, and an incomplete boolean. The native backend
recovers assignment classification after the malformed table line.

Dockerfile comparison covers parser directives, build stages, flags, variables,
JSON-form commands, malformed strings, and an incomplete braced variable. It
does not claim to parse the shell command language embedded in instructions.

Python comparison covers decorators, declarations, annotations, prefixed
strings, malformed function syntax, and an unterminated triple string. Native
highlighting remains lexical and does not interpret indentation or f-string
expressions.

SQL comparison covers common query tokens, quoted identifiers, functions,
parameters, an unterminated block comment, and an unterminated dollar-quoted
body. The native scanner remains deliberately dialect-neutral.

C comparison covers preprocessing lines, documentation comments, declarations,
literal escapes, malformed macro/function input, and an unterminated block
comment. The native backend remains independent of the compiler-grade Aro
pipeline.

JavaScript comparison covers classes, private properties, async methods,
templates, malformed function/template input, and an unterminated block
comment through the `js` alias. Regex disambiguation and JSX remain outside the
lexical backend.

TypeScript comparison covers interfaces, type aliases, generic punctuation,
primitive types, malformed interface/template input, and declaration-context
recovery through the `ts` alias. TSX and type-expression parsing remain out of
scope.

YAML comparison covers directives, document markers, mappings, anchors,
aliases, quoted and block scalars, line-bounded malformed strings, and block
scalar dedentation through the `yml` alias. Schema resolution remains outside
the highlighter.

HCL comparison covers blocks, attributes, primitive types and values,
functions, traversals, quoted template introducers, line-bounded malformed
strings, and incomplete heredocs. Expression evaluation and template parsing
remain outside the lexical backend.

Make comparison covers directives, assignments, targets, variables, strings,
and tab-prefixed recipes. Recipe bodies remain embedded text rather than being
interpreted as shell.

CMake comparison covers command calls, control-flow keywords, primitive
values, quoted strings, and line-bounded malformed input. Evaluation and
generator expressions remain outside the scanner.

The roadmap increment from Java through Protocol Buffers compares complete,
malformed, and incomplete input for every backend. Conventional languages use
language-specific keyword and literal policies over shared bounded recovery;
Vue and Astro use component-markup recovery, while JSDoc and regular
expressions have dedicated scanners. Embedded languages, semantic resolution,
macro expansion, and dialect validation remain outside these backends.

The roadmap increment from KDL through Nim compares complete, malformed, and
incomplete input for all thirty-two backends. These are bounded lexical
highlighters with language-specific token policies; RPM Bash intentionally
reuses the native Bash backend, while its Tree-sitter comparison fixture also
contains an RPM macro because Flow's standalone RPM Bash query only captures
RPM constructs. Full parsing, embedded-language injection, type resolution,
and dialect-specific validation remain outside this increment.

The final roadmap increment from D through generic comment tags compares
complete, malformed, and incomplete input for all fourteen backends. D, V,
Odin, C3, SystemVerilog, LLVM IR, OpenSCAD, Nickel, Hare, Agda, Tree-sitter
Query, Vimscript, and Uxntal use bounded language configurations. The comment
backend is a dedicated scanner for text ranges already known to be comments;
it recognizes tag families, optional owners, issue numbers, and URLs without
owning surrounding comment delimiters. Grammar validation, macro expansion,
embedded-language injection, and semantic analysis remain outside this
increment.

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

In that first spike, representative output differed only where intended: Zig
used stable `syntax-*` classes while Rust remained byte-for-byte identical
through Tree-sitter. Phase 11 subsequently converted Rust and added Bash; their
intentional snapshot changes use the same stable scope classes. The expanded
fixture exposes hostile source bytes through every Zine entry point, while the
package conformance suite verifies recovery after stripping spans and decoding
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
- Bash and Rust are bounded lexical scanners rather than validators. Their
  supported token shapes, malformed-input recovery, and plain-text boundaries
  are documented in the package compatibility notes.
- JSON uses a bounded source-offset scanner because `std.json.Scanner` does not
  expose token byte offsets. The standard scanner remains the valid-corpus
  grammar oracle; JSON5-only syntax remains plain text.
- Explicit backend selection separates Tree-sitter-only comparison,
  native-first comparison, native-only validation, and fully disabled
  highlighting. Tree-sitter remains available as a temporary comparison oracle
  while broader native coverage is implemented.
- End-to-end allocation counts are not directly comparable until both the Zig
  allocator path and Tree-sitter's C allocator are observed by one harness.
  Process maximum RSS is used only as a first-spike proxy.

No Phase 1 ownership or lifetime boundary needs revision before adding more
languages.
