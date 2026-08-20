# Decision: Keep Local Validation Native And Run Release Matrices In CI

## Decision

Normal local development builds and tests only the developer's host
architecture. GitHub CI owns multi-OS native validation, cross-target release
compilation, and release archive verification.

## Date And Status

- Date: 2026-08-20
- Status: accepted
- Owners: fork maintainers

## Context

Zine supports eight release triples, but building every target on each local
iteration is slow and duplicates work that a shared CI runner can perform more
consistently. Local feedback should remain fast while release portability and
packaging stay continuously verified.

## Options Considered

- Require every contributor to build and verify every supported target locally.
- Limit local validation to the host and assign platform and release matrices
  to GitHub CI.

## Consequences

- Pull requests run native tests on Linux, Windows, and macOS runners.
- Pushes to `main` additionally compile every supported release target and
  verify that non-packaging build steps do not depend on archive tools.
- Version tags and manual workflow dispatches build and verify all release
  archives.
- Normal local work uses `./build.sh check`, `./build.sh test`,
  `./build.sh test-workflows`, and relevant focused native gates. It does not
  require `check-release-targets`, `release`, or `verify-release`.
- Changes to the compiler pin, target definitions, release graph, or packaging
  may still need targeted investigation, but the authoritative all-target
  result comes from CI.

## Evidence And Verification

- Relevant files: `.github/workflows/ci.yml`, `build.zig`, `build.sh`,
  `docs/markdown-validation.md`, and `docs/image-validation.md`.
- Native verification commands: `./build.sh check`, `./build.sh test`, and
  `./build.sh test-workflows`.
- CI release commands: `zig build check-release-targets -Dpreview=true`,
  `zig build test-release-tool-isolation`, and
  `zig build verify-release -Dpreview=true`.

## Revisit When

Revisit if CI cannot cover a supported platform, if target compilation depends
on host-specific behavior, or if the release process moves away from GitHub
Actions.

## Search Keywords

native validation, GitHub Actions, release targets, cross compilation,
check-release-targets, test-release-tool-isolation, verify-release, Zig pin
