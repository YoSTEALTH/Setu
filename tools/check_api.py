'''Checks that the test extension compiles every public runtime function of Setu: each `pub fn` in `src/*.zig`
that takes a runtime parameter (or none) must have a line in `zig build coverage`'s result. Zig compiles only
what is referenced, and kcov counts only compiled code, so a function `setu_classes` never calls is missing from
the result, not red: a new API would read 100% untested. Setu's `zig build coverage` runs it after the coverage
run (CI too).

    python3 tools/check_api.py [zig-out/coverage.json]

Note
    - Left out: a function whose parameters are all `comptime` (it runs at compile time: no code), what follows
      a file's first top-level `test` (tests and their samples), the files of the stub generator (`HOST`, a host
      program kcov does not measure), and a function with a `// comptime: <why>` line right above its
      `pub fn` (runtime parameters, but only ever called at compile time: `c.Slot.func`).
    - A line counts when it has code in the build, run or not: `-- -k ...` (some tests only) gives the same answer.
'''

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = {'src/stub.zig', 'src/stubgen.zig'}  # the stub generator's (`addStubs`), never in an extension

LITERAL = re.compile(r'\\\\.*|//.*|"(?:\\.|[^"\\])*"|' + r"'(?:\\.|[^'\\])*'")  # `\\` strings, comments, literals
PUB_FN = re.compile(r'\bpub (?:inline |export )?fn (\w+)\(')


def fail(message):
    print(f'check_api.py: {message}', file=sys.stderr)
    raise SystemExit(1)


def code_lines(text):
    '''`text`'s lines with comments, strings and characters blanked (same length), so brackets match.'''
    return [LITERAL.sub(lambda m: ' ' * len(m[0]), line) for line in text.splitlines()]


def closing(lines, row, col, open_, close):
    '''The `(row, col)` of the bracket `close` matching the `open_` at `lines[row][col]`.'''
    depth = 0
    for r in range(row, len(lines)):
        for c in range(col if r == row else 0, len(lines[r])):
            depth += {open_: 1, close: -1}.get(lines[r][c], 0)
            if depth == 0:
                return r, c
    fail(f'unbalanced {open_!r} at line {row + 1}')


def after(lines, row, col, ch):
    '''The `(row, col)` of the first `ch` from `lines[row][col]` on, or None.'''
    for r in range(row, len(lines)):
        c = lines[r].find(ch, col if r == row else 0)
        if c >= 0:
            return r, c
    return None


def top_level_params(text):
    '''The parameters in a parameter list's `text` (without the parentheses).'''
    params, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        depth += {'(': 1, '[': 1, '{': 1, ')': -1, ']': -1, '}': -1}.get(ch, 0)
        if ch == ',' and depth == 0:
            params.append(text[start:i])
            start = i + 1
    params.append(text[start:])
    return [p.strip() for p in params if p.strip()]


def runtime_functions(path):
    '''`(name, first line, last line)` (1-based) of each runtime `pub fn` with a body in the file `path`.'''
    with open(path) as f:
        source = f.read().splitlines()
    lines = code_lines('\n'.join(source))
    end = next((i for i, line in enumerate(lines) if re.match(r'test\b', line)), len(lines))
    found = []
    for row in range(end):
        m = PUB_FN.search(lines[row])
        if not m:
            continue
        if row > 0 and source[row - 1].strip().startswith('// comptime:'):
            continue
        prow, pcol = closing(lines, row, m.end() - 1, '(', ')')
        if prow == row:
            text = lines[row][m.end() : pcol]
        else:
            text = '\n'.join([lines[row][m.end() :], *lines[row + 1 : prow], lines[prow][:pcol]])
        params = top_level_params(text)
        if params and all(p.startswith('comptime ') for p in params):
            continue
        brace = after(lines, prow, pcol + 1, '{')  # the body's (the return type has none: no `struct {` there)
        if brace is None:
            fail(f'{path}:{row + 1}: `{m[1]}` has no body')
        last, _ = closing(lines, *brace, '{', '}')
        found.append((m[1], row + 1, last + 1))
    return found


def main():
    result = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out', 'coverage.json')
    try:
        with open(result) as f:
            files = json.load(f)['files']
    except (OSError, ValueError, KeyError) as e:
        fail(f'{result}: no `zig build coverage` result ({e})')
    missing = []
    for name in sorted(os.listdir(os.path.join(ROOT, 'src'))):
        path = f'src/{name}'
        if not name.endswith('.zig') or path in HOST:
            continue
        compiled = {int(n) for n in files.get(path, {}).get('hits', {})}
        for fn, first, last in runtime_functions(os.path.join(ROOT, path)):
            if not any(first <= n <= last for n in compiled):
                missing.append(f'{path}:{first}: `{fn}`')
    if missing:
        fail(
            'public runtime functions the test extension never compiles (call them from `test/`, or mark one only '
            'ever called at compile time with `// comptime: <why>` above it):\n  ' + '\n  '.join(missing)
        )
    print('check_api.py: every public runtime function is compiled into the test extension')


if __name__ == '__main__':
    main()
