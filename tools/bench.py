'''Times Setu's per-call cost on `setu_classes` (the test extension): the argument shapes Liburing's hot
path uses (`bench_*` in `test/functions.zig`: `prep_recv` / `prep_send` with and without a buffer, a
buffer kept with `take()` or as `py.OwnedWritableBuffer`), plus a property, a method and `__init__`. With
`--ref`, an A/B against another commit, so a hot-path change gets a before / after without Liburing.

    python3.15 tools/bench.py                     # this tree, built `-Doptimize=fast` into a temp dir
    python3.15 tools/bench.py --ref HEAD          # A/B: HEAD (a temp worktree) vs this tree
    python3.15 tools/bench.py --ref v2026.10.21 --cpu 2 -k recv
    python3.15 tools/bench.py --so test/setu_classes.so     # an extension as built, no build
    python3.15 tools/bench.py --so a/setu_classes.so --so b/setu_classes.so   # A/B of two builds

    for v in 3.15 3.15t 3.14 3.14t; do /opt/python/$v/bin/python3 tools/bench.py --ref HEAD; done

Note
    - ns per call, the best of `--repeat` x `--rounds`; the builds take turns each round (interleaved),
      so drift (CPU clock, other load) hits both. timeit's loop is included (a few ns), the same for both.
    - Differences under ~1 ns are noise. Hot-path results also depend on LLVM's inlining: compare the
      disassembly (`objdump -d`) when a change does not show where expected.
    - A case the `--ref` build does not have (an older commit) shows `-`.
    - `--cpu N` pins this process to one CPU (as `taskset -c N`); `ZIG=...` picks the compiler.
'''

import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile
import timeit

SETU = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (label, statement); names from `setup` below
CASES = [
    ('bench_nop(v)', 'bench_nop(v)'),
    ('bench_recv(v, -1, None)', 'bench_recv(v, -1, None)'),
    ('bench_recv(v, -1, bytearray)', 'bench_recv(v, -1, ba)'),
    ('bench_recv(v, -1, bytearray, 0)', 'bench_recv(v, -1, ba, 0)'),
    ('bench_recv(v, -1, memoryview)', 'bench_recv(v, -1, mv)'),
    ('bench_recv_take(v, -1, bytearray)', 'bench_recv_take(v, -1, ba)'),
    ('bench_recv_owned(v, -1, bytearray)', 'bench_recv_owned(v, -1, ba)'),
    ('bench_send(v, -1, bytes)', 'bench_send(v, -1, by)'),
    ('o.rank = 1', 'o.rank = 1'),
    ('o.rank', 'o.rank'),
    ('v.norm2()', 'v.norm2()'),
    ('v == v', 'v == v'),
    ('v == None', 'v == None'),
    ('Vec(1, 2)', 'Vec(1, 2)'),
]


def build(tree, out):
    '''`zig build develop -Doptimize=fast` of `tree`, installed under `out`; the extension's path.'''
    zig = os.environ.get('ZIG', 'zig')
    prefix = os.path.join(out, 'zig-out')  # `develop` installs into `<prefix>/../test`
    cmd = [zig, 'build', 'develop', '-Doptimize=fast', '-p', prefix]
    subprocess.run(cmd, cwd=tree, check=True)
    return os.path.join(out, 'test', 'setu_classes.so')


def build_name(so):
    '''A short name for the extension `so`: its directory, or the one above a `test/`.'''
    d = os.path.dirname(os.path.abspath(so))
    return os.path.basename(os.path.dirname(d) if os.path.basename(d) == 'test' else d)


def load(path, tag):
    '''The extension at `path` as a module of its own (two builds load side by side).'''
    spec = importlib.util.spec_from_file_location('setu_classes', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.modules.pop('setu_classes', None)
    module.__tag__ = tag
    return module


def namespace(m):
    '''The names the statements use, from the module `m`.'''
    ns = {name: getattr(m, name) for name in dir(m) if not name.startswith('_')}
    ba = bytearray(64)
    ns.update(v=m.Vec(3, 4), o=m.Ordered(1), ba=ba, mv=memoryview(ba), by=b'x' * 64)
    return ns


def release(ns):
    '''Drops the buffers the `take` / owned cases keep.'''
    for name in ('bench_recv_take', 'bench_recv_owned'):
        if name in ns:
            ns[name](ns['v'], -1, None)


def runnable(stmt, ns):
    try:
        exec(stmt, dict(ns))
        return True
    except (NameError, AttributeError, TypeError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--ref', help='also time this git ref (built in a temp worktree), as the baseline')
    parser.add_argument(
        '--so', action='append', help='time this extension as built instead of building this tree (repeatable)'
    )
    parser.add_argument('--rounds', type=int, default=3, help='interleaved rounds (default 3)')
    parser.add_argument('--repeat', type=int, default=5, help='timings per round and case (default 5)')
    parser.add_argument('--number', type=int, default=200_000, help='calls per timing (default 200000)')
    parser.add_argument('--cpu', type=int, help='pin to this CPU')
    parser.add_argument('-k', dest='filter', default='', help='only cases containing this text')
    args = parser.parse_args()
    if args.cpu is not None:
        os.sched_setaffinity(0, {args.cpu})

    with tempfile.TemporaryDirectory(prefix='setu_bench_') as tmp:
        builds = []
        if args.ref:
            tree = os.path.join(tmp, 'ref')
            subprocess.run(['git', 'worktree', 'add', '-q', '--detach', tree, args.ref], cwd=SETU, check=True)
            try:
                builds.append((args.ref, build(tree, os.path.join(tmp, 'ref-out'))))
            finally:
                subprocess.run(['git', 'worktree', 'remove', '--force', tree], cwd=SETU, check=True)
        if args.so:
            builds += [(build_name(so), so) for so in args.so]
        else:
            builds.append(('this tree', build(SETU, os.path.join(tmp, 'new'))))
        modules = [load(path, tag) for tag, path in builds]

    spaces = [namespace(m) for m in modules]
    cases = [(label, stmt) for label, stmt in CASES if args.filter in label]
    best = {}
    for _ in range(args.rounds):
        for label, stmt in cases:
            for k, ns in enumerate(spaces):
                if not runnable(stmt, ns):
                    continue
                timer = timeit.Timer(stmt, globals=ns)
                t = min(timer.repeat(args.repeat, args.number)) / args.number * 1e9
                best[label, k] = min(best.get((label, k), t), t)
                release(ns)

    gil = 'GIL' if getattr(sys, '_is_gil_enabled', lambda: True)() else 'free-threaded'
    print(f'Python {sys.version.split()[0]} ({gil}), ns per call, best of {args.rounds} x {args.repeat}')
    width = max(len(label) for label, _ in cases)
    print(f'{"":{width}}  ' + '  '.join(f'{tag:>12}' for tag, _ in builds))
    for label, _ in cases:
        cells = [f'{best[label, k]:12.1f}' if (label, k) in best else f'{"-":>12}' for k in range(len(builds))]
        print(f'{label:{width}}  ' + '  '.join(cells))


if __name__ == '__main__':
    main()
