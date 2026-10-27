# Setu

[![ci](https://github.com/YoSTEALTH/Setu/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/YoSTEALTH/Setu/actions/workflows/ci.yml?query=branch%3Amain)
[![tag](https://img.shields.io/github/v/tag/YoSTEALTH/Setu?sort=date&label=tag)](https://github.com/YoSTEALTH/Setu/tags)
[![zig](https://img.shields.io/badge/zig-0.17.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![python](https://img.shields.io/badge/python-3.14%20%7C%203.14t%20%7C%203.15%20%7C%203.15t-3776AB?logo=python&logoColor=white)](https://www.python.org/downloads/)
[![abi](https://img.shields.io/badge/abi-abi3t%20(PEP%20803)-3776AB)](https://peps.python.org/pep-0803/)
[![platform](https://img.shields.io/badge/platform-linux-FCC624?logo=linux&logoColor=black)](https://kernel.org/)
[![license](https://img.shields.io/github/license/YoSTEALTH/Setu)](LICENSE.txt)

Setu (सेतु, "bridge"): a generic Zig <-> CPython binding layer. One build loads on
CPython 3.14, 3.14t, 3.15, 3.15t and later: a single `<name>.so` in one
`cp314.cp315-abi3.abi3t.cp314t.cp315t` wheel per platform (the 3.15 stable ABI for free-threading,
PEP 803, plus a 3.14 entry point). Any pip installs it on 3.14, 3.14t, 3.15 and 3.15t; 3.16t and later
need pip 26.2+ (`abi3t`). PEP 697 type data, critical sections. No `Python.h`: the C API is declared by hand in
`src/capi.zig`.
Zig 0.17.0, Linux.

Setu is mainly for the [Shakti](https://github.com/YoSTEALTH/Shakti) and
[Liburing](https://github.com/YoSTEALTH/Liburing) projects, which use it as a dependency (it never imports
either). For your own extensions, use [PyOZ](https://pyoz.dev) instead: it fills the same role and is
documented and maintained for public use.

```
src/root.zig      the module root (@import("setu"))
src/capi.zig      hand-declared C API
src/py.zig        functions, conversions, errors, the module (exportModule)
src/scan.zig      setu.From: which declarations of a Module.from namespace Python gets
src/class.zig     setu.Class: a struct becomes a Python type
src/exception.zig setu.Exception: an exception class of the extension
src/stub.zig      .pyi text (stub.module writes an extension's whole .pyi)
src/stubgen.zig   the stub generator addStubs builds (no libpython)
test/             setu_classes, a test extension with a class per hook family (the model root file)
test/wheel/       setu_classes as a project, for the tools/setu_build.py wheel checks
test/docs/        setu_classes as a docs site, for the tools/setu_docs.py checks
tools/setu_build.py   the wheel build backend (PEP 517) projects copy into their tools/
tools/setu_docs.py    the docs site builder projects copy into their tools/
tools/setu_docs_web.zig  the site's search and Run logic (WebAssembly, zig build docs-web)
tools/check_coverage.py  line coverage under pytest (kcov), run by zig build coverage (addCoverageSteps)
```

Commands:

```sh
zig build test                        # type-check every declaration + comptime and docs-web unit tests
zig build develop                     # test extension (setu_classes.so) + stubs into test/
python3 tools/check_docs.py           # the docs site of test/docs/ (after develop)
tools/check.sh                        # every check, on 3.15t, 3.15, 3.14t and 3.14
python3 tools/bench.py --ref HEAD     # per-call cost, A/B against a commit (`-Doptimize=fast`)
zig build coverage -Dpython=python3   # line coverage of the test extension (kcov), zig-out/coverage/
```

## For AI sessions (and other readers in a hurry)

`llms.txt` is the index to read first; `docs/setu-guide.md` is the guide to writing an extension: the rules,
every parameter type, every class hook signature, every compile error Setu raises. A project using Setu keeps a
copy of the guide at `docs/setu-guide.md` (`zig build setu-guide-sync` / `setu-guide-check`, see
`addSetuGuideSteps`), so a session working on its bindings finds it inside the project.
`tools/check_guide.py` keeps the guide in step with the source. A project's own docs site gets `llms.txt` and
`llms-full.txt` for its Python API from `tools/setu_docs.py`.

## An extension: one `module` declaration

The extension's root file lists its Zig files once. Setu finds their lowercase `pub fn`s (functions),
`setu.Class`es, `setu.Exception`s, UPPER_CASE constants and enums, creates them in its `Py_mod_exec`
(classes bases first), adds `__version__`, runs `init`, and writes the `.pyi` from the same declaration:

```zig
const setu = @import("setu");

pub const module: setu.Module = .{
    .name = "point",
    .version = "1.0",
    .from = &.{
        .{ .ns = @import("point.zig"), .source = @embedFile("point.zig") },
        .{ .ns = @import("kernel.zig"), .prefixes = &.{"O_"} }, // constants only: no `source`
        .{ .ns = @import("enum.zig"), .enums = .int_enum }, // `enum.IntEnum` classes
    },
    .init = init, // after Setu's part
};

fn init(_: *setu.c.Object) setu.py.Error!void {}

comptime {
    setu.py.exportModule(module);
}
```

```zig
// build.zig: the .pyi, written by Setu's stub generator (built for the host, no libpython)
const pyi = @import("setu").addStubs(b, setu_dep, .{ .root_source_file = b.path("src/root.zig") });
```

`_`-named declarations, camelCase `pub fn`s, plain structs and lowercase values are skipped; a name
found twice is a compile error. `src/scan.zig` (top) has the rules, `test/setu_classes.zig` an example of
each filter (`.only`, `.exclude`, `.prefixes`, `.functions = false`).

## Naming

Setu's own code follows Zig style. In a file that `Module.from`, `py.exportFns` or `setu.Class` exports, a lowercase
`pub fn`, snake_case included (`prep_recv`, `get_label`), is a Python function, method or property under
that name; camelCase `pub fn`s are Zig-only helpers. So snake_case function names there are on purpose,
not a slip from Zig's camelCase rule: they are the Python names. Hooks keep their Python names too
(`__init__`, `__repr__`).

## Wheels: `tools/setu_build.py`

A PEP 517 build backend (no setuptools) that builds a Zig + Setu extension's wheels with `zig build`.
A backend must sit in the project's own tree, so each project keeps a byte-identical copy in its
`tools/`, never edited there: what differs per project goes in `[tool.setu_build]` in its
`pyproject.toml` (the keys are listed in the script's docstring). Setu tests the script itself:
`tools/check.sh` builds the glibc and musl wheels of `test/wheel/` and pip-installs them on every
interpreter (`tools/check_wheels.py`).

A project keeps its copy in step with the Setu it pins with two `zig build` steps, from its
`build.zig` (`setu` must be in its `build.zig.zon`):

```zig
const setu_dep = b.dependency("setu", .{});
@import("setu").addSetuBuildSteps(b, setu_dep);
```

`zig build setu-build-sync` copies the pinned Setu's `tools/setu_build.py` into `tools/` (run it after
bumping Setu); `zig build setu-build-check` fails if the copy differs (run it in the project's checks).

## Docs site: `tools/setu_docs.py`

A static HTML site built by Setu's own builder, Python's standard library only: the API pages from the imported
module's docstrings (the `///` docs; typed signatures from the `.pyi`), grouped by a `[tool.setu_docs]` table in
the project's `pyproject.toml` (the keys are in the script's docstring), the project's Markdown pages, the
constants, its example scripts, `llms.txt` / `llms-full.txt`, and a runner for the `>>>` examples
(`setu_docs.py check`; project fixtures in a hooks file). Search and the Run transcript are Zig compiled to
WebAssembly (`tools/setu_docs_web.zig`); `setu_docs.py serve` serves the site on 127.0.0.1 with Run buttons
that run an example and show its session (only on examples that can run: none that read a name nothing defines;
the published site has no Run buttons). A Markdown table after a `<!-- chart -->` line becomes a colored bar
chart (GitHub shows the table). The project keeps a byte-identical copy of `setu_docs.py` in `tools/`,
like `setu_build.py`, in step with `addSetuDocsSteps` (`zig build setu-docs-sync` / `setu-docs-check`), which
also adds `zig build docs-web` (the Wasm module, from the pinned Setu; `setu_docs.py` runs it). `test/docs/` is
a working model (`tools/check_docs.py`). The workflow runs `zig build develop` (the extension and its stub),
then `python tools/setu_docs.py` (writes `site/`), and uploads `site/` to GitHub Pages.

## Releases

Versions are `<year>.<month>.<day>[-<n>]`, no zero padding: `2026.10.20` for a day's first release, then
`2026.10.20-2`, `2026.10.20-3`, ... Tags are `v<version>` (the `build.zig.zon` version). Each tag's notes say whether
`tools/setu_build.py` changed since the previous tag: if it did, projects run `zig build setu-build-sync`
after bumping to it. `git diff --quiet <previous tag> <tag> -- tools/setu_build.py` tells (exit 1: changed).
