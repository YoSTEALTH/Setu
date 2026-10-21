'''Check the hand-written CPython constants in `src/capi.zig`.

Compiles a tiny C program against the headers of the interpreter running this
script and compares every constant and struct size with the Zig side. Run it with
3.14, 3.14t, 3.15 and 3.15t: the one Setu binary serves them all.

    python3.15t tools/check_abi.py
    python3.14 tools/check_abi.py

Note
    - 3.15 renumbered some slot IDs (`PySlot`). `capi.zig` names the `PyType_Slot` /
      `PyModuleDef_Slot` numbers `OLD` (and `*_old`): they are checked with the headers'
      `_Py_SLOT_COMPAT_VALUE(OLD, NEW)` picking `OLD`, on 3.15 too.
    - On 3.14 the PEP 793 constants (`PEP793_ONLY`) do not exist and are skipped.
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
# `PyType_Slot` / `PyModuleDef_Slot` numbers (3.15 renumbered their `PySlot` IDs); `*_old` too.
OLD = {'Py_mp_ass_subscript', 'Py_mp_length'}
# PEP 793 (3.15): not in the 3.14 headers.
PEP793_ONLY = {
    'slot_end', 'SLOT_OPTIONAL', 'SLOT_STATIC', 'SLOT_INTPTR', 'Py_tp_name', 'Py_tp_extra_basicsize', 'Py_tp_flags',
    'Py_mod_exec', 'Py_mod_multiple_interpreters', 'Py_mod_gil', 'Py_mod_name', 'Py_mod_doc', 'Py_mod_methods',
    'Py_mod_abi', 'PyABIInfo_STABLE', 'PyABIInfo_GIL', 'PyABIInfo_FREETHREADED', 'version_3_15',
}  # fmt: skip
PEP793 = sys.version_info >= (3, 15)
FREE_THREADED = bool(sysconfig.get_config_var('Py_GIL_DISABLED'))
# Struct sizes the Zig declarations assume.
SIZES = {
    'PyMethodDef': 32,
    'PyGetSetDef': 40,
    'PyMemberDef': 40,
    'Py_buffer': 80,
    'PyModuleDef': 120 if FREE_THREADED else 104,  # `ModuleDef(ObjectHeadFt)` / `ModuleDef(ObjectHeadGil)`
    'PyModuleDef_Slot': 16,
    'PyType_Spec': 32,
    'PyType_Slot': 16,
}
if PEP793:
    SIZES |= {'PySlot': 16, 'PyABIInfo': 12}
if PEP793 or FREE_THREADED:  # an incomplete type in the regular 3.14 (whose functions do nothing)
    SIZES['PyCriticalSection'] = 16

CONST = re.compile(r'^pub const (\w+): \w+ = (0x[0-9A-Fa-f]+|\d+|1 << \d+);', re.M)


def zig_constants():
    text = open(CAPI).read()
    return {name: eval(value) for name, value in CONST.findall(text) if PEP793 or name not in PEP793_ONLY}


def main():
    zig = zig_constants()
    include = sysconfig.get_paths()['include']
    lines = ['#include <Python.h>', '#include <stdio.h>', '#include <stdint.h>', 'int main(void) {']
    new = [n for n in zig if n not in OLD and not n.endswith('_old')]
    old = [n for n in zig if n not in new]
    for name in new + ['#old'] + old:
        if name == '#old':  # from here on, slot IDs expand to their `PyType_Slot` / `PyModuleDef_Slot` number
            lines += ['#undef _Py_SLOT_COMPAT_VALUE', '#define _Py_SLOT_COMPAT_VALUE(OLD, NEW) OLD']
            continue
        expr = ALIASES.get(name, name.removesuffix('_old'))
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
