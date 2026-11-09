#!/usr/bin/env python3
'''Runs every Setu check, offline, and stops at the first failure.

    tool/check.py [-- PYTEST_ARGS...]

Steps
    - `zig fmt`, package paths (every file `build.zig` runs from a dependent's pinned Setu ships in
      `build.zig.zon`'s `.paths`), int casts (a `// cast:` reason on each `@intCast` / `@truncate`), ruff (also on
      the copied tools with the consumers' rules).
    - `zig build test`, the `setu-build-sync` / `setu-build-check` and `setu-guide-*` steps on the wheel fixture
      `test/wheel/`, `check_guide.py`, `zig build develop` (the one `setu_class.so` and its generated stubs, which
      `ruff check` lints with flake8-pyi: an unused import or a `__repr__` fails).
    - With each interpreter (3.15t, 3.15, 3.14t, 3.14, and 3.16t-dev / 3.16-dev when installed): `check_abi.py`,
      `zig build check-symbol`, pytest, the `cp314.cp315-abi3.abi3t.cp314t.cp315t` wheels `tool/setu_build.py`
      builds (`check_wheel.py`) and the docs site `tool/setu_doc.py` builds, serves and runs the examples of
      (`check_doc.py`).
    - `mypy --strict` (as 3.14 and 3.15) + `stubtest` on the test stubs.

Environment
    Interpreters: PY_FT=... / PY_GIL=... (3.15), PY314_FT=... / PY314_GIL=..., PY316_FT=... / PY316_GIL=... (the
    next CPython's alphas, for early warning only: skipped when missing); compiler: ZIG=...
'''

import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PY_FT = os.environ.get('PY_FT', '/opt/python/3.15t/bin/python3')
PY_GIL = os.environ.get('PY_GIL', '/opt/python/3.15/bin/python3')
PY314_FT = os.environ.get('PY314_FT', '/opt/python/3.14t/bin/python3')
PY314_GIL = os.environ.get('PY314_GIL', '/opt/python/3.14/bin/python3')
PY316_FT = os.environ.get('PY316_FT', '/opt/python/3.16t-dev/bin/python3')
PY316_GIL = os.environ.get('PY316_GIL', '/opt/python/3.16-dev/bin/python3')
ZIG = os.environ.get('ZIG', 'zig')

# Liburing and Shakti lint their copies with ruff's default rules (more than Setu's E/F/W) and format for
# Python 3.14 (`except A, B:`), so the copies must pass both without their own settings.
COPIED = ['tool/setu_build.py', 'tool/setu_doc.py']


class Failed(Exception):
    '''A check failed: its message is printed, the exit status is 1.'''


def step(title):
    '''Prints a step's bold header.'''
    print(f'\n\033[1m== {title}\033[0m', flush=True)


def run(*cmd, cwd=None, env=None):
    '''Runs `cmd` (from the repository root, or `cwd` under it); a non-zero exit raises `CalledProcessError`.'''
    full_env = None if env is None else {**os.environ, **env}
    subprocess.run(cmd, cwd=os.path.join(ROOT, cwd) if cwd else ROOT, env=full_env, check=True)


def check_package_paths():
    '''Every file build.zig runs from a dependent's pinned Setu (`setu_dep.path("...")`) must ship in the package:
    a URL-fetched Setu holds only `build.zig.zon`'s `.paths`.'''
    with open(os.path.join(ROOT, 'build.zig.zon')) as f:
        zon = f.read()
    with open(os.path.join(ROOT, 'build.zig')) as f:
        build = f.read()
    paths = re.findall(r'"([^"]+)"', zon[zon.index('.paths') :])
    used = set(re.findall(r'setu_dep(?:\.path\(|, )"([^"]+)"', build))  # also `addCopySteps`
    bad = sorted(u for u in used if not any(u == p or u.startswith(p + '/') for p in paths))
    for u in bad:
        print(f"build.zig runs `{u}` from the dependency, but build.zig.zon's .paths lacks it")
    if bad or not used:
        raise Failed('package paths')


def check_int_casts():
    '''An `@intCast` / `@truncate` needs a `// cast: <why it fits>` on its line or the line above; a value a caller
    chooses goes through `py.narrow` (or an exact parameter type) instead.'''
    cast = re.compile(r'@(intCast|truncate)\(')
    comment = re.compile(r'^\s*//')
    reason = re.compile(r'//.*cast:')
    reason_above = re.compile(r'^\s*// cast:')
    bad = False
    for pattern in ('src/*.zig', 'test/*.zig', 'tool/*.zig'):
        for path in sorted(glob.glob(pattern, root_dir=ROOT)):
            with open(os.path.join(ROOT, path)) as f:
                prev = ''
                for n, line in enumerate(f.read().splitlines(), 1):
                    if cast.search(line) and not comment.match(line) and not reason.search(line):
                        if not reason_above.match(prev):
                            print(f'{path}:{n}: cast without a `// cast:` reason (or use `py.narrow`)\n{line}')
                            bad = True
                    prev = line
    if bad:
        raise Failed('int casts')


def has_mypy(py):
    '''Whether `py` can import mypy.'''
    return subprocess.run([py, '-c', 'import mypy'], capture_output=True).returncode == 0


def main(argv):
    '''Runs every step; `argv` after an optional `--` goes to pytest.'''
    pytest_args = argv[1:] if argv[:1] == ['--'] else argv

    step('zig fmt')
    run(ZIG, 'fmt', '--check', 'src', 'test', 'tool', 'build.zig', 'build.zig.zon')

    step('package paths')
    check_package_paths()

    step('int casts')
    check_int_casts()

    step('ruff')
    run(PY_FT, '-m', 'ruff', 'check', '.')
    run(PY_FT, '-m', 'ruff', 'format', '--check', '.')

    step('ruff on the copied tools, as the consumers see them')
    common = ['--isolated', '--line-length', '120', '--target-version', 'py314']
    run(PY_FT, '-m', 'ruff', 'check', *common, *COPIED)
    run(PY_FT, '-m', 'ruff', 'format', '--check', *common, '--config', 'format.quote-style = "preserve"', *COPIED)

    step('zig build test')
    run(ZIG, 'build', 'test', '--summary', 'all')

    step('setu-build-sync + setu-build-check, setu-guide-sync + setu-guide-check (test/wheel)')
    # What a project using Setu runs: copy Setu's `tool/setu_build.py` and `doc/setu-guide.md` in, then compare.
    run(ZIG, 'build', 'setu-build-sync', 'setu-guide-sync', cwd='test/wheel')
    run(ZIG, 'build', 'setu-build-check', 'setu-guide-check', cwd='test/wheel')

    step('doc/setu-guide.md')
    run(PY_FT, 'tool/check_guide.py')

    step('zig build develop')
    run(ZIG, 'build', 'develop')  # test/setu_class.so: one binary for every interpreter below

    step('ruff check (generated stubs)')
    # gitignored, so `ruff check .` above skips it; flake8-pyi too (PYI021: the docstrings are on purpose)
    run(PY_FT, '-m', 'ruff', 'check', '--extend-select', 'PYI', '--extend-ignore', 'PYI021', 'test/setu_class.pyi')
    run(PY_FT, '-m', 'ruff', 'format', '--check', 'test/setu_class.pyi')

    pythons = [PY_FT, PY_GIL, PY314_FT, PY314_GIL]
    for py in (PY316_FT, PY316_GIL):
        if os.access(py, os.X_OK):
            pythons.append(py)
        else:
            print(f'skipped: {py} is not installed')
    for py in pythons:
        step(py)
        run(py, 'tool/check_abi.py')
        run(ZIG, 'build', 'check-symbol', f'-Dpython={py}')  # tool/check_symbol.py, as `addSymbolCheck` runs it
        run(py, '-m', 'pytest', *pytest_args)
        run(py, 'tool/check_wheel.py', '--all')  # glibc + musl, installed and imported here
        run(py, 'tool/check_wheel.py')  # `build_wheel` (PEP 517)
        run(py, 'tool/check_doc.py')  # the docs site of test/doc/: built, served, every example run

    step(f'mypy --strict + stubtest ({PY_FT})')
    if has_mypy(PY_FT):
        env = {'MYPYPATH': '.', 'PYTHONPATH': '.'}
        mypy = [PY_FT, '-m', 'mypy', '--strict']
        run(*mypy, '--python-version', '3.14', 'setu_class.pyi', cwd='test', env={'MYPYPATH': '.'})
        run(*mypy, 'setu_class.pyi', cwd='test', env=env)
        run(PY_FT, '-m', 'mypy.stubtest', 'setu_class', cwd='test', env=env)
    else:
        print(f'skipped: mypy is not installed for {PY_FT}')

    step('all checks passed')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except subprocess.CalledProcessError as e:
        print(f'\nfailed ({e.returncode}): {" ".join(map(str, e.cmd))}', file=sys.stderr)
        sys.exit(e.returncode or 1)
    except Failed as e:
        print(f'\nfailed: {e}', file=sys.stderr)
        sys.exit(1)
