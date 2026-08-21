# Learning: Nested Lazy Dependencies Can Hide Public Zig Modules

## Lesson

With the pinned Zig compiler, a package consumed through
`dependency.module(...)` must register that module during its first clean
configuration. If its build script first encounters an unavailable nested lazy
dependency and returns, the parent can panic because the public module was
never registered.

## Context And Symptom

Zine's native-highlighting branch passed locally but failed on clean GitHub
Actions runners for Linux, macOS, and Windows with:

```text
panic: unable to find module "native_syntax"
```

The panic came from Zine requesting the module exported by
`zig-native-syntax`. A populated local package directory had hidden the
first-configuration behavior.

## Cause Or Explanation

The package declared parser adapters as lazy dependencies and called
`lazyDependency(...) orelse return` before registering its public modules. On
a clean consumer, the nested dependency was marked for fetching, but control
returned to Zine, which immediately called `dependency.module(...)` on the
partially configured package.

## Check First

- Inspect the dependency's `build.zig` for an early return before `addModule`.
- Reproduce from a clean checkout without a populated local package directory.
- Use `zig build --fetch=all` as a diagnostic: if it makes the next build pass,
  nested lazy dependency discovery is involved.
- Do not infer that a local cache-directory override also isolates a separate
  project-local package directory.

## Verified Approach

Declare dependencies needed by public optional modules as eager manifest
dependencies, then use build options to configure, compile, and link only the
selected modules. This preserves a dependency-free compiled core while making
public modules discoverable on the first clean consumer build.

The CI cache also keys on `build.zig` and `build.zig.zon`; that prevents stale
build graphs but is not a substitute for fixing nested lazy module discovery.

## Avoid

Do not treat `panic: unable to find module` as cache corruption merely because
the dependency exists locally. Cache invalidation alone does not fix a package
build that returns before exporting its modules.

## References

- [Pinned dependency](../../../build.zig.zon)
- [Native highlighting validation](../../native-highlighting-validation.md)

## Search Keywords

unable to find module native_syntax, dependency.module, lazyDependency,
nested lazy dependency, build.zig.zon, clean consumer, setup-zig cache
