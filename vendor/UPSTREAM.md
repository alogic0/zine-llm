# Vendored build dependencies

These packages are vendored temporarily to keep Zine's direct and SuperMD-transitive
dependencies on one Zig-compatible revision while the pure-Zig Markdown migration
removes SuperMD and cmark-gfm.

| Directory | Upstream revision | Zig package hash | Local changes |
| --- | --- | --- | --- |
| `superhtml` | `kristoff-it/superhtml@23ef2f44ca0df2d2e05a0be3874370553c5b591d` | `superhtml-0.7.0-Y7MdPHKkJgA1s7ycx0okrfwclJaChKuAbTrsjmQ3uGlM` | Replace two removed `ArrayList.getLast()` calls with `last()`. |
| `supermd` | `kristoff-it/supermd@28af383ecbb4ee861b8b45024475eb74f71b283e` | `supermd-0.1.0-3Mco3OS8WADDwP6qVCK2_GSoTLrjv_vUdM39eKqiFnfO` | Point SuperHTML and translate-c at their sibling vendored packages. Only the files needed to build the Zig package are included. |
| `translate-c` | `ziglang/translate-c@330c97b4af783b724586c7ff626cf512afb19c21` | `translate_c-0.0.0-Q_BUWn1CBwC9g-axMDfnTrjyLYRyX-dr34bIHjPPz2Go` | None. Its manifest selects `ziglang/arocc@a4e99cedda3bff1e3a3a388e9f6ed05bbd36e441`. |
| `wuffs` | `allyourcodebase/wuffs@364ba880b20ca1c9b94ee41b07738bc941cee275` | `wuffs-0.4.0-alpha.9+3837.20240914-3CHJgY8LAADueYEeHrj8cQs_rZQ0bDGsngrbgV7Z2LFt` | Point translate-c at the sibling vendored package. Only the Zig package build files are included; Wuffs C sources remain the package's declared upstream dependency. |

The upstream license files are retained inside each package directory.
