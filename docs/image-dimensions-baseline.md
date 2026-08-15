# Wuffs Image-Dimension Baseline

This document records the image-autosizing behavior and build cost before Zine
replaces Wuffs with bounded Zig metadata parsers. Measurements are diagnostic;
they are not portable test thresholds.

## Source baseline

The baseline was recorded on 2026-08-15 at commit `366526e` with:

- Zig `0.17.0-dev.1756+613c03321`;
- `x86_64-linux.7.0...7.0-gnu.2.39`;
- Linux `7.0.0-28-generic`;
- 16 logical processors.

The Wuffs package wrapper declares version
`0.4.0-alpha.9+3837.20240914`. It downloads the upstream release-C archive at
commit `90e4d81a6a8b7b601e8e568da32a105d7f7705e5` with Zig package hash
`N-V-__8AANEmUgA6aZZZKbfNMv6DSs5In7CDFU6nInu_Y6aY`.

The wrapper translates `release/c/wuffs-v0.4.c` to Zig declarations and also
compiles that monolithic file with `-DWUFFS_IMPLEMENTATION`, libc enabled, and
C sanitization disabled. Zine creates and imports that dependency in both
graphs:

- the normal host executable (`build.zig` dependency near line 288 and import
  near line 393);
- each of the eight release executables (`build.zig` dependency near line 832
  and import near line 885).

The release graph therefore repeats target-specific Wuffs translation and C
compilation for:

- `aarch64-freebsd.15.0`;
- `aarch64-linux-musl`;
- `aarch64-macos`;
- `aarch64-windows`;
- `x86_64-freebsd.15.0`;
- `x86_64-linux-musl`;
- `x86_64-macos`;
- `x86_64-windows`.

Removing Wuffs does not remove Zine's root `translate_c` dependency. That
dependency also translates `src/c.h`, including target-specific macOS APIs.

## Behavior baseline

Image probing is attempted only when all of these conditions hold:

- `image_size_attributes` is enabled;
- the directive is an image;
- no explicit image size is present;
- the image resolves to a local page, site, or build asset.

The current implementation opens and stats the file, maps the complete file,
guesses a format, allocates a Wuffs decoder, and decodes its image
configuration. Its dispatch recognizes BMP, GIF, JPEG, Netpbm, NIE, PNG, QOI,
TGA, WBMP, and WebP. The executable oracle confirms the WebP decoder accepts
the simple lossless `VP8L` fixture but rejects the direct lossy `VP8 ` and
extended `VP8X` fixtures. Supporting all three is therefore an intentional
improvement in the replacement rather than legacy compatibility.

Observed source-level failure behavior is deliberately non-fatal:

| Input or failure | Current result |
| --- | --- |
| File cannot be opened or stated | Debug log; image size remains unset |
| Empty file or mapping failure | Debug log; image size remains unset |
| Unknown signature | `CouldNotGuessFileFormat` or `UnsupportedImageFormat`; caught and logged |
| Recognized but truncated input | Wuffs decoder error; caught and logged |
| Recognized but malformed input | Wuffs decoder error; caught and logged |
| Decoder allocation failure | Caught and logged; image size remains unset |
| Successful configuration decode | Decoder width and height are copied to the directive |
| Zero width or height returned | Value is copied, but HTML rendering omits each non-positive attribute |

The next migration slice turns these source observations into an executable
Wuffs oracle for PNG, JPEG, GIF, WebP, and BMP before production behavior is
changed.

## Accepted parser differences

Differential and mutation tests record these intentional differences between
the legacy configuration decoder and the replacement metadata parser:

- PNG dimensions become available after the validated IHDR fields; the Zig
  parser deliberately does not validate the IHDR checksum or require an IDAT
  header because it does not decode pixels.
- GIF dimensions come from the complete logical screen descriptor and do not
  require the first image descriptor.
- The Zig parser supports direct lossy `VP8 ` and extended `VP8X` WebP in
  addition to the simple lossless `VP8L` accepted by the legacy path.
- SVG intrinsic sizing and direct static AVIF primary-item sizing are new.
- AVIF sequences and derived grid primary items are rejected rather than
  guessed; grid support requires validating its item data and references.
- Netpbm, NIE, QOI, TGA, and WBMP are outside the replacement contract.

For the overlapping PNG, GIF, JPEG, BMP, and lossless WebP cases, generated
positive dimensions must agree exactly with Wuffs.

## Build baseline

A clean local-cache host check used the existing global dependency cache:

```sh
./build.sh check --cache-dir <empty>/cache --prefix <empty>/out
```

Results:

- wall time: 66.39 seconds;
- peak RSS: 1,420,424 KiB;
- local cache after the build: 920 MiB;
- Debug `zine` artifact in the isolated cache: 398,716,448 bytes.

A warm normal check completed in 3.83 seconds with 456,292 KiB peak RSS. The
installed Debug executable was 398,638,640 bytes.

The release baseline was refreshed with:

```sh
./build.sh verify-release -Dpreview=true
```

It completed in 81.98 seconds with 1,567,844 KiB peak RSS. Archive sizes were:

| Target | Archive size (bytes) |
| --- | ---: |
| `aarch64-freebsd.15.0` | 10,579,172 |
| `aarch64-linux-musl` | 10,796,764 |
| `aarch64-macos` | 12,901,914 |
| `aarch64-windows` | 12,597,428 |
| `x86_64-freebsd.15.0` | 10,910,260 |
| `x86_64-linux-musl` | 11,083,580 |
| `x86_64-macos` | 12,719,464 |
| `x86_64-windows` | 12,757,761 |

These values include the entire Zine dependency graph and vary with machine,
cache state, compression tools, compiler revision, and archive metadata. The
migration result should compare direction and order of magnitude, not enforce
these numbers as pass/fail limits.

## Pure Zig migration result

The post-migration measurement was recorded on 2026-08-15 after commit
`60db771`, using the same Zig version and host. The source and build graph no
longer contain:

- `src/wuffs.zig` or the temporary Wuffs differential oracle;
- the root `wuffs` package dependency;
- the vendored Wuffs package wrapper and its upstream release-C archive;
- Wuffs declaration translation, monolithic C compilation, libc linkage, or
  target-specific Wuffs modules.

The root `translate_c` package remains because Zine still translates
`src/c.h`; that work is independent of image probing.

An isolated local-cache host check used:

```sh
./build.sh check --cache-dir <empty>/cache --prefix <empty>/out
```

Results:

- wall time: 24.13 seconds, down from 66.39 seconds;
- peak RSS: 1,195,080 KiB, down from 1,420,424 KiB;
- local cache after the build: 865,932 KiB (about 846 MiB), down from about
  920 MiB;
- Debug `zine` artifact: 399,466,298 bytes, 749,850 bytes (0.19%) larger than
  the isolated baseline artifact;
- immediate incremental check: 0.65 seconds and 40,936 KiB peak RSS.

The Debug artifact result shows why executable size is recorded rather than
used as a pass/fail gate: the compact release binaries benefit while Zig debug
code and metadata make the host Debug executable slightly larger.

An eight-target release and archive verification from a separate empty local
cache completed in 304.70 seconds with 1,557,464 KiB peak RSS. That clean time
is not directly comparable to the 81.98-second baseline refresh, which reused
existing target compilation inputs. Repeating the command with the new local
cache warm took 4.15 seconds and 41,444 KiB peak RSS.

| Target | Before (bytes) | After (bytes) | Change (bytes) |
| --- | ---: | ---: | ---: |
| `aarch64-freebsd.15.0` | 10,579,172 | 10,056,796 | -522,376 |
| `aarch64-linux-musl` | 10,796,764 | 10,276,408 | -520,356 |
| `aarch64-macos` | 12,901,914 | 12,726,642 | -175,272 |
| `aarch64-windows` | 12,597,428 | 12,347,767 | -249,661 |
| `x86_64-freebsd.15.0` | 10,910,260 | 10,366,740 | -543,520 |
| `x86_64-linux-musl` | 11,083,580 | 10,536,316 | -547,264 |
| `x86_64-macos` | 12,719,464 | 12,575,205 | -144,259 |
| `x86_64-windows` | 12,757,761 | 12,526,177 | -231,584 |

Every release archive became smaller. The decrease ranges from 144,259 bytes
to 547,264 bytes depending on target and archive format.

The final supported-format contract is PNG, JPEG, GIF, direct `VP8 `, `VP8L`,
and `VP8X` WebP, supported BMP DIB headers, SVG with resolvable intrinsic
dimensions, and direct static AVIF primary items. SVG parsing is bounded and
does not evaluate CSS or entities. AVIF sequences, grids, and unsupported
derived items are rejected rather than guessed.

Netpbm, NIE, QOI, TGA, and WBMP autosizing was intentionally removed. SVG and
static AVIF autosizing was added, as was support for the direct lossy and
extended WebP fixtures the legacy Wuffs configuration path rejected. All
probe failures remain non-fatal and leave dimensions unset.

## Full validation run

After adding permanent optimization-mode coverage at commit `799c53e`, the
following migration gates passed together on 2026-08-15:

```sh
./build.sh test
./build.sh check
./build.sh check-release-targets -Dpreview=true
./build.sh test-release-tool-isolation
./build.sh verify-release -Dpreview=true
```

This validates the complete snapshot suite, the native executable, every
configured release target, archive contents, and the rule that ordinary build
steps do not require release packaging tools.
