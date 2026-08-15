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
