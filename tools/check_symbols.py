'''Checks that an extension uses only what one Setu binary may: every CPython symbol it imports
must be exported by the interpreter running this script, and (3.15+) be in the stable ABI for
free-threading (abi3t, PEP 803), so the binary keeps loading on later versions.

    python3.14 tools/check_symbols.py test/setu_classes.so    # exported by 3.14?
    python3.15t tools/check_symbols.py test/setu_classes.so   # exported by 3.15t, and in abi3t?

Note
    - The extension links nothing from libpython: its symbols resolve at import, so a symbol
      missing from one version only fails there, at import. This catches it at build time.
    - The stable ABI check compiles `&symbol` against this interpreter's headers with
      `Py_TARGET_ABI3T`, which hides everything outside abi3t.
'''

import ctypes
import os
import re
import subprocess
import sys
import sysconfig
import tempfile

HEADER = '#define Py_TARGET_ABI3T 0x030f0000\n#include <Python.h>\n'


def imported(path):
    '''The CPython symbols (`Py*`, `_Py*`) the shared object `path` imports.'''
    out = subprocess.run(['nm', '-D', '--undefined-only', path], check=True, capture_output=True, text=True).stdout
    return sorted({m for m in re.findall(r'\bU (\w+)', out) if m.startswith(('Py', '_Py'))})


def not_exported(symbols):
    '''The `symbols` this interpreter does not export.'''
    return [s for s in symbols if not hasattr(ctypes.pythonapi, s)]


def not_stable(symbols):
    '''The `symbols` outside the stable ABI (abi3t) of this interpreter's headers.'''
    include = sysconfig.get_paths()['include']
    missing = []
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, 'sym.c')
        for s in symbols:
            with open(src, 'w') as f:  # `Py_TARGET_ABI3T` hides what abi3t lacks
                f.write(HEADER + f'const void *f(void) {{ return &{s}; }}\n')
            cc = ['cc', '-c', '-w', '-I', include, src, '-o', os.devnull]
            if subprocess.run(cc, stderr=subprocess.DEVNULL).returncode != 0:
                missing.append(s)
    return missing


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: check_symbols.py <extension.so>')
    symbols = imported(sys.argv[1])
    bad = [f'not exported by this interpreter: {s}' for s in not_exported(symbols)]
    stable = sys.version_info >= (3, 15)
    if stable:
        bad += [f'not in the stable ABI (abi3t): {s}' for s in not_stable(symbols)]
    for line in bad:
        print(line)
    checked = 'exported' + (' + abi3t' if stable else '')
    print(f'{len(symbols)} symbols of {sys.argv[1]} checked ({checked}): {"OK" if not bad else f"{len(bad)} bad"}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
