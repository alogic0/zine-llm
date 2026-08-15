# Image format workflow fixture

`build.zig` materializes the binary fixture inputs from
`src/image_dimensions_fixtures.zig`, runs a real Zine release, and snapshots
the resulting HTML here. Keeping the generated site in the build cache avoids
duplicating binary fixtures in the repository.
