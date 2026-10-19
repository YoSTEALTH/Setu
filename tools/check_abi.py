'''Check the hand-written CPython constants in `src/capi.zig`.

Compiles a tiny C program against the headers of the interpreter running this
script and compares every constant and struct size with the Zig side.

    python3.15t tools/check_abi.py
'''

import os
import re
import subprocess
import sys
import sysconfig
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPI = os.path.join(ROOT, 'src', 'capi.zig')

# Zig name -> C expression, where they differ.
ALIASES = {
    'slot_end': 'Py_slot_end',
    'SLOT_OPTIONAL': 'PySlot_OPTIONAL',
    'SLOT_STATIC': 'PySlot_STATIC',
    'SLOT_INTPTR': 'PySlot_INTPTR',
    'version_3_15': '_Py_PACK_VERSION(3, 15)',
}
# Struct sizes the Zig declarations assume.
SIZES = {'PySlot': 16, 'PyMethodDef': 32, 'PyGetSetDef': 40, 'PyABIInfo': 12, 'PyCriticalSection': 16, 'Py_buffer': 80}

CONST = re.compile(r'^pub const (\w+): \w+ = (0x[0-9A-Fa-f]+|\d+|1 << \d+);', re.M)


def zig_constants():
    text = open(CAPI).read()
    return {name: eval(value) for name, value in CONST.findall(text)}


def main():
    zig = zig_constants()
    include = sysconfig.get_paths()['include']
    lines = ['#include <Python.h>', '#include <stdio.h>', '#include <stdint.h>', 'int main(void) {']
    for name in zig:
        expr = ALIASES.get(name, name)
        lines.append(f'  printf("{name} %lld\\n", (long long)(intptr_t)({expr}));')
    for struct in SIZES:
        lines.append(f'  printf("sizeof:{struct} %zu\\n", sizeof({struct}));')
    lines.append('  return 0;\n}')

    with tempfile.TemporaryDirectory() as tmp:
        src, exe = os.path.join(tmp, 'abi.c'), os.path.join(tmp, 'abi')
        open(src, 'w').write('\n'.join(lines))
        subprocess.run(['cc', '-I', include, src, '-o', exe], check=True)
        out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout

    bad = 0
    for line in out.splitlines():
        name, value = line.rsplit(' ', 1)
        value = int(value)
        if name.startswith('sizeof:'):
            expected = SIZES[name[7:]]
        else:
            expected = zig[name]
        if value != expected:
            bad += 1
            print(f'MISMATCH {name}: headers={value} capi.zig={expected}')
    print(
        f'{len(zig)} constants, {len(SIZES)} struct sizes checked against {include}: '
        f'{"OK" if not bad else f"{bad} mismatch(es)"}'
    )
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
