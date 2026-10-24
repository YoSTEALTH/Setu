#!/usr/bin/env bash
# Runs every Setu check: zig fmt, int casts, ruff, `zig build test`, the `setu-build-sync` /
# `setu-build-check` steps on the wheel fixture `test/wheel/`, `zig build develop` (the one `setu_classes.so`
# and its generated stubs, which `ruff check` lints: an import Setu writes but the stub does not use fails),
# then with each interpreter (3.15t, 3.15, 3.14t, 3.14) `check_abi.py`, `check_symbols.py`, pytest and the
# `cp314.cp315-abi3.abi3t.cp314t.cp315t` wheels `tools/setu_build.py` builds (`check_wheels.py`), then
# `mypy --strict` (as 3.14 and 3.15) + `stubtest` on the test stubs. All offline.
# Interpreters: PY_FT=... / PY_GIL=... (3.15), PY314_FT=... / PY314_GIL=...; compiler: ZIG=...
set -euo pipefail

cd "$(dirname "$0")/.."
PY_FT=${PY_FT:-/opt/python/3.15t/bin/python3}
PY_GIL=${PY_GIL:-/opt/python/3.15/bin/python3}
PY314_FT=${PY314_FT:-/opt/python/3.14t/bin/python3}
PY314_GIL=${PY314_GIL:-/opt/python/3.14/bin/python3}
ZIG=${ZIG:-zig}
[[ ${1:-} == -- ]] && shift
PYTEST_ARGS=("$@")

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "zig fmt"
"$ZIG" fmt --check src test build.zig build.zig.zon

step "int casts"
# An `@intCast` / `@truncate` needs a `// cast: <why it fits>` on its line or the line above; a value a
# caller chooses goes through `py.narrow` (or an exact parameter type) instead.
awk '
    FNR == 1 { prev = "" }
    /@(intCast|truncate)\(/ && $0 !~ /^[[:space:]]*\/\// && $0 !~ /\/\/.*cast:/ && prev !~ /^[[:space:]]*\/\/ cast:/ {
        printf "%s:%d: cast without a `// cast:` reason (or use `py.narrow`)\n%s\n", FILENAME, FNR, $0; bad = 1
    }
    { prev = $0 }
    END { exit bad }
' src/*.zig test/*.zig

step "ruff"
"$PY_FT" -m ruff check .
"$PY_FT" -m ruff format --check .

step "zig build test"
"$ZIG" build test --summary all

step "setu-build-sync + setu-build-check (test/wheel)"
# What a project using Setu runs: copy Setu's `tools/setu_build.py` into its `tools/`, then compare.
(cd test/wheel && "$ZIG" build setu-build-sync && "$ZIG" build setu-build-check)

step "zig build develop"
"$ZIG" build develop # test/setu_classes.so: one binary for every interpreter below

step "ruff check (generated stubs)"
"$PY_FT" -m ruff check test/setu_classes.pyi # gitignored, so `ruff check .` above skips it
"$PY_FT" -m ruff format --check test/setu_classes.pyi

for py in "$PY_FT" "$PY_GIL" "$PY314_FT" "$PY314_GIL"; do
    step "$py"
    "$py" tools/check_abi.py
    "$py" tools/check_symbols.py test/setu_classes.so
    "$py" -m pytest "${PYTEST_ARGS[@]}"
    "$py" tools/check_wheels.py --all # glibc + musl, installed and imported here
    "$py" tools/check_wheels.py       # `build_wheel` (PEP 517)
done

step "mypy --strict + stubtest ($PY_FT)"
if "$PY_FT" -c 'import mypy' 2>/dev/null; then
    (cd test && MYPYPATH=. "$PY_FT" -m mypy --strict --python-version 3.14 setu_classes.pyi)
    (cd test && PYTHONPATH=. MYPYPATH=. "$PY_FT" -m mypy --strict setu_classes.pyi)
    (cd test && PYTHONPATH=. MYPYPATH=. "$PY_FT" -m mypy.stubtest setu_classes)
else
    echo "skipped: mypy is not installed for $PY_FT"
fi

step "setu_docs.py ($PY_FT)"
"$PY_FT" tools/check_docs.py
if "$PY_FT" -c 'import mkdocs, mkdocstrings, mkdocs_gen_files' 2>/dev/null; then
    "$PY_FT" tools/check_docs.py --site
else
    echo "skipped: the site build needs mkdocs, mkdocstrings and mkdocs-gen-files for $PY_FT"
fi

step "all checks passed"
