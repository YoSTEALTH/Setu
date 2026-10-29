#!/usr/bin/env bash
# Runs every Setu check: zig fmt, package paths, int casts, ruff (also on the copied tools with the consumers' rules),
# `zig build test`, the `setu-build-sync` / `setu-build-check` and `setu-guide-*` steps on the wheel fixture
# `test/wheel/`, `check_guide.py`, `zig build develop` (the one `setu_classes.so`
# and its generated stubs, which `ruff check` lints with flake8-pyi: an unused import or a `__repr__` fails),
# then with each interpreter (3.15t, 3.15, 3.14t, 3.14, and 3.16t-dev / 3.16-dev when installed)
# `check_abi.py`, `zig build check-symbols`, pytest, the `cp314.cp315-abi3.abi3t.cp314t.cp315t` wheels
# `tools/setu_build.py` builds (`check_wheels.py`) and the docs site `tools/setu_docs.py` builds, serves and runs
# the examples of (`check_docs.py`), then
# `mypy --strict` (as 3.14 and 3.15) + `stubtest` on the test stubs. All offline.
# Interpreters: PY_FT=... / PY_GIL=... (3.15), PY314_FT=... / PY314_GIL=..., PY316_FT=... / PY316_GIL=...
# (the next CPython's alphas, for early warning only: skipped when missing); compiler: ZIG=...
set -euo pipefail

cd "$(dirname "$0")/.."
PY_FT=${PY_FT:-/opt/python/3.15t/bin/python3}
PY_GIL=${PY_GIL:-/opt/python/3.15/bin/python3}
PY314_FT=${PY314_FT:-/opt/python/3.14t/bin/python3}
PY314_GIL=${PY314_GIL:-/opt/python/3.14/bin/python3}
PY316_FT=${PY316_FT:-/opt/python/3.16t-dev/bin/python3}
PY316_GIL=${PY316_GIL:-/opt/python/3.16-dev/bin/python3}
ZIG=${ZIG:-zig}
[[ ${1:-} == -- ]] && shift
PYTEST_ARGS=("$@")

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "zig fmt"
"$ZIG" fmt --check src test tools build.zig build.zig.zon

step "package paths"
# Every file build.zig runs from a dependent's pinned Setu (`setu_dep.path("...")`) must ship in the package:
# a URL-fetched Setu holds only `build.zig.zon`'s `.paths`.
"$PY_FT" - <<'PY'
import re, sys
zon = open('build.zig.zon').read()
paths = re.findall(r'"([^"]+)"', zon[zon.index('.paths'):])
used = set(re.findall(r'setu_dep(?:\.path\(|, )"([^"]+)"', open('build.zig').read()))  # also `addCopySteps`
bad = sorted(u for u in used if not any(u == p or u.startswith(p + '/') for p in paths))
for u in bad:
    print(f'build.zig runs `{u}` from the dependency, but build.zig.zon\'s .paths lacks it')
sys.exit(1 if bad or not used else 0)
PY

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
' src/*.zig test/*.zig tools/*.zig

step "ruff"
"$PY_FT" -m ruff check .
"$PY_FT" -m ruff format --check .

step "ruff on the copied tools, as the consumers see them"
# Liburing and Shakti lint their copies with ruff's default rules (more than Setu's E/F/W) and format for
# Python 3.14 (`except A, B:`), so the copies must pass both without their own settings.
copied=(tools/setu_build.py tools/setu_docs.py)
"$PY_FT" -m ruff check --isolated --line-length 120 --target-version py314 "${copied[@]}"
"$PY_FT" -m ruff format --isolated --check --line-length 120 --target-version py314 \
    --config 'format.quote-style = "preserve"' "${copied[@]}"

step "zig build test"
"$ZIG" build test --summary all

step "setu-build-sync + setu-build-check, setu-guide-sync + setu-guide-check (test/wheel)"
# What a project using Setu runs: copy Setu's `tools/setu_build.py` and `docs/setu-guide.md` in, then compare.
(cd test/wheel && "$ZIG" build setu-build-sync setu-guide-sync && "$ZIG" build setu-build-check setu-guide-check)

step "docs/setu-guide.md"
"$PY_FT" tools/check_guide.py

step "zig build develop"
"$ZIG" build develop # test/setu_classes.so: one binary for every interpreter below

step "ruff check (generated stubs)"
# gitignored, so `ruff check .` above skips it; flake8-pyi too (PYI021: the docstrings are on purpose)
"$PY_FT" -m ruff check --extend-select PYI --extend-ignore PYI021 test/setu_classes.pyi
"$PY_FT" -m ruff format --check test/setu_classes.pyi

pythons=("$PY_FT" "$PY_GIL" "$PY314_FT" "$PY314_GIL")
for py in "$PY316_FT" "$PY316_GIL"; do
    if [[ -x $py ]]; then pythons+=("$py"); else echo "skipped: $py is not installed"; fi
done
for py in "${pythons[@]}"; do
    step "$py"
    "$py" tools/check_abi.py
    "$ZIG" build check-symbols -Dpython="$py" # tools/check_symbols.py, as `addSymbolCheck` runs it
    "$py" -m pytest "${PYTEST_ARGS[@]}"
    "$py" tools/check_wheels.py --all # glibc + musl, installed and imported here
    "$py" tools/check_wheels.py       # `build_wheel` (PEP 517)
    "$py" tools/check_docs.py         # the docs site of test/docs/: built, served, every example run
done

step "mypy --strict + stubtest ($PY_FT)"
if "$PY_FT" -c 'import mypy' 2>/dev/null; then
    (cd test && MYPYPATH=. "$PY_FT" -m mypy --strict --python-version 3.14 setu_classes.pyi)
    (cd test && PYTHONPATH=. MYPYPATH=. "$PY_FT" -m mypy --strict setu_classes.pyi)
    (cd test && PYTHONPATH=. MYPYPATH=. "$PY_FT" -m mypy.stubtest setu_classes)
else
    echo "skipped: mypy is not installed for $PY_FT"
fi

step "all checks passed"
