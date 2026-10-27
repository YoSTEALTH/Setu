'''Line coverage of an extension's Zig code: pytest under kcov, with the extension loaded first, then a per-file
table. `zig build coverage` runs it (`addCoverageSteps` in `build.zig`), with an LLVM Debug build of the extension.

    zig build coverage                             # Setu: setu_classes + class_test.py (-Dpython=...)
    zig build coverage -- --missed -k vec          # after `--`: these options, the rest goes to pytest
    python3 tools/check_coverage.py --name setu_classes --include src --include test <ext.so> [-- pytest args]

Options
    --name NAME       the name the tests import the extension by: `setu_classes`, `liburing.liburing` (inside a
                      package, whose `from .liburing import ...` then gets this build)
    --include DIR     a source directory to report (kcov `--include-path`), repeatable
    --min PERCENT     fail when the total is lower
    --out DIR         kcov's report (`index.html`, `codecov.json`, ...); default `zig-out/coverage`, replaced on
                      each run (refused unless it is empty or an earlier report)
    --missed          list the lines that never ran (red), with their source
    --partial         list the lines that ran at some of their addresses only (yellow), with `hits/possible`

    Arguments that are none of these (and all after a `--`) go to pytest.

Note
    - Needs kcov (43 tested) and readelf. Exit status: pytest's when tests fail, else 1 when the coverage check
      fails, else 0.
    - Zig's default Debug backend (self-hosted x86_64) writes `.debug_info` elfutils rejects ("Bogus
      end-of-siblings marker"), so kcov sees none of the extension's Zig lines: build it with `.use_llvm = true`.
      readelf's warnings fail the check before kcov runs.
    - kcov records nothing from a shared library loaded once about 24 are mapped, and `import pytest` maps more,
      so the extension is loaded before pytest, under `--name` (`sys.modules`); a test importing another copy fails
      the check.
    - Zig compiles only referenced code: a function nothing calls is not counted as missed.
    - In the report, yellow lines ran at some of their addresses only (counted as covered): mostly a generic line
      whose instance for some comptime type never ran.
    - Code between a `// coverage-off` and a `// coverage-on` comment is not counted (kcov `--exclude-region`):
      for code the tests are not meant to run, so every red line is a gap.
'''

import glob
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys


def fail(message):
    sys.stdout.flush()  # pytest's output first
    print(f'check_coverage.py: {message}', file=sys.stderr)
    raise SystemExit(1)


VALUED = ('--name', '--include', '--min', '--out')
FLAGS = ('--missed', '--partial')


def options(argv):
    '''The options, the extension's path and the pytest arguments from `argv`.'''
    opts = {'name': None, 'include': [], 'min': None, 'out': os.path.join('zig-out', 'coverage')}
    opts |= {flag[2:]: False for flag in FLAGS}
    path, pytest_args = None, []
    args = iter(argv)
    for arg in args:
        key, eq, value = arg.partition('=')
        if arg == '--':
            pytest_args += args
        elif arg in FLAGS:
            opts[arg[2:]] = True
        elif key in VALUED:
            if not eq:
                value = next(args, None)
                if value is None:
                    fail(f'{key} needs a value')
            if key == '--include':
                opts['include'].append(value)
            elif key == '--min':
                opts['min'] = float(value)
            else:
                opts[key[2:]] = value
        elif path is None and not arg.startswith('-'):
            path = arg
        else:
            pytest_args.append(arg)
    if path is None or not opts['name'] or not opts['include']:
        fail(
            'usage: check_coverage.py --name NAME --include DIR [--min PERCENT] [--out DIR] [--missed] [--partial] '
            '<ext.so> [pytest args]'
        )
    return opts, path, pytest_args


def run_tests(name, path, pytest_args):
    '''In the process kcov traces: loads `path` as `name`, then runs pytest; fails if the tests imported another
    copy of the extension.'''
    loader = importlib.machinery.ExtensionFileLoader(name, path)
    spec = importlib.util.spec_from_file_location(name, path, loader=loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    loader.exec_module(module)
    import pytest  # after the extension: see the module's Note

    status = pytest.main(pytest_args)
    base = os.path.basename(path)
    others = {
        m.__file__ for m in list(sys.modules.values()) if os.path.basename(getattr(m, '__file__', None) or '') == base
    } - {module.__file__}
    if others:
        fail(f'the tests imported {", ".join(sorted(others))}, not {path}: is `--name {name}` the name they import?')
    return int(status)


def check_debug_info(path):
    '''Fails unless readelf reads the `.debug_info` of `path` without warnings.'''
    if not shutil.which('readelf'):
        fail('readelf not found (binutils)')
    out = subprocess.run(['readelf', '--debug-dump=info', path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    warnings = [line for line in out.stderr.decode(errors='replace').splitlines() if line.strip()]
    if out.returncode != 0 or warnings:
        fail(
            f'{path}: readelf cannot read its .debug_info, so kcov would see no Zig line:\n  '
            + '\n  '.join(warnings[:3])
            + '\nbuild the extension in Debug with `.use_llvm = true` (`addCoverageSteps` does)'
        )


def report(out):
    '''kcov's `codecov.json` in `out` (the run's, not the merged one): `{path: {line: (hits, possible)}}`.'''
    # `<command>` is a symlink to `<command>.<hash>`
    found = {os.path.realpath(p) for p in glob.glob(os.path.join(out, '*', 'codecov.json'))}
    found = [p for p in found if os.sep + 'kcov-merged' + os.sep not in p]
    if len(found) != 1:
        fail(f'kcov wrote {len(found)} codecov.json in {out}, not 1')
    with open(found[0]) as f:
        data = json.load(f)['coverage']
    return {
        path: {int(n): tuple(int(x) for x in hits.split('/')) for n, hits in lines.items()}
        for path, lines in data.items()
    }


def table(files):
    '''The per-file table, lowest coverage first, and the totals.'''
    rows = []
    for path, lines in files.items():
        covered, total = sum(1 for hits, _ in lines.values() if hits), len(lines)
        rows.append((covered / total * 100 if total else 100.0, covered, total, path))
    rows.sort()
    width = max((len(str(total)) for _, _, total, _ in rows), default=1)
    for percent, covered, total, path in rows:
        print(f'{percent:6.1f}%  {covered:>{width}} / {total:>{width}}  {path}')
    return sum(r[1] for r in rows), sum(r[2] for r in rows)


def listing(files, title, keep):
    '''The lines `keep(hits, possible)` selects, with their source.'''
    print(f'\n{title}:')
    for path in sorted(files):
        lines = sorted(n for n, (hits, possible) in files[path].items() if keep(hits, possible))
        if not lines:
            continue
        with open(path) as f:
            source = f.read().splitlines()
        for n in lines:
            hits, possible = files[path][n]
            text = source[n - 1].strip() if n <= len(source) else ''
            print(f'{path}:{n}: {hits}/{possible}  {text}')


def main():
    argv = sys.argv[1:]
    if argv[:1] == ['--run']:  # inside kcov: `--run <name> <path> -- <pytest args>`
        return run_tests(argv[1], argv[2], argv[4:])
    opts, path, pytest_args = options(argv)
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        fail(f'{path}: no such file')
    kcov = shutil.which('kcov')
    if not kcov:
        fail('kcov not found (Ubuntu 25.04+ / Arch: the `kcov` package)')
    check_debug_info(path)

    # kcov keeps every earlier run (one directory per command line) and merges them all into `index.html`.
    out = opts['out']
    if os.path.isdir(out) and os.listdir(out):
        if not os.path.isdir(os.path.join(out, 'kcov-merged')):
            fail(f'{out} is not a kcov report directory: not overwriting it')
        shutil.rmtree(out)

    include = ','.join(os.path.abspath(d) for d in opts['include'])
    # paths relative to here (others stay absolute); `coverage-off` ... `coverage-on`: not code
    cmd = [kcov, '--clean', f'--include-path={include}', f'--strip-path={os.getcwd()}']
    cmd += ['--exclude-region=coverage-off:coverage-on', opts['out'], sys.executable, os.path.abspath(__file__)]
    status = subprocess.run([*cmd, '--run', opts['name'], path, '--', *pytest_args]).returncode

    print()
    files = report(opts['out'])
    covered, total = table(files)
    if total == 0:
        fail(f'kcov recorded no line under {include}: wrong --include, or the extension was not loaded first')
    percent = covered / total * 100
    print(f'{percent:6.1f}%  {covered} / {total}  total; report: {os.path.join(opts["out"], "index.html")}')
    if opts['missed']:
        listing(files, 'Never ran (red)', lambda hits, possible: hits == 0)
    if opts['partial']:
        listing(files, 'Ran at some addresses only (yellow)', lambda hits, possible: 0 < hits < possible)
    if status != 0:
        return status
    if opts['min'] is not None and percent < opts['min']:
        fail(f'coverage {percent:.1f}% is below --min {opts["min"]:g}%')
    return 0


if __name__ == '__main__':
    sys.exit(main())
