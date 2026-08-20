# Vendored build dependencies

These packages are vendored to keep Zine's dependencies on one Zig-compatible
revision. The pure-Zig Markdown migration removed SuperMD's cmark-gfm
implementation; its remaining package contains only the directive context used
by Zine's semantic pass.

| Directory | Upstream revision | Zig package hash | Local changes |
| --- | --- | --- | --- |
| `superhtml` | `kristoff-it/superhtml@23ef2f44ca0df2d2e05a0be3874370553c5b591d` | `superhtml-0.7.0-Y7MdPHKkJgA1s7ycx0okrfwclJaChKuAbTrsjmQ3uGlM` | Replace two removed `ArrayList.getLast()` calls with `last()`. |
| `supermd` | `kristoff-it/supermd@28af383ecbb4ee861b8b45024475eb74f71b283e` | `supermd-0.1.0-3Mco3OS8WADDwP6qVCK2_GSoTLrjv_vUdM39eKqiFnfO` | Retain the directive/Scripty context only; remove the cmark AST, C header, libraries, and cmark-only dependencies. |

The upstream license files are retained inside each package directory.
