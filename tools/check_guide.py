'''Checks that `docs/setu-guide.md` keeps up with the source: every class hook and setting `src/class.zig`
knows, every `Module` / `From` field, and every name `src/py.zig` exports for extensions must be mentioned.

    python3 tools/check_guide.py

Note
    - The names `INTERNAL` lists are `py.zig` exports the guide does not cover: the old method-table API
      (`exportFns`, `methodDef`, `addConstants`, ...) and low-level reference helpers.
'''

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUIDE = os.path.join(ROOT, 'docs', 'setu-guide.md')

INTERNAL = {
    'Param', 'getter', 'methodDef', 'method_end', 'getset_end', 'Constant', 'constants', 'addConstants', 'exportFns',
    'releases', 'owns', 'isInstance', 'typeData', 'notImplemented', 'newNotImplemented', 'incref', 'decref', 'none',
    'newNone', 'trueObj', 'falseObj', 'fromPythonAs', 'setString', 'Object', 'Error', 'stubgen',
}  # fmt: skip


def read(*parts):
    with open(os.path.join(ROOT, *parts)) as f:
        return f.read()


def block(text, start, end):
    '''The text between the first `start` and the next `end`.'''
    at = text.index(start)
    return text[at : text.index(end, at)]


def hooks(class_zig):
    '''The hook names of `class.zig`: the `hooks` list, the comparison, number and unary operators.'''
    names = set(re.findall(r'"(__\w+__)"', block(class_zig, 'const hooks = blk:', 'break :blk out;')))
    names |= set(re.findall(r'"(__\w+__)"', block(class_zig, 'const compare_hooks =', ';')))
    for op in re.findall(r'\.name = "(\w+)"', block(class_zig, 'pub const number_ops =', '};')):
        names |= {f'__{op}__', f'__r{op}__', f'__i{op}__'}
    names |= set(re.findall(r'"(__\w+__)"', block(class_zig, 'pub const unary_ops =', '};')))
    return names


def settings(class_zig):
    return set(re.findall(r'"(\w+)"', block(class_zig, 'pub const settings =', '};')))


def fields(zig, head):
    '''The field names of the struct declared as `head` in `zig`.'''
    body = block(zig, head, '\n};')
    return set(re.findall(r'^    (\w+):', body, re.M))


def exports(py_zig):
    return set(re.findall(r'^pub (?:const|inline fn|fn) (\w+)', py_zig, re.M)) - INTERNAL


def main():
    guide = read('docs', 'setu-guide.md')
    words = set(re.findall(r'\w+', guide))
    class_zig = read('src', 'class.zig')
    want = {
        'hook': hooks(class_zig),
        'setting': settings(class_zig),
        'Module field': fields(read('src', 'export.zig'), 'pub const Module = struct {'),
        'From field': fields(read('src', 'scan.zig'), 'pub const From = struct {'),
        'py export': exports(read('src', 'py.zig')),
    }
    missing = [f'{kind} `{n}`' for kind, names in want.items() for n in sorted(names) if n not in words]
    for m in missing:
        print(f'{GUIDE}: does not mention {m}')
    total = sum(map(len, want.values()))
    print(f'{total} names checked against docs/setu-guide.md: {"OK" if not missing else f"{len(missing)} missing"}')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
