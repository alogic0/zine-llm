# Image-Dimension Validation

Zine's local-image autosizing uses an allocation-free Zig metadata parser and
bounded positional file reads. The permanent focused gate is:

```sh
./build.sh test-image-dimensions
```

It covers:

- valid, truncated, malformed, and unsupported PNG, JPEG, GIF, BMP, WebP,
  SVG, and static AVIF metadata;
- generated dimensions for the retained legacy formats;
- every fixture prefix, deterministic single-byte mutations, arbitrary input,
  and hostile declared lengths;
- temporary-file probing, filesystem failures, and large skipped JPEG, WebP,
  and AVIF ranges;
- the byte parser in Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.

The parser and normal filesystem probe take no allocator, so allocation-failure
injection is not applicable. SVG and retained AVIF metadata are capped at 64
KiB; JPEG and WebP payloads are skipped with positional reads.

Production behavior is covered by rendering snapshots and both release and
live-server workflows:

```sh
./build.sh test
./build.sh test-workflows
```

The snapshots cover page, site, and build assets, explicit-size precedence,
disabled autosizing, non-fatal malformed input, every supported format, all
three WebP variants, unresolved SVG, and AVIF primary-property selection.

The compact PNG, GIF, JPEG, BMP, WebP, and synthetic AVIF fixtures are built
programmatically in `src/image_dimensions_fixtures.zig`. The real AVIF sample
is libavif v1.2.0's BSD-licensed `tests/data/white_1x1.avif`; its provenance is
recorded next to the base64 fixture. Workflow binary inputs are materialized
from those same arrays into the build cache, so the repository does not carry
duplicate generated binaries.

Before release, run the cross-target and packaging gates:

```sh
./build.sh check
./build.sh check-release-targets -Dpreview=true
./build.sh test-release-tool-isolation
./build.sh verify-release -Dpreview=true
```

Historical Wuffs references remain in the migration plan and baseline report.
Live source, tests, manifests, and vendored packages contain no Wuffs module,
C source, translated header, or package dependency. The independent
`translate_c` dependency remains for `src/c.h`.
