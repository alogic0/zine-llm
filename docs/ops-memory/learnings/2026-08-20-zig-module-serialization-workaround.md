# Learning: Pinned Zig Module Serialization Workaround

## Lesson

Zine's exact Zig `0.17.0-dev.1756+613c03321` build graph requires
`workAroundPinnedZigModuleSerialization()` at the end of `build()`. Do not
remove, move, or narrow it without validating the complete dependency and
release-target graphs.

## Context And Symptom

During preparation for the pure-Zig Markdown migration, public dependency
modules that transitively linked compiled libraries caused build-graph
serialization to unwrap a missing `std.Build.Serialize.stepIndex`.

The workaround and exact Zig pin were introduced together in commit
`381443f8bba65a63d0fe4ab7e1c196d31e3857ac`.

## Cause Or Explanation

This Zig development build serializes public dependency modules before it has
discovered every compile-step dependency. A public module may import another
module that links a compile step, so clearing only the directly linked module
is insufficient.

By the end of Zine's `build()` function, required modules are already reachable
from top-level compile steps. Clearing each dependency builder's public module
lookup table at that point lets serialization rediscover the modules through
those compile-step graphs after step indexes exist.

## Check First

```sh
./build.sh --help
git blame -L 636,650 -- build.zig
rg -n "required_zig_version|workAroundPinnedZigModuleSerialization" build.zig build.sh build.zig.zon
```

Inspect:

- the exact compiler path in `build.sh`;
- `required_zig_version` in `build.zig`;
- `.minimum_zig_version` in `build.zig.zon`;
- the final call to `workAroundPinnedZigModuleSerialization()` in `build.zig`.

## Verified Approach

Keep the workaround after all top-level modules and compile steps have been
created. When changing the Zig pin or dependency graph, validate at least:

```sh
./build.sh check
./build.sh test
./build.sh check-release-targets -Dpreview=true
./build.sh verify-release -Dpreview=true
```

If a newer Zig build no longer needs the workaround, remove it only in the
same change that updates the pin and passes these gates.

## Avoid

- Do not invoke an arbitrary `zig` from `PATH`; use `./build.sh`.
- Do not clear only the module that appears in the immediate failure.
- Do not move the workaround earlier, before the top-level graph is complete.
- Do not assume a native `check` proves all cross-target module graphs work.

## References

- Implementation: `build.zig`
- Toolchain launcher: `build.sh`
- Package minimum: `build.zig.zon`
- Introducing commit: `381443f8bba65a63d0fe4ab7e1c196d31e3857ac`
- Vendored dependency pins: `vendor/UPSTREAM.md`

## Search Keywords

Zig 0.17.0-dev.1756, std.Build.Serialize.stepIndex, unwrap null, public module,
dependency_cache, clearRetainingCapacity, build graph, module serialization
