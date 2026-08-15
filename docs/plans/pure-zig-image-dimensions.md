# Pure-Zig Image-Dimension Probe Plan

## Objective

Replace Wuffs with a small, allocation-free Zig implementation that reads only
enough image metadata to determine width and height.

The migration must preserve Zine's current author-facing behavior:

```text
local image asset
  -> resolve page, site, or build asset
  -> inspect image metadata when image_size_attributes is enabled
  -> attach width and height to the image directive
  -> render width and height attributes
```

The replacement's supported-format contract is:

- PNG;
- JPEG;
- GIF;
- WebP (`VP8 `, `VP8L`, and `VP8X`);
- BMP;
- SVG with resolvable intrinsic dimensions;
- static AVIF.

Wuffs currently recognizes BMP, GIF, JPEG, Netpbm, NIE, PNG, QOI, TGA, WBMP,
and WebP. Dropping Netpbm, NIE, QOI, TGA, and WBMP is an intentional scope
change: they are not documented Zine formats and are not representative web
publishing formats. Adding SVG and static AVIF is an intentional expansion
beyond Wuffs. Record both changes in migration documentation rather than
presenting the new parser as exact decoder-for-decoder compatibility.

## Current state

- `src/wuffs.zig` memory-maps an entire local image, asks Wuffs to identify the
  format, initializes a format decoder, decodes the image configuration, and
  copies its dimensions into `directive.kind.image.size`.
- `src/worker.zig` invokes that helper for page assets, site assets, and build
  assets only when `image_size_attributes` is enabled and no explicit size is
  already present.
- Failures are non-fatal: they are logged at debug level and leave the image
  size unset.
- `vendor/wuffs` is a Zig build wrapper. Its nested package downloads and
  compiles the roughly 3 MiB monolithic `wuffs-v0.4.c` release and translates
  its public declarations to Zig.
- Wuffs is configured for normal and all eight release-target builds even when
  image autosizing is disabled.
- The repository currently contains GIF and JPEG starter assets plus two WebP
  test assets, but no production fixture enables `image_size_attributes` and
  no focused test covers malformed image metadata.
- The root `translate_c` dependency remains necessary for `src/c.h`; removing
  Wuffs does not by itself remove all translate-c usage from Zine.

## Success criteria

- Page, site, and build images receive the same dimensions as the Wuffs path
  for PNG, JPEG, GIF, WebP, and BMP when autosizing is enabled.
- SVG and static AVIF receive dimensions according to the explicit rules in
  this plan, even though the Wuffs path does not support them.
- Explicitly supplied image dimensions are never overwritten.
- Autosizing disabled remains a zero-work path: no image file is opened.
- Unsupported, truncated, malformed, or inaccessible files remain non-fatal
  and do not produce width or height attributes.
- Every format in the replacement contract has focused valid, truncated, and
  malformed-input coverage.
- Dimension parsing performs no heap allocation and uses checked offsets and
  arithmetic throughout.
- Image probing no longer maps or reads an entire file when a small header or
  bounded segment scan is sufficient.
- `build.zig`, `build.zig.zon`, and the release graph contain no Wuffs package,
  module, translated header, C source, or libc link introduced solely by Wuffs.
- Focused tests, optimization-mode tests, property tests, production workflow
  snapshots, the full suite, and all release targets pass.
- Clean build and release artifacts demonstrate the expected build-size or
  build-time improvement; measurements are recorded without imposing a noisy
  machine-dependent pass/fail threshold.

## Design

### Public parsing API

Add `src/image_dimensions.zig` with a narrow API:

```zig
pub const Dimensions = struct {
    width: u32,
    height: u32,
};

pub const Format = enum {
    bmp,
    gif,
    jpeg,
    png,
    webp,
    svg,
    avif,
};

pub const ProbeError = error{
    UnsupportedFormat,
    UnsupportedVariant,
    Truncated,
    Malformed,
    DimensionOverflow,
};
```

Keep byte parsing independent from filesystem access. The core parser should
accept either a bounded random-access source or a small reader abstraction so
unit tests can use byte slices without opening files. The filesystem wrapper
should open the file and supply only requested ranges.

Do not expose format-specific structs to the rest of Zine. `worker.zig` needs
only a `Dimensions` result and the existing non-fatal wrapper.

### Safety rules

- Check every slice boundary before reading a field.
- Use explicit big- and little-endian helpers.
- Use checked addition when advancing over chunks or JPEG segments.
- Bound SVG prolog and root-element scanning; do not expand entities or parse
  external resources.
- Bound every ISO-BMFF box walk and validate extended sizes, nesting, item
  identifiers, and property associations before parsing AVIF dimensions.
- Reject zero dimensions and values that cannot fit the semantic image-size
  representation.
- Never trust a declared chunk or segment length to fit within the file.
- Do not allocate based on dimensions or declared payload lengths.
- Do not decode pixels, decompress payloads, validate checksums, or parse
  unrelated metadata.
- For SVG, return dimensions only when the root element's intrinsic size can be
  resolved without layout, CSS evaluation, or treating `viewBox` coordinates
  as CSS pixels.
- For AVIF, do not use the first `ispe` box found. Resolve the primary image
  item and its associated properties, and reject unsupported derived-image or
  sequence variants instead of guessing.

### I/O strategy

Replace whole-file `mmap` and the Windows mapping calls with bounded reads:

- fixed-header formats read one small prefix;
- WebP reads the RIFF header and the first image-bearing chunk header;
- JPEG walks marker headers and skips payloads until a supported SOF marker;
- SVG incrementally scans a bounded XML prolog and root element;
- AVIF walks only the required ISO-BMFF boxes and property associations;
- no path allocates a buffer proportional to file size.

If Zig's current `std.Io.File` API makes a reusable random-access abstraction
awkward, first land a slice-only parser behind the existing mapping wrapper,
then replace mapping in a separate slice. Do not combine parser correctness and
platform I/O lifetime changes into one review unit.

## Phase 1: Establish the Wuffs compatibility oracle

### Slice 1.1: Record baseline behavior and cost

Record:

- supported Wuffs formats and the exact Wuffs revision;
- current `check` and `check-release-targets` build graph inputs;
- clean-cache wall time for a representative native `check`;
- native executable size and the eight release archive sizes;
- current behavior for unknown, truncated, zero-sized, and malformed inputs.

Measurements are diagnostic evidence, not portable thresholds.

Suggested commit:

```text
docs: baseline Wuffs image probing
```

### Slice 1.2: Expose a test-only Wuffs oracle

Refactor the existing byte-slice logic so tests can call it directly while
Wuffs is still present. Keep production behavior unchanged.

Create compact, license-clear fixtures for PNG, JPEG, GIF, WebP, and BMP.
Prefer programmatically constructed minimal files or fixtures whose provenance
and license are recorded. Include each WebP encoding variant handled by Wuffs
(`VP8 `, `VP8L`, and `VP8X`) and representative BMP DIB/JPEG SOF variants.

Add an oracle table containing:

- format;
- expected width and height;
- Wuffs result;
- expected truncation boundary behavior.

Suggested commit:

```text
test: establish Wuffs dimension oracle
```

## Phase 2: Build the pure-Zig parser

### Slice 2.1: Add parser infrastructure and fixed layouts

Implement the shared cursor, checked endian reads, format result, and error
model. Add the formats whose dimensions are available in a fixed header:

- PNG;
- GIF;
- BMP, including the DIB variants accepted by the compatibility oracle.

For each format, test:

- minimum valid input;
- multiple dimension values and byte orders;
- every truncation point in the required header;
- bad signature or unsupported variant;
- zero, overflow, and structurally impossible dimensions;
- trailing bytes and unrelated payload bytes.

Compare successful and rejected cases with the Wuffs oracle.

Suggested commit:

```text
image: parse fixed-layout dimensions in Zig
```

### Slice 2.2: Add JPEG segment walking

Implement a bounded JPEG marker walker:

- require SOI;
- tolerate legal fill bytes and standalone markers;
- skip length-prefixed APP, DQT, DHT, COM, and other non-SOF segments;
- accept the SOF marker families for which Wuffs reports dimensions;
- reject invalid segment lengths, truncated payloads, missing SOF, arithmetic
  overflow, and dimensions of zero;
- stop before entropy-coded image data when no usable SOF was found.

Test metadata-heavy JPEGs where the SOF marker is not in the initial read,
multiple SOF variants, malformed marker streams, and truncation at every marker
field.

Suggested commit:

```text
image: parse JPEG dimensions in Zig
```

### Slice 2.3: Add WebP container variants

Validate RIFF size arithmetic and the `WEBP` signature, then parse dimensions
from:

- lossy `VP8 ` frame headers;
- lossless `VP8L` packed dimensions;
- extended `VP8X` 24-bit-minus-one dimensions.

Reject truncated chunks, wrong frame signatures, impossible dimensions, and
declared container/chunk lengths outside the file. Test odd-sized RIFF chunk
padding and all three variants against Wuffs.

Suggested commit:

```text
image: parse WebP dimensions in Zig
```

### Slice 2.4: Add SVG intrinsic sizing

Implement a bounded, non-validating XML root-element scanner. It must ignore an
optional BOM, XML declaration, comments, whitespace, and doctype without
expanding entities or accessing external resources. Once the root `<svg>`
element is found:

- accept finite, positive unitless and `px` width/height values;
- support other absolute CSS units only through explicit, tested conversion to
  CSS pixels;
- reject percentages, `auto`, relative units, CSS variables, and values that
  require stylesheet or layout evaluation;
- use a valid `viewBox` only as an aspect ratio to derive one missing absolute
  dimension;
- do not manufacture dimensions when `viewBox` is the only sizing information;
- round converted values according to one documented rule and reject overflow.

Test single and double quotes, attribute ordering, namespaces, comments,
doctypes, malformed XML prefixes, excessive prefixes, all supported units, one
missing dimension, percentage/relative dimensions, and `viewBox`-only SVGs.

Suggested commit:

```text
image: parse SVG intrinsic dimensions
```

### Slice 2.5: Add static AVIF dimensions

Implement a bounded ISO-BMFF walker for static AVIF files:

- validate a compatible AVIF brand in `ftyp`;
- locate `meta`, its primary item (`pitm`), item information, and item property
  container/associations (`iprp`, `ipco`, and `ipma`);
- obtain dimensions from the `ispe` property associated with the primary image
  item rather than from an unrelated image, thumbnail, or alpha item;
- account for supported clean-aperture and rotation properties when they alter
  the displayed dimensions;
- support the common direct `av01` primary-image case;
- add grid-derived images only after their output dimensions and item
  references are validated;
- reject image sequences, unknown derived-image types, malformed box trees,
  cycles, and unsupported transformations instead of guessing.

Test 32-bit and extended box sizes, reordered boxes, unrelated `ispe`
properties, large item identifiers, thumbnails and alpha items, cropping,
rotation, grid images if supported, truncation at every box field, and static
files produced by representative encoders.

Suggested commit:

```text
image: parse static AVIF dimensions
```

### Slice 2.6: Differential and property coverage

While both implementations exist, run PNG, JPEG, GIF, WebP, and BMP fixtures
and generated mutations through Wuffs and the Zig parser. Run SVG and static
AVIF through independent expected-result fixtures. Classify differences as:

- new-parser bug;
- deliberate stricter validation;
- existing Wuffs behavior to preserve;
- invalid fixture assumption.

For generated inputs, require that the Zig parser never traps, reads out of
bounds, allocates, or returns zero dimensions. Run every valid fixture through
all prefix truncations and targeted length-field mutations.

Document accepted differences before removing the oracle.

Suggested commit:

```text
test: validate Zig image probing against Wuffs
```

## Phase 3: Integrate bounded file probing

### Slice 3.1: Introduce the filesystem probe

Add a filesystem-facing helper which:

- opens the image once;
- uses small fixed buffers and positional reads or bounded seeks;
- reports file errors separately from parser errors for useful debug logging;
- closes all handles on every path;
- performs no heap allocation in normal probing;
- works on Linux, macOS, FreeBSD, and Windows without platform-specific mapping
  APIs.

Test it with temporary files containing every valid fixture plus inaccessible,
empty, truncated, and oversized-declaration cases.

Suggested commit:

```text
image: probe dimensions with bounded file reads
```

### Slice 3.2: Replace worker call sites

Replace `@import("wuffs.zig")` with the new image-dimension module and route the
three existing asset kinds through one helper:

- page assets;
- site assets;
- build assets.

Preserve these conditions exactly:

- do nothing unless `image_size_attributes` is enabled;
- do nothing for non-image directives;
- do not overwrite an explicit size;
- keep failures non-fatal and visible only through debug logging;
- set both width and height from one successful probe.

Consolidate duplicated worker call-site conditions only if the resulting asset
base-directory and path ownership remain obvious.

Suggested commit:

```text
image: use the Zig dimension probe for local assets
```

## Phase 4: Add production workflow coverage

### Slice 4.1: Exercise every asset source

Add a rendering fixture with `image_size_attributes = true` and cover:

- a page-relative image;
- a site asset;
- a build asset;
- an image with an explicit size directive;
- an unsupported or malformed image;
- autosizing disabled in a comparison fixture.

Snapshots must verify:

- successful probes emit exact `width` and `height` attributes;
- an explicit size wins;
- malformed/unsupported files still render without generated dimensions;
- each image is emitted once with the correct URL.

Suggested commit:

```text
render: cover automatic image dimensions
```

### Slice 4.2: Cover representative formats in workflow tests

Send PNG, JPEG, GIF, all three WebP variants, BMP, SVG, and static AVIF through
a real `zine release`. Include SVG cases with and without resolvable intrinsic
dimensions and an AVIF case with an unrelated `ispe` property so the workflow
test verifies selection rather than signature recognition alone.

Run `test-workflows` so the same fixture also passes through the development
server path.

Suggested commit:

```text
test: exercise image formats through Zine workflows
```

## Phase 5: Remove Wuffs

### Slice 5.1: Remove runtime and build integration

After differential tests pass:

- remove `src/wuffs.zig`;
- remove normal-build and release-build `b.dependency("wuffs", ...)` calls;
- remove both `addImport("wuffs", ...)` calls;
- remove `.wuffs` from the root `build.zig.zon`;
- remove `vendor/wuffs` and its nested upstream dependency;
- retain the root `translate_c` dependency used for `src/c.h`;
- remove temporary Wuffs-oracle code and tests.

Confirm with `rg` that no source, build, documentation, or test path still
depends on Wuffs. Generated cache/package directories are not source and must
not be committed.

Suggested commit:

```text
build: remove Wuffs image dependency
```

### Slice 5.2: Record the migration result

Repeat the Phase 1 measurements with a clean local cache where practical.
Record:

- removed package and C translation inputs;
- native executable and release archive sizes;
- representative clean and incremental build times;
- any accepted format behavior differences;
- the intentional removal of Netpbm, NIE, QOI, TGA, and WBMP autosizing;
- the addition and supported-variant boundaries of SVG and static AVIF.

Suggested commit:

```text
docs: record pure Zig image probing results
```

## Phase 6: Final validation

### Slice 6.1: Focused gates

Add a dedicated build step if the image tests are not naturally included in an
existing focused gate, then run:

```sh
./build.sh test-image-dimensions
./build.sh test-markdown-modes
./build.sh test-markdown-properties
./build.sh test-workflows
```

Run the image parser in Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Use
allocation-failure testing only for the filesystem wrapper if it allocates;
the byte parser itself should have no allocator parameter.

### Slice 6.2: Full and release gates

```sh
./build.sh test
./build.sh check
./build.sh check-release-targets -Dpreview=true
./build.sh test-release-tool-isolation
./build.sh verify-release -Dpreview=true
```

The release-target matrix is especially important because removing Wuffs also
removes its translated C API and Windows-specific mapping path.

### Slice 6.3: Repository audit

- Run `zig fmt` on all touched Zig files.
- Run `git diff --check`.
- Confirm generated binary fixtures have documented provenance and minimal
  size.
- Confirm snapshots changed only for intentional width/height output.
- Confirm `rg -n "wuffs|WUFFS"` finds no live dependency or source references.
- Confirm no temporary oracle files, generated sites, logs, compiler processes,
  or packaging processes remain.
- Update `docs/markdown-validation.md` or add focused image-validation
  documentation for the permanent gates.

Suggested commit:

```text
docs: complete pure Zig image validation
```

## Completion checklist

- [ ] Phase 1: Wuffs behavior and build cost are baselined.
- [ ] Phase 2: the pure-Zig parser covers PNG, JPEG, GIF, WebP, BMP, SVG, and
      static AVIF according to the documented contract.
- [ ] Phase 3: bounded file probing replaces whole-file mapping in production.
- [ ] Phase 4: production rendering verifies automatic dimensions.
- [ ] Phase 5: Wuffs and its build wrapper are removed.
- [ ] Phase 6: focused, full, workflow, and release validation passes.

The replacement is complete only when the Wuffs oracle has served its purpose,
the narrower legacy-format scope and new SVG/AVIF support are documented, all
accepted behavior differences are recorded, and no production or build path
references Wuffs.
