#!/usr/bin/env bash
# Runs every Setu check: zig fmt, int casts, ruff, `zig build test`, then for both 3.15 builds
# `zig build develop`, `check_abi.py` and pytest, then `mypy --strict` + `stubtest` on the test stubs.
# Interpreters: PY_FT=... / PY_GIL=...; compiler: ZIG=...
set -euo pipefail

cd "$(dirname "$0")/.."
PY_FT=${PY_FT:-/opt/python/3.15t/bin/python3}
PY_GIL=${PY_GIL:-/opt/python/3.15/bin/python3}
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

for py in "$PY_FT" "$PY_GIL"; do
    if [[ $("$py" -c 'import sysconfig; print(sysconfig.get_config_var("Py_GIL_DISABLED") or 0)') == 1 ]]; then
        flag=-Dfree-threaded=true
    else
        flag=-Dfree-threaded=false
    fi
    step "$py ($flag)"
    "$ZIG" build develop "$flag"
    "$py" tools/check_abi.py
    "$py" -m pytest "${PYTEST_ARGS[@]}"
done

step "mypy --strict + stubtest ($PY_FT)"
if "$PY_FT" -c 'import mypy' 2>/dev/null; then
    "$ZIG" build develop -Dfree-threaded=true
    (cd test && PYTHONPATH=. MYPYPATH=. "$PY_FT" -m mypy --strict setu_classes.pyi)
    (cd test && PYTHONPATH=. MYPYPATH=. "$PY_FT" -m mypy.stubtest setu_classes)
else
    echo "skipped: mypy is not installed for $PY_FT"
fi

step "all checks passed"
