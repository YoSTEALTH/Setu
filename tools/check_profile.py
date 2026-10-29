'''Instructions per call of an extension's hot paths, by callgrind: each case of a cases file (a statement, as
`tools/bench.py`'s `CASES`) runs N and 2N times under valgrind, and the difference / N is what one call costs,
exactly (no timing noise), in total and per line of the extension's Zig code. `zig build profile` runs it
(`addProfileSteps` in `build.zig`) on a fast build of the extension.

    zig build profile -Doptimize=fast -Dcpu=x86_64_v3          # Setu: setu_classes + tools/bench.py's cases
    zig build profile -Doptimize=fast -Dcpu=x86_64_v3 -- -k recv --lines 8
    zig build profile ... -- --python /opt/python/3.15t/bin/python3      # that interpreter too
    zig build profile ... -- --baseline before.json            # the change per call; fails past --tolerance
    python3 tools/check_profile.py --name setu_classes --cases tools/bench.py <ext.so>

Options
    --name NAME       the name the cases import the extension by: `setu_classes`; `liburing` for a package's
                      `__init__.so` (the path then `.../liburing/__init__.so`)
    --cases FILE      the cases: a Python file with `CASES`, a list of `(label, statement)`, and `namespace(module)`,
                      the names the statements use (a dict); `tools/bench.py` is one
    --python PATH     run the cases under this interpreter too (after the one running this script), repeatable
    --number N        calls per run: the case runs N and 2N times (default 20000)
    --repeat R        runs of each size, the cheapest kept (default 2)
    -k TEXT           only the cases whose label contains TEXT
    --lines K         under each case, its K costliest lines of the extension, with their source (default 0)
    --json FILE       the result (format below); default `zig-out/profile.json`, replaced on each run (refused
                      unless it is an earlier result)
    --baseline FILE   an earlier `--json` result: each case's change per call next to it
    --tolerance N     with `--baseline`: fail when a case's total or extension cost grew by more than N instructions
                      per call (default 2)
    --jobs N          valgrind runs at a time (default: half the CPUs)

The `--json` file (instructions per call; paths as `tools/check_coverage.py` shows them: relative to the current
directory, `setu/src/args.zig` for a Zig package's file, `std/math.zig` for Zig's standard library)
    {"number": 20000,
     "interpreters": {"3.15": {"python": "/opt/python/3.15/bin/python3", "loop": 38.0,
                               "cases": {"bench_nop(v)": {"total": 151.2, "ext": 48.0,
                                                          "files": {"src/export.zig": {"total": 20.0,
                                                                                       "lines": {"88": 4.0, ...}}}}}}}},
     "sources": {"src/export.zig": "/home/me/proj/src/export.zig", ...}}
    `sources` gives each shown path's file (absolute), for the docs site's Profile page (`tools/setu_docs.py`).

Note
    - Needs valgrind (3.25 tested), which runs no AVX-512 (SIGILL, exit 132): build the extension for a CPU without
      it (`-Dcpu=x86_64_v3`). Fast (a Debug build's counts say nothing of a release) and not stripped (its line
      tables give the files and lines).
    - `total` is everything one call costs, the interpreter's part too, with the loop around it (`loop`: the cost of
      `pass`) taken out; `ext` is the part in the extension's `.so`: its own code, Setu's and std's, inlined there.
      Lines are listed for the extension only.
    - Instructions, not time: a cache miss or a mispredicted branch counts no more than an add. `tools/bench.py`
      gives the time; the two together say whether a change saves work or only moves it.
    - Each run sets `PYTHONHASHSEED=0` and disables the GC. `ext` comes out the same on every run; `total` within
      about 0.3 per call (the interpreter's memory layout). A rare one-time event in a run (millions of
      instructions, about once in 100 runs, more under load) only adds, so each size keeps its cheapest run
      (`--repeat`); a loop at or below 0 (the event in every small run) fails the run. The child runs with `-s -P`:
      no user site, no current directory on `sys.path` (a changed directory there is listed again by the import
      system, a one-time cost).
    - An inlined function's instructions count at its own source line (LLVM's line tables), so a line of
      `convert.zig` shows the cost of every call that inlined it in this case.
'''

import argparse
import concurrent.futures
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_coverage import shown  # noqa: E402

# Run under valgrind: `<so dir> <name> <cases file> <label or ''> <n>`; `''` is the loop alone (`pass`).
CHILD = '''import gc, importlib, importlib.util, itertools, sys
gc.disable()
so_dir, name, cases_path, label, n = sys.argv[1:]
sys.path.insert(0, so_dir)
module = importlib.import_module(name)
spec = importlib.util.spec_from_file_location('_setu_profile_cases', cases_path)
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)
stmt = dict(cases.CASES)[label] if label else 'pass'
ns = cases.namespace(module)
# as timeit's loop: `repeat` makes no int objects (`range` past 256 allocates one per call)
exec(compile('def _run(_it):\\n    for _ in _it:\\n        ' + stmt + '\\n', '<case>', 'exec'), ns)
ns['_run'](itertools.repeat(None, int(n)))
'''

LABEL = (
    'import sys, sysconfig; '
    'print("%d.%d" % sys.version_info[:2] + "t" * bool(sysconfig.get_config_var("Py_GIL_DISABLED")))'
)


def fail(message):
    sys.stdout.flush()
    print(f'check_profile.py: {message}', file=sys.stderr)
    raise SystemExit(1)


def options(argv):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('so', help="the extension (fast, not stripped, no AVX-512)")
    parser.add_argument('--name', required=True)
    parser.add_argument('--cases', required=True)
    parser.add_argument('--python', action='append', default=[])
    parser.add_argument('--number', type=int, default=20000)
    parser.add_argument('--repeat', type=int, default=2)
    parser.add_argument('-k', dest='filter', default='')
    parser.add_argument('--lines', type=int, default=0)
    parser.add_argument('--json', default=os.path.join('zig-out', 'profile.json'))
    parser.add_argument('--baseline')
    parser.add_argument('--tolerance', type=float, default=2.0)
    parser.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2))
    opts = parser.parse_args(argv)
    if opts.number < 1 or opts.repeat < 1:
        fail('--number and --repeat must be at least 1')
    return opts


def interpreter_label(python):
    '''The interpreter's version, `t` when free-threaded: `3.15t`, `3.14`.'''
    out = subprocess.run([python, '-c', LABEL], capture_output=True, text=True)
    if out.returncode != 0:
        fail(f'{python}: cannot run it:\n{out.stderr.strip()}')
    return out.stdout.strip()


def load_cases(path):
    '''The `(label, statement)`s of the cases file `path` (read in this process too, for the labels).'''
    spec = importlib.util.spec_from_file_location('_setu_profile_cases', path)
    if spec is None or spec.loader is None:
        fail(f'--cases {path}: not a Python file')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not isinstance(getattr(module, 'CASES', None), list) or not callable(getattr(module, 'namespace', None)):
        fail(f'--cases {path}: needs `CASES` (a list of (label, statement)) and `namespace(module)`')
    return module.CASES


def parse(path, ext):
    '''A callgrind output file (`--compress-strings=no --compress-pos=no`, events `Ir`): the total, the cost per
    object file, and the extension's (`ext`, an object path) cost per `(source file, line)`; self cost only.'''
    total, objects, lines = 0, {}, {}
    ob = fl = current = None
    skip = False  # the cost line after `calls=`: the call's inclusive cost, counted at the callee
    with open(path) as f:
        for raw in f:
            line = raw.rstrip('\n')
            if not line:
                continue
            first = line[0]
            if first.isdigit():
                if skip:
                    skip = False
                    continue
                n, _, cost = line.partition(' ')
                ir = int(cost.split()[0]) if cost else 0
                objects[ob] = objects.get(ob, 0) + ir
                if ob == ext:
                    key = (current, int(n))
                    lines[key] = lines.get(key, 0) + ir
            elif line.startswith('ob='):
                ob = line[3:]
            elif line.startswith('fl='):
                fl = current = line[3:]
            elif line.startswith(('fi=', 'fe=')):
                current = line[3:]
            elif line.startswith('fn='):
                current = fl
            elif line.startswith('calls='):
                skip = True
            elif line.startswith(('summary:', 'totals:')):
                total = int(line.split()[1])
    return total, objects, lines


def import_dir(so):
    '''The directory to import the extension `so` from: its own, the one above for a package's `__init__.so`.'''
    d = os.path.dirname(so)
    return os.path.dirname(d) if os.path.basename(so).startswith('__init__.') else d


def run_one(python, so, name, cases_path, label, n, out):
    '''One valgrind run of the case `label` (`''`: the loop alone), `n` calls; the parsed output.'''
    cmd = [
        'valgrind', '--tool=callgrind', '-q', f'--callgrind-out-file={out}',
        '--compress-strings=no', '--compress-pos=no',
        python, '-s', '-P', '-c', CHILD, import_dir(so), name, cases_path, label, str(n),
    ]  # fmt: skip
    env = {**os.environ, 'PYTHONHASHSEED': '0'}
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        why = ' (SIGILL: an AVX-512 build? use -Dcpu=x86_64_v3)' if proc.returncode in (132, -4) else ''
        fail(f'{label or "pass"} on {python}: exit {proc.returncode}{why}\n{proc.stderr.strip()}')
    return parse(out, so)


def per_call(small, large, n):
    '''Cost per call: the `large` (2n calls) run's minus the `small` (n calls) one's, over `n`.'''
    total = (large[0] - small[0]) / n
    ext = (large[1].get(EXT, 0) - small[1].get(EXT, 0)) / n
    lines = {}
    for key in large[2].keys() | small[2].keys():
        cost = (large[2].get(key, 0) - small[2].get(key, 0)) / n
        if abs(cost) >= 0.05:
            lines[key] = cost
    return total, ext, lines


EXT = None  # the extension's object path, as callgrind names it (set in `main`)


def display(path):
    '''A source path as the report shows it (`shown`, std's files as `std/...`). Normalized first: callgrind names a
    dependency's file through the project (`<project>/../setu/src/args.zig`), which is `setu/src/args.zig`, not a path
    with `..` (the docs site fetches `source/<path>`, which a browser would resolve elsewhere).'''
    path = os.path.normpath(path)
    cwd = os.getcwd() + os.sep
    if path.startswith(cwd):
        return shown(path[len(cwd) :])  # a fetched package's file in `zig-pkg/`: `setu/src/args.zig` too
    path = shown(path)
    if os.path.isabs(path) and '/std/' in path:
        return 'std/' + path.rpartition('/std/')[2]
    return path


def case_result(total, ext, lines):
    files = {}
    for (path, n), cost in lines.items():
        entry = files.setdefault(display(path or '?'), {'total': 0.0, 'lines': {}})
        entry['total'] += cost
        entry['lines'][str(n)] = round(entry['lines'].get(str(n), 0.0) + cost, 2)
    for entry in files.values():
        entry['total'] = round(entry['total'], 2)
        entry['lines'] = dict(sorted(entry['lines'].items(), key=lambda kv: int(kv[0])))
    return {
        'total': round(total, 2),
        'ext': round(ext, 2),
        'files': dict(sorted(files.items(), key=lambda kv: -kv[1]['total'])),
    }


def is_result(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and {'number', 'interpreters'} <= data.keys()


def source_line(path, n, cache={}):
    '''Line `n` of the shown path `path`, stripped ('' when not found).'''
    if path not in cache:
        real = SOURCES.get(path)
        try:
            with open(real) as f:
                cache[path] = f.read().splitlines()
        except (OSError, TypeError):
            cache[path] = []
    text = cache[path]
    return text[n - 1].strip() if 0 < n <= len(text) else ''


SOURCES = {}  # shown path -> real path


def delta(now, before):
    if before is None:
        return f'{"":>8}'
    return f'{now - before:+8.1f}'


def report(label, run, base, opts):
    '''The table of one interpreter's results.'''
    cases = run['cases']
    width = max([len(c) for c in cases] + [4])
    print(f'\n{label} ({run["python"]}): instructions per call, the loop ({run["loop"]:.1f}) taken out')
    head = f'{"case":<{width}}  {"total":>8}  {"ext":>8}'
    if base is not None:
        head += f'  {"Δtotal":>8}  {"Δext":>8}'
    print(head)
    for case, r in cases.items():
        old = (base or {}).get(case)
        text = f'{case:<{width}}  {r["total"]:8.1f}  {r["ext"]:8.1f}'
        if base is not None:
            text += f'  {delta(r["total"], old and old["total"])}  {delta(r["ext"], old and old["ext"])}'
        print(text)
        if opts.lines:
            rows = [(cost, path, int(n)) for path, f in r['files'].items() for n, cost in f['lines'].items()]
            for cost, path, n in sorted(rows, key=lambda x: (-x[0], x[1], x[2]))[: opts.lines]:
                text = source_line(path, n) if n else '(no line: code the compiler added)'
                print(f'    {cost:7.1f}  {path}:{n}  {text}')


def main():
    global EXT
    opts = options(sys.argv[1:])
    so = os.path.realpath(opts.so)
    if not os.path.isfile(so):
        fail(f'{opts.so}: no such file')
    if not shutil.which('valgrind'):
        fail('valgrind not found')
    EXT = so
    if '.' in opts.name:
        fail(f'--name {opts.name}: a top-level module or package (a package as `<name>/__init__.so`)')
    cases = [(label, stmt) for label, stmt in load_cases(opts.cases) if opts.filter in label]
    if not cases:
        fail(f'no case matches -k {opts.filter!r}')
    pythons = [sys.executable] + [shutil.which(p) or fail(f'--python {p}: not found') for p in opts.python]
    labels = [interpreter_label(p) for p in pythons]
    if len(set(labels)) < len(labels):
        fail(f'--python: the same interpreter version twice ({", ".join(labels)})')
    if os.path.exists(opts.json) and not is_result(opts.json):
        fail(f'{opts.json} is not an earlier --json result: not overwriting it')
    baseline = None
    if opts.baseline:
        if not is_result(opts.baseline):
            fail(f'--baseline {opts.baseline}: not a --json result')
        with open(opts.baseline) as f:
            baseline = json.load(f)

    n = opts.number
    cases_path = os.path.abspath(opts.cases)
    runs = [(python, label) for python in pythons for label in ['', *(c[0] for c in cases)]]
    count = len(runs) * 2 * opts.repeat
    print(f'callgrind: {count} runs ({n} and {2 * n} calls, {opts.repeat} each), {opts.jobs} at a time', flush=True)
    with tempfile.TemporaryDirectory(prefix='check_profile-') as tmp:
        with concurrent.futures.ThreadPoolExecutor(opts.jobs) as pool:
            jobs = {}
            for i, (python, label) in enumerate(runs):
                for k, calls in enumerate((n, 2 * n)):
                    for r in range(opts.repeat):
                        out = os.path.join(tmp, f'cg.{i}.{k}.{r}')
                        args = (python, so, opts.name, cases_path, label, calls, out)
                        jobs[i, k, r] = pool.submit(run_one, *args)
            # a one-time event (rare: ~4M instructions once in ~100 runs) only adds: each size's cheapest run
            parsed = {
                (i, k): min((jobs[i, k, r].result() for r in range(opts.repeat)), key=lambda p: p[0])
                for i in range(len(runs))
                for k in (0, 1)
            }

    result = {'number': n, 'interpreters': {}}
    for python, version in zip(pythons, labels):
        entry = {'python': python, 'loop': 0.0, 'cases': {}}
        for i, (p, label) in enumerate(runs):
            if p != python:
                continue
            total, ext, lines = per_call(parsed[i, 0], parsed[i, 1], n)
            if not label:
                if total <= 0:  # a one-time cost in every small run: it would be added to each case
                    why = 'run again (more --repeat, fewer --jobs)'
                    fail(f'{version}: the loop came out at {total:.1f} per call: {why}')
                entry['loop'] = round(total, 2)
                continue
            for path, _ in lines:
                if path:
                    SOURCES.setdefault(display(path), os.path.normpath(path))
            entry['cases'][label] = case_result(total - entry['loop'], ext, lines)
        result['interpreters'][version] = entry
    result['sources'] = dict(sorted(SOURCES.items()))

    os.makedirs(os.path.dirname(opts.json) or '.', exist_ok=True)
    with open(opts.json, 'w') as f:
        json.dump(result, f, indent=1)
        f.write('\n')

    grown = []
    for version, run in result['interpreters'].items():
        base = None
        if baseline is not None:
            base = baseline['interpreters'].get(version, {}).get('cases', {})
        report(version, run, base, opts)
        for case, r in run['cases'].items():
            old = (base or {}).get(case)
            if old is None:
                continue
            for key in ('total', 'ext'):
                if r[key] - old[key] > opts.tolerance:
                    grown.append(f'{version} {case}: {key} {old[key]:.1f} -> {r[key]:.1f}')
    print(f'\n{opts.json}')
    if grown:
        fail(f'grew by more than --tolerance {opts.tolerance:g} per call:\n  ' + '\n  '.join(grown))
    return 0


if __name__ == '__main__':
    sys.exit(main())
