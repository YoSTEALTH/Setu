'''Line coverage of an extension's Zig code: pytest under kcov, with the extension loaded first, then a per-file
table. `zig build coverage` runs it (`addCoverageSteps` in `build.zig`), with the Debug build of the extension.
With `--exe`, kcov over a Zig test executable instead (`addZigTestCoverage`: `zig build coverage-zig`).

    zig build coverage                             # Setu: setu_classes + class_test.py (-Dpython=...)
    zig build coverage -- --missed -k vec          # after `--`: these options, the rest goes to pytest
    zig build coverage -- --python /opt/python/3.14/bin/python3   # 3.14's paths too, merged
    python3 tools/check_coverage.py --name setu_classes --include src --include test <ext.so> [-- pytest args]
    python3 tools/check_coverage.py --exe --include tools <test executable> [-- its args]

Options
    --exe             the path is a Zig test executable (`b.addTest`, a Debug build), run under kcov
                      with the arguments after `--`; no pytest, `--name` or `--python`
    --name NAME       the name the tests import the extension by: `setu_classes`; `liburing` for a package's
                      `__init__.so` (the path then `.../liburing/__init__.so`: a package, as normally imported);
                      `pkg.ext` inside a package (whose `from .ext import ...` then gets this build, bound to the
                      package as by a normal import)
    --include DIR     a source directory to report (kcov `--include-path`), repeatable
    --python PATH     run the tests under this interpreter too (after the one running this script), repeatable;
                      the table merges the runs: a line ran if it ran in any
    --min PERCENT     fail when the total is lower
    --json FILE       the result, merged over the interpreters (format below); default `zig-out/coverage.json`,
                      replaced on each run (refused unless it is an earlier result)
    --badge FILE      also write the merged total as a shields.io endpoint file (format below), for a README
                      badge; replaced on each run (refused unless it is an earlier badge)
    --history FILE    also keep the totals (and the project's own files') per project version (`.version` of
                      `./build.zig.zon`) in this file (format below), for the docs site's history chart: the run
                      sets its version's entry, the others stay (refused unless it is an earlier history)
    --html DIR        also keep kcov's HTML report, one per interpreter in `<DIR>/<3.15t, 3.14, ...>/index.html`;
                      replaced on each run (refused unless it is empty or an earlier report). Without it kcov writes
                      into a temporary directory, removed after the run
    --max-memory GB   stop the run (kcov and the tests under it) when together they use more memory (resident);
                      default 8
    --missed          list the lines that never ran (red), with their source
    --partial         list the lines that ran at some of their addresses only (yellow), with `hits/possible`
                      (with several interpreters: the largest `hits` of a run)

    Arguments that are none of these (and all after a `--`) go to pytest (with `--exe`: to the executable).

The `--json` file (paths as in the table: relative to the current directory, `<package>/<path>` for a Zig
package's file outside it or in its `zig-pkg/`, `setu/src/args.zig`; `hits` of `possible` addresses ran)
    {"total": {"covered": 1025, "lines": 1028},
     "interpreters": {"3.15": {"python": "/opt/python/3.15/bin/python3", "covered": 1019, "lines": 1028,
                               "files": {"src/args.zig": [94, 94], ...}}, ...},
     "files": {"src/args.zig": {"covered": 94, "lines": 94, "crc32": 1234567890, "hits": {"318": [2, 2], ...}},
               ...}}
    `crc32` is the source's CRC-32 when it was measured: the docs site flags a file changed since.
    `commit` (only when the measured files in the git work tree are as committed, so their lines are the commit's):
    the docs site links missed lines to the repository at it.
    With `--exe`, `interpreters` holds the one run, named after the executable: {"test": {"exe": "<path>", ...}}.

The `--badge` file (https://shields.io/badges/endpoint-badge; the percent rounded down, so 100% means every line)
    {"schemaVersion": 1, "label": "coverage", "message": "99.7%", "color": "brightgreen"}
    `color`: brightgreen from 95%, green 90, yellowgreen 80, yellow 70, orange 60, else red.

The `--history` file (oldest first; a run on a version already there replaces its entry in place)
    {"runs": [{"version": "2026.10.27-3", "covered": 1289, "lines": 1289, "own": [1289, 1289],
               "interpreters": {"3.15t": [1281, 1289], ...}}, ...]}
    `own`: the project's files only (no Zig package's: the Coverage page's donut), what the chart plots; an entry
    without it (written before) is charted by its total.

Note
    - Needs kcov (43 tested) and pytest (in each interpreter; not with `--exe`). Exit status: pytest's (the
      executable's) when tests fail, else 1 when the coverage check fails, else 0.
    - Zig's default Debug backend (self-hosted x86_64) pads its line tables with ops elfutils (kcov) misreads, so
      kcov would see none of the file's Zig lines: kcov runs a copy with the padding rewritten (`fix_line_tables`,
      which also ends each sequence at its last row; the build itself is not changed). Its line tables give each
      line its own code, so every red line is code that never ran. An LLVM build (`.use_llvm = true`, aarch64)
      works as is, but folds a line like `orelse return ...` into the one above (its error path shows as run) and
      marks some comment and `fn` lines red (a jump nothing takes). readelf still warns about the self-hosted
      `.debug_info` ("Bogus end-of-siblings marker", zero padding after a unit's last entry); kcov does not mind.
    - kcov records nothing from a shared library loaded once about 24 are mapped, and `import pytest` maps more,
      so the extension is loaded before pytest; importing `--name` gets it (a `sys.meta_path` finder); a test
      importing another copy fails the check.
    - Zig compiles only referenced code: a function nothing calls is not counted as missed.
    - In the report, yellow lines ran at some of their addresses only (counted as covered): mostly a generic line
      whose instance for some comptime type never ran.
    - Code between a `// coverage-off` and a `// coverage-on` comment is not counted (kcov `--exclude-region`):
      for code the tests can not run (out of memory, a lost race), so every red line is a gap.
    - The runs are merged here, not by `kcov --merge`, which counts the `coverage-off` lines again; so there is no
      merged HTML report, only one per interpreter (`--html`).
    - Child processes of the tests (a test running `python3 example.py`) do not get kcov's `libkcov_sowrapper.so`
      preload: they import the normal build of the extension, not this one, so they add no coverage, and kcov
      parsing that build's self-hosted-backend DWARF grew to 25 GB in one of Liburing's runs (OOM-killed, desktop
      apps with it). `--max-memory` stops a run that grows anyway.
'''

import glob
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import zlib


def fail(message):
    sys.stdout.flush()  # pytest's output first
    print(f'check_coverage.py: {message}', file=sys.stderr)
    raise SystemExit(1)


VALUED = ('--name', '--include', '--python', '--min', '--max-memory', '--json', '--badge', '--history', '--html')
FLAGS = ('--exe', '--missed', '--partial')


def options(argv):
    '''The options, the extension's path and the pytest arguments from `argv`.'''
    opts = {'name': None, 'include': [], 'python': [], 'min': None, 'max_memory': 8.0, 'html': None}
    opts |= {'badge': None, 'history': None}
    opts['json'] = os.path.join('zig-out', 'coverage.json')
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
            if key in ('--include', '--python'):
                opts[key[2:]].append(value)
            elif key in ('--min', '--max-memory'):
                opts[key[2:].replace('-', '_')] = float(value)
            else:
                opts[key[2:]] = value
        elif path is None and not arg.startswith('-'):
            path = arg
        else:
            pytest_args.append(arg)
    if opts['exe'] and (opts['name'] or opts['python']):
        fail('--exe runs a test executable: no --name or --python')
    if path is None or not (opts['name'] or opts['exe']) or not opts['include']:
        fail(
            'usage: check_coverage.py --name NAME --include DIR [--python PATH] [--min PERCENT] [--max-memory GB] '
            '[--json FILE] [--badge FILE] [--history FILE] [--html DIR] [--missed] [--partial] <ext.so> '
            '[pytest args]\n'
            '       check_coverage.py --exe --include DIR [...] <test executable> [its args]'
        )
    return opts, path, pytest_args


class Preloaded:
    '''A `sys.meta_path` finder and loader: the import of `name` gets `module`, already loaded. Not put in
    `sys.modules` beforehand, so the import system does the rest as for a normal import: `from . import ext` in
    package `pkg` binds `pkg.ext` then, and a package that deletes it (`del ext`, to keep it out of
    `from pkg import *`) keeps it deleted.'''

    def __init__(self, spec, module):
        self.spec, self.module = spec, module
        spec.loader = self

    def find_spec(self, fullname, path=None, target=None):
        return self.spec if fullname == self.spec.name else None

    def create_module(self, spec):
        return self.module

    def exec_module(self, module):
        pass  # ran in `run_tests`, before pytest


def run_tests(name, path, pytest_args):
    '''In the process kcov traces: loads `path` as `name`, then runs pytest; fails if the tests imported another
    copy of the extension.'''
    loader = importlib.machinery.ExtensionFileLoader(name, path)
    spec = importlib.util.spec_from_file_location(name, path, loader=loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    sys.meta_path.insert(0, Preloaded(spec, module))
    # kcov's preload, kept from child processes (see the module's Note)
    preload = [p for p in os.environ.get('LD_PRELOAD', '').replace(':', ' ').split() if 'libkcov_sowrapper' not in p]
    if preload:
        os.environ['LD_PRELOAD'] = ' '.join(preload)
    else:
        os.environ.pop('LD_PRELOAD', None)
    import pytest  # after the extension: see the module's Note

    status = pytest.main(pytest_args)
    base = os.path.basename(path)
    others = {
        m.__file__ for m in list(sys.modules.values()) if os.path.basename(getattr(m, '__file__', None) or '') == base
    } - {module.__file__}
    if others:
        fail(f'the tests imported {", ".join(sorted(others))}, not {path}: is `--name {name}` the name they import?')
    return int(status)


def uleb128(data, at):
    '''The ULEB128 at `at` in `data`, and the offset after it.

    Example
        >>> uleb128(b'\\x80\\x07\\x00', 0)
        (896, 2)
    '''
    value = shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, at


def padding_ops(n):
    '''`n` bytes of line-table padding between two sequences: `DW_LNE` 0 ops (Zig's padding) of at most 129 bytes,
    each with a one-byte length; `DW_LNS_const_add_pc` (it only moves the address) for fewer than 3 bytes.

    Example
        >>> padding_ops(5), padding_ops(2)
        (b'\\x00\\x03\\x00\\x00\\x00', b'\\x08\\x08')
    '''
    if n < 3:
        return bytes([8]) * n
    out = bytearray()
    while n > 0:
        take = min(n, 129)
        if 0 < n - take < 3:  # leave no 1 or 2 bytes, which no padding op fits
            take = n - 3
        out += bytes([0, take - 2, 0]) + bytes(take - 3)
        n -= take
    return bytes(out)


def elf_section(data, name):
    '''`(offset, size)` of the section `name` of a 64-bit little-endian ELF file, or `None`.'''
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        return None
    shoff = int.from_bytes(data[0x28:0x30], 'little')
    entsize, count, names = (int.from_bytes(data[at : at + 2], 'little') for at in (0x3A, 0x3C, 0x3E))
    headers = [data[shoff + i * entsize : shoff + (i + 1) * entsize] for i in range(count)]
    strtab = int.from_bytes(headers[names][0x18:0x20], 'little')
    for h in headers:
        start = strtab + int.from_bytes(h[0:4], 'little')
        if data[start : data.index(0, start)] == name.encode():
            return int.from_bytes(h[0x18:0x20], 'little'), int.from_bytes(h[0x20:0x28], 'little')
    return None


def fix_line_tables(data):
    '''Rewrites the `.debug_line` of the ELF file in `data` (a `bytearray`) for kcov; gives how many ops it rewrote.

    - Padding: Zig's self-hosted backend (the x86_64 Debug default) leaves room in the line tables to grow in place,
      filled with one extended op (`DW_LNE` 0) whose length is a multi-byte ULEB128, or with a length-0 one.
      elfutils reads an extended op's length as one byte, so it misreads the rest of the line program and drops it:
      kcov then sees no line of the file. LLVM's line tables have no padding.
    - Sequence ends: kcov also puts a breakpoint at a sequence's end address, one past the function's code. The
      self-hosted backend can put a `switch`'s jump table there: the breakpoint's `0xcc` overwrites an entry's low
      byte, and that case jumps into the middle of an instruction (`SIGILL`). The address ops after a sequence's
      last row become `DW_LNS_set_basic_block`s (one byte, no operand, no address change), so it ends at that row.
    '''
    section = elf_section(data, '.debug_line')
    if section is None:
        return 0
    base, size = section
    fixed, unit = 0, 0
    while unit < size:
        at = base + unit
        length, offset_size = int.from_bytes(data[at : at + 4], 'little'), 4
        at += 4
        if length == 0xFFFFFFFF:  # 64-bit DWARF
            length, offset_size = int.from_bytes(data[at : at + 8], 'little'), 8
            at += 8
        end = at + length
        version = int.from_bytes(data[at : at + 2], 'little')
        at += 2 + (2 if version >= 5 else 0)  # `address_size`, `segment_selector_size`
        header_length = int.from_bytes(data[at : at + offset_size], 'little')
        at += offset_size
        program = at + header_length
        at += 1 + (1 if version >= 4 else 0) + 3  # `minimum_instruction_length` ... `line_range`
        opcode_base = data[at]
        argument_counts = data[at + 1 : at + opcode_base]
        i, advances = program, []  # the address ops since the last row: `(start, end)`
        while i < end:
            op = data[i]
            if op == 0:  # extended: a length, then the sub-opcode and its operands
                n, j = uleb128(data, i + 1)
                if n == 0 or (data[j] == 0 and j - i > 2):  # Zig's padding, which elfutils misreads
                    data[i : j + n] = padding_ops(j + n - i)
                    fixed += 1
                elif data[j] == 1 and advances:  # `DW_LNE_end_sequence`, past the last row
                    for start, stop in advances:
                        data[start:stop] = bytes([7]) * (stop - start)
                    fixed += 1
                if n == 0 or data[j] == 1:
                    advances = []
                i = j + n
            elif op == 9:  # `DW_LNS_fixed_advance_pc`: a 2-byte operand, not a ULEB128
                advances.append((i, i + 3))
                i += 3
            elif op < opcode_base:
                start = i
                i += 1
                for _ in range(argument_counts[op - 1]):
                    i = uleb128(data, i)[1]  # a SLEB128 ends the same way
                if op in (2, 8):  # `DW_LNS_advance_pc`, `DW_LNS_const_add_pc`
                    advances.append((start, i))
                elif op == 1:  # `DW_LNS_copy`: a row
                    advances = []
            else:
                i += 1  # a special opcode: a row
                advances = []
        unit = end - base
    return fixed


def readable_copy(path, tmp):
    '''`path`, or, when its line tables need `fix_line_tables`, a fixed copy in `tmp`: of its whole directory, so a
    package's `__init__.so` stays in its package and the stub next to the extension stays next to it.'''
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    if not fix_line_tables(data):
        return path
    folder = os.path.join(tmp, 'build', os.path.basename(os.path.dirname(path)))
    shutil.copytree(os.path.dirname(path), folder, symlinks=True)
    copy = os.path.join(folder, os.path.basename(path))
    with open(copy, 'wb') as f:
        f.write(data)
    return copy


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


def merge(runs):
    '''The reports of several runs as one: a line's largest `hits` and `possible` of any run.'''
    files = {}
    for run in runs:
        for path, lines in run.items():
            merged = files.setdefault(path, {})
            for n, (hits, possible) in lines.items():
                old_hits, old_possible = merged.get(n, (0, 0))
                merged[n] = (max(old_hits, hits), max(old_possible, possible))
    return files


def counts(lines):
    '''The lines of one file that ran, and all of them.'''
    return sum(1 for hits, _ in lines.values() if hits), len(lines)


def totals(files):
    '''The lines that ran, and all lines.'''
    pairs = [counts(lines) for lines in files.values()]
    return sum(p[0] for p in pairs), sum(p[1] for p in pairs)


def row(covered, total, width, name):
    '''One line of the table: percent, lines that ran / all lines, `name`.'''
    percent = covered / total * 100 if total else 100.0
    return f'{percent:6.1f}%  {covered:>{width}} / {total:>{width}}  {name}'


def table(files):
    '''The per-file table, lowest coverage first.'''
    rows = sorted((*counts(lines), path) for path, lines in files.items())
    rows.sort(key=lambda r: r[0] / r[1] if r[1] else 1.0)
    width = max((len(str(total)) for _, total, _ in rows), default=1)
    for covered, total, path in rows:
        print(row(covered, total, width, path))


LABEL = (
    'import importlib.util, sys, sysconfig; '
    'print("%d.%d" % sys.version_info[:2] + "t" * bool(sysconfig.get_config_var("Py_GIL_DISABLED"))); '
    'print(importlib.util.find_spec("pytest") is not None)'
)


def interpreter_label(python):
    '''The interpreter's version, `t` when free-threaded: `3.15t`, `3.14`; fails without pytest.'''
    out = subprocess.run([python, '-c', LABEL], capture_output=True, text=True)
    if out.returncode != 0:
        fail(f'{python}: cannot run it:\n{out.stderr.strip()}')
    label, has_pytest = out.stdout.split()
    if has_pytest != 'True':
        fail(
            f'{python} ({label}) has no pytest: install it, or choose another interpreter (`zig build coverage '
            '-Dpython=<path>`, `--python <path>`)'
        )
    return label


def is_report(out):
    '''Whether the directory `out` holds an earlier report: kcov's, or one per interpreter.'''
    if os.path.isdir(os.path.join(out, 'kcov-merged')):
        return True
    entries = [os.path.join(out, e) for e in os.listdir(out)]
    return all(os.path.isdir(os.path.join(e, 'kcov-merged')) for e in entries)


def is_result(path):
    '''Whether the file `path` holds an earlier `--json` result.'''
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    keys = {'total', 'interpreters', 'files'}
    return isinstance(data, dict) and keys <= data.keys() <= keys | {'commit'}


def is_badge(path):
    '''Whether the file `path` holds an earlier `--badge` file.'''
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and data.get('schemaVersion') == 1 and data.get('label') == 'coverage'


BADGE_COLORS = ((95, 'brightgreen'), (90, 'green'), (80, 'yellowgreen'), (70, 'yellow'), (60, 'orange'))


def badge(covered, total):
    '''The `--badge` file's content for `covered` of `total` lines.'''
    tenths = covered * 1000 // total  # rounded down: 100% only when every line ran
    percent = tenths / 10
    color = next((c for least, c in BADGE_COLORS if percent >= least), 'red')
    message = f'{tenths // 10}%' if tenths % 10 == 0 else f'{percent:.1f}%'
    return {'schemaVersion': 1, 'label': 'coverage', 'message': message, 'color': color}


def is_history(path):
    '''Whether the file `path` holds an earlier `--history` file.'''
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and data.keys() == {'runs'} and isinstance(data['runs'], list)


def project_version():
    '''The `.version` of `build.zig.zon` in the current directory, else None.'''
    try:
        with open('build.zig.zon') as f:
            found = re.search(r'\.version\s*=\s*"([^"]+)"', f.read())
    except OSError:
        return None
    return found[1] if found else None


def history(old, version, covered, total, own, runs):
    '''The `--history` file `old` (None: a new one) with `version`'s entry set to `covered` of `total` lines, `own`
    (`(covered, lines)` of the project's own files, no package's) and the totals of `runs` (`(label, covered,
    lines)`): in place when there is one, else last.

    Example
        >>> h = history(None, '1.0', 9, 10, (5, 5), [('3.15', 9, 10)])
        >>> h = history(h, '1.1', 10, 10, (5, 5), [('3.15', 10, 10)])
        >>> history(h, '1.0', 8, 10, (4, 5), [])['runs'][0], [r['version'] for r in h['runs']]
        ({'version': '1.0', 'covered': 8, 'lines': 10, 'own': [4, 5], 'interpreters': {}}, ['1.0', '1.1'])
    '''
    entry = {'version': version, 'covered': covered, 'lines': total, 'own': list(own)}
    entry['interpreters'] = {label: [c, n] for label, c, n in runs}
    entries = [dict(e) for e in (old or {'runs': []})['runs']]
    at = next((i for i, e in enumerate(entries) if e.get('version') == version), None)
    if at is None:
        entries.append(entry)
    else:
        entries[at] = entry
    return {'runs': entries}


def history_text(data):
    '''The `--history` file's text: an entry per line, so a run's change is a one-line diff.

    Example
        >>> print(history_text({'runs': [{'version': '1.0', 'covered': 9, 'lines': 10, 'interpreters': {}}]}), end='')
        {"runs": [
         {"version": "1.0", "covered": 9, "lines": 10, "interpreters": {}}
        ]}
    '''
    lines = ',\n'.join(' ' + json.dumps(e) for e in data['runs'])
    return '{"runs": [\n' + lines + ('\n' if lines else '') + ']}\n'


def source_crc(path):
    '''The CRC-32 of the file `path` (None when it can not be read): the docs site's Coverage page flags a source
    changed since the run (`tools/setu_docs.py`).'''
    try:
        with open(path, 'rb') as f:
            return zlib.crc32(f.read())
    except OSError:
        return None


def clean_commit(paths=()):
    '''The current directory's git commit when the files `paths` (the measured sources; those outside the current
    directory, a dependency's, are left out) are as committed, else None (changes, or not a git work tree): their
    line numbers match that commit's. Other changes (`build.zig.zon`, docs) move no measured line.'''
    inside = [p for p in (os.path.relpath(p) for p in paths) if not p.startswith('..')]
    try:
        git = ['git', 'status', '--porcelain', '--untracked-files=no', '--', *inside], ['git', 'rev-parse', 'HEAD']
        changes, head = (subprocess.run(c, capture_output=True, text=True, check=True).stdout.strip() for c in git)
    except (OSError, subprocess.CalledProcessError):
        return None
    return None if changes else head


def result(runs, files, sources):
    '''The `--json` result of `runs` (`(label, origin, files)`, `origin` `{"python": ...}` or `{"exe": ...}`), their
    merge `files` and the files' `sources` (shown path -> real path); `commit` when `clean_commit` gives one.'''

    def summary(lines):
        covered, total = totals(lines)
        return {'covered': covered, 'lines': total}

    out = {
        'total': summary(files),
        'interpreters': {
            label: {
                **origin,
                **summary(run),
                'files': {shown(path): list(counts(lines)) for path, lines in sorted(run.items())},
            }
            for label, origin, run in runs
        },
        'files': {
            path: {
                **summary({path: lines}),
                'crc32': source_crc(sources[path]),
                'hits': {str(n): list(lines[n]) for n in sorted(lines)},
            }
            for path, lines in sorted(files.items())
        },
    }
    if commit := clean_commit(sources[path] for path in files):
        out['commit'] = commit
    return out


def shown(path):
    '''`path` as the table and `--json` show it: relative to the current directory when under it (kcov strips
    that), else `<package>/<path in it>` for a file of a Zig package (`.name` of the nearest `build.zig.zon` above
    it: `setu/src/args.zig`, wherever the dependency lives: a path dependency, or a fetched one in the project's
    `zig-pkg/<name>-<hash>/`), else as is.'''
    if not os.path.isabs(path):
        if not is_package(path):
            return path
        path = os.path.abspath(path)
    d = os.path.dirname(path)
    while d != os.path.dirname(d):
        zon = os.path.join(d, 'build.zig.zon')
        if os.path.isfile(zon):
            with open(zon) as f:
                name = re.search(r'\.name\s*=\s*\.(\w+)', f.read())
            return f'{name[1]}/{os.path.relpath(path, d)}' if name else path
        d = os.path.dirname(d)
    return path


def is_package(path):
    '''Whether kcov's `path` is a Zig package's file: outside the current directory (absolute), or a fetched one in
    its `zig-pkg/` (`zig-pkg/setu-<hash>/src/args.zig`), not the project's own.'''
    return os.path.isabs(path) or path.startswith('zig-pkg' + os.sep)


def listing(files, sources, title, keep):
    '''The lines `keep(hits, possible)` selects, with their source (`sources`: shown path -> real path).'''
    print(f'\n{title}:')
    for path in sorted(files):
        lines = sorted(n for n, (hits, possible) in files[path].items() if keep(hits, possible))
        if not lines:
            continue
        with open(sources[path]) as f:
            source = f.read().splitlines()
        for n in lines:
            hits, possible = files[path][n]
            text = source[n - 1].strip() if n <= len(source) else ''
            print(f'{path}:{n}: {hits}/{possible}  {text}')


PAGE = os.sysconf('SC_PAGE_SIZE')


def session_memory(sid):
    '''The resident memory (bytes) of the processes in session `sid`.'''
    total = 0
    for pid in os.listdir('/proc'):
        if not pid.isdigit():
            continue
        try:
            with open(f'/proc/{pid}/stat') as f:
                stat = f.read()
            if int(stat[stat.rindex(')') + 2 :].split()[3]) != sid:  # after `(comm)`: state, ppid, pgrp, session
                continue
            with open(f'/proc/{pid}/statm') as f:
                total += int(f.read().split()[1]) * PAGE
        except (OSError, ValueError, IndexError):  # gone meanwhile
            continue
    return total


def run_capped(cmd, max_gb):
    '''Runs `cmd` in a session of its own; kills it all when its memory passes `max_gb`. Its exit status.'''
    proc = subprocess.Popen(cmd, start_new_session=True)
    try:
        while True:
            try:
                return proc.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                used = session_memory(proc.pid)
            if used > max_gb * 2**30:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
                fail(
                    f'kcov and the tests used {used / 2**30:.1f} GB, over --max-memory {max_gb:g}: stopped. A test '
                    'whose child processes kcov traces can grow it; leave it out (`-- --deselect ...`) or raise the cap'
                )
    except BaseException:  # Ctrl-C reaches only this process: the session is not in the terminal's group
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        raise


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
    temporary = tempfile.TemporaryDirectory(prefix='check_coverage-')  # removed after the runs (or on exit)
    traced = readable_copy(path, temporary.name)  # what kcov runs: `path`, or its copy with fixed line tables
    # what kcov runs: `(label, origin for --json, command)`
    if opts['exe']:
        targets = [(os.path.basename(path), {'exe': path}, [traced])]
    else:
        pythons = [sys.executable]
        for python in opts['python']:
            found = shutil.which(python)
            if not found:
                fail(f'--python {python}: not found')
            pythons.append(found)
        labels = [interpreter_label(python) for python in pythons]
        if len(set(labels)) < len(labels):
            fail(f'--python: the same interpreter version twice ({", ".join(labels)})')
        runner = [os.path.abspath(__file__), '--run', opts['name'], traced, '--']
        targets = [(label, {'python': python}, [python, *runner]) for python, label in zip(pythons, labels)]

    out_json, html, out_badge, out_history = opts['json'], opts['html'], opts['badge'], opts['history']
    if os.path.exists(out_json) and not is_result(out_json):
        fail(f'{out_json} is not an earlier --json result: not overwriting it')
    if out_badge and os.path.exists(out_badge) and not is_badge(out_badge):
        fail(f'{out_badge} is not an earlier --badge file: not overwriting it')
    if out_history and os.path.exists(out_history) and not is_history(out_history):
        fail(f'{out_history} is not an earlier --history file: not overwriting it')
    version = project_version()
    if out_history and version is None:
        fail('--history: no `.version` in ./build.zig.zon')
    # kcov keeps every earlier run (one directory per command line) and lists them all in `index.html`.
    if html and os.path.isdir(html) and os.listdir(html):
        if not is_report(html):
            fail(f'{html} is not a kcov report directory: not overwriting it')
        shutil.rmtree(html)

    include = ','.join(os.path.abspath(d) for d in opts['include'])
    # paths relative to here (others stay absolute); `coverage-off` ... `coverage-on`: not code
    cmd = [kcov, '--clean', f'--include-path={include}', f'--strip-path={os.getcwd()}']
    cmd += ['--exclude-region=coverage-off:coverage-on']
    status, runs = 0, []
    with temporary as tmp:
        for label, origin, command in targets:
            run_out = os.path.join(html or tmp, label)
            if len(targets) > 1:
                print(f'\n{label}: {command[0]}', flush=True)
            os.makedirs(run_out, exist_ok=True)  # kcov makes the last directory only
            returncode = run_capped([*cmd, run_out, *command, *pytest_args], opts['max_memory'])
            status = status or returncode
            runs.append((label, origin, report(run_out)))

    print()
    merged = merge(r[2] for r in runs)
    sources = {shown(p): p for p in merged}
    files = {name: merged[p] for name, p in sources.items()}
    table(files)
    covered, total = totals(files)
    if total == 0:
        why = 'not a Debug build with debug info' if opts['exe'] else 'or the extension was not loaded first'
        fail(f'kcov recorded no line under {include}: wrong --include, {why}')
    os.makedirs(os.path.dirname(out_json) or '.', exist_ok=True)
    with open(out_json, 'w') as f:
        json.dump(result(runs, files, sources), f, indent=1)
        f.write('\n')
    if out_badge:
        os.makedirs(os.path.dirname(out_badge) or '.', exist_ok=True)
        with open(out_badge, 'w') as f:
            json.dump(badge(covered, total), f)
            f.write('\n')
    if out_history:
        old = None
        if os.path.exists(out_history):
            with open(out_history) as f:
                old = json.load(f)
        own = totals({name: lines for name, lines in files.items() if not is_package(sources[name])})
        new = history(old, version, covered, total, own, [(label, *totals(run)) for label, _, run in runs])
        os.makedirs(os.path.dirname(out_history) or '.', exist_ok=True)
        with open(out_history, 'w') as f:
            f.write(history_text(new))
    width = len(str(total))
    if len(runs) > 1:
        for label, _, run_files in runs:
            report_path = f'; report: {os.path.join(html, label, "index.html")}' if html else ''
            print(row(*totals(run_files), width, label + report_path))
        print(row(covered, total, width, f'total, merged; {out_json}'))
    else:
        report_path = f'; report: {os.path.join(html, runs[0][0], "index.html")}' if html else ''
        print(row(covered, total, width, f'total; {out_json}{report_path}'))
    percent = covered / total * 100
    if opts['missed']:
        listing(files, sources, 'Never ran (red)', lambda hits, possible: hits == 0)
    if opts['partial']:
        listing(files, sources, 'Ran at some addresses only (yellow)', lambda hits, possible: 0 < hits < possible)
    if status != 0:
        return status
    if opts['min'] is not None and percent < opts['min']:
        fail(f'coverage {percent:.1f}% is below --min {opts["min"]:g}%')
    return 0


if __name__ == '__main__':
    sys.exit(main())
