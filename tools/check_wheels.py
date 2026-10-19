'''Checks `tools/setu_build.py` on the fixture project `test/wheel/` (Setu's test extension
`setu_classes`): run by `tools/check.sh`, offline, with each 3.15 interpreter.

    python3.15t tools/check_wheels.py --all   # the release matrix: glibc + musl wheels, both ABIs
    python3.15 tools/check_wheels.py          # the PEP 517 `build_wheel` hook, for this interpreter

Note
    - `test/wheel/tools/setu_build.py` must be there first: `zig build setu-build-sync` (in
      `test/wheel/`) copies Setu's, the step projects use; `check.sh` runs it and `setu-build-check`.
    - `--all` builds the `[tool.setu_build]` matrix of `test/wheel/pyproject.toml` (cp315t / cp315 x
      `x86_64-linux-gnu.2.28` / `x86_64-linux-musl`) and checks each wheel's name, `WHEEL` tag,
      files, `RECORD` hashes, `METADATA`, and the extension's `NEEDED` libc (`readelf -d`); the
      glibc wheel of this interpreter's ABI is also imported.
    - Without `--all`: `build_wheel` (what `pip install` calls) for this interpreter, checked the
      same way and imported.
'''

import base64
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import sysconfig
import tempfile
import zipfile

SETU = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(SETU, 'test', 'wheel')
SCRIPT = os.path.join(FIXTURE, 'tools', 'setu_build.py')
NAME = 'setu_classes'
VERSION = '1.2.3'  # `test/wheel/build.zig.zon`
# `--all`: platform tag -> (extension suffix libc, the libc the extension must link)
PLATFORMS = {
    'manylinux_2_28_x86_64': ('gnu', 'libc.so.6'),
    'musllinux_1_2_x86_64': ('musl', 'libc.musl-x86_64.so.1'),
}
ABIS = ('cp315t', 'cp315')


def fail(msg):
    raise SystemExit(f'check_wheels: {msg}')


def this_abi():
    return 'cp315t' if sysconfig.get_config_var('Py_GIL_DISABLED') else 'cp315'


def check_wheel(path, abi, platform, libc):
    '''Checks the wheel at `path` (built for `abi` / `platform`, extension suffix `libc`); returns
    the libraries its extension needs.'''
    name = os.path.basename(path)
    tag = f'cp315-{abi}-{platform}'
    if name != f'{NAME}-{VERSION}-{tag}.whl':
        fail(f'{name}: expected {NAME}-{VERSION}-{tag}.whl')
    ext = f'{NAME}/{NAME}.cpython-315{"t" if abi.endswith("t") else ""}-x86_64-linux-{libc}.so'
    dist = f'{NAME}-{VERSION}.dist-info'
    want = {
        f'{NAME}/__init__.py',
        f'{NAME}/py.typed',
        f'{NAME}/{NAME}.pyi',
        ext,
        f'{dist}/METADATA',
        f'{dist}/WHEEL',
        f'{dist}/licenses/LICENSE.txt',
        f'{dist}/RECORD',
    }
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if sorted(names) != sorted(want):
            fail(f'{name}: files {sorted(names)}, expected {sorted(want)}')
        if any(n.endswith(('.zig', '.h')) for n in names):
            fail(f'{name}: ships sources')
        wheel = z.read(f'{dist}/WHEEL').decode()
        if f'\nTag: {tag}\n' not in wheel or 'Root-Is-Purelib: false' not in wheel:
            fail(f'{name}: WHEEL is\n{wheel}')
        meta = z.read(f'{dist}/METADATA').decode()
        for line in (f'Name: {NAME}', f'Version: {VERSION}', 'Requires-Python: >=3.15', 'License-Expression: CC0-1.0'):
            if f'\n{line}\n' not in f'\n{meta}':
                fail(f'{name}: METADATA has no `{line}`')
        record = z.read(f'{dist}/RECORD').decode().splitlines()
        if sorted(r.split(',')[0] for r in record) != sorted(want):
            fail(f'{name}: RECORD lists {record}')
        for row in record:
            file, digest, size = row.split(',')
            if file == f'{dist}/RECORD':
                continue
            data = z.read(file)
            sha = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
            if digest != f'sha256={sha}' or int(size) != len(data):
                fail(f'{name}: RECORD is wrong for {file}')
        if (z.getinfo(ext).external_attr >> 16) & 0o777 != 0o755:
            fail(f'{name}: {ext} is not executable')
        with tempfile.TemporaryDirectory() as tmp:
            so = z.extract(ext, tmp)
            dynamic = subprocess.run(['readelf', '-d', so], check=True, capture_output=True, text=True).stdout
    return re.findall(r'\(NEEDED\)\s+Shared library: \[([^]]+)\]', dynamic)


def check_import(path):
    '''Imports the extension from the wheel at `path` with this interpreter.'''
    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(path) as z:
            z.extractall(tmp)
        code = f'import {NAME}; assert {NAME}.vec_norm2({NAME}.Vec(3, 4)) == 25; print({NAME}.__file__)'
        # `-I`: nothing from the checkout or the environment, only the unpacked wheel on `sys.path`.
        out = subprocess.run(
            [sys.executable, '-I', '-c', f'import sys; sys.path.insert(0, {tmp!r}); {code}'],
            capture_output=True,
            text=True,
        )
        if out.returncode != 0 or not out.stdout.startswith(tmp):
            fail(f'{os.path.basename(path)}: import failed\n{out.stdout}{out.stderr}')


def check_all(out):
    '''`setu_build.py --all`: every wheel of the fixture's `[tool.setu_build]` matrix.'''
    run = subprocess.run([sys.executable, SCRIPT, '--all', '-o', out], check=True, capture_output=True, text=True)
    built = run.stdout.split()
    want = [f'{NAME}-{VERSION}-cp315-{a}-{p}.whl' for a in ABIS for p in PLATFORMS]
    if [os.path.basename(p) for p in built] != want:
        fail(f'--all built {built}, expected {want}')
    for path in built:
        abi, platform = re.fullmatch(r'.*-cp315-(\w+)-(\w+)\.whl', path).groups()
        libc, needed = PLATFORMS[platform]
        libs = check_wheel(path, abi, platform, libc)
        if needed not in libs or (libc == 'musl' and 'libc.so' in libs):
            fail(f'{os.path.basename(path)}: NEEDED {libs}, expected {needed}')
        if abi == this_abi() and libc == 'gnu':
            check_import(path)
        print(f'ok  {os.path.basename(path)}  NEEDED {", ".join(libs)}')


def check_hook(out):
    '''The PEP 517 `build_wheel` hook, for this interpreter (a native `linux_x86_64` wheel).'''
    spec = importlib.util.spec_from_file_location('setu_build', SCRIPT)
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    if backend.get_requires_for_build_wheel() != []:
        fail('get_requires_for_build_wheel() is not []')
    path = os.path.join(out, backend.build_wheel(out))
    libs = check_wheel(path, this_abi(), 'linux_x86_64', 'gnu')
    check_import(path)
    print(f'ok  {os.path.basename(path)}  NEEDED {", ".join(libs)}  (build_wheel)')


def main():
    if not os.path.isfile(SCRIPT):
        fail(f'no {SCRIPT}: run `zig build setu-build-sync` in test/wheel/ first')
    with tempfile.TemporaryDirectory() as out:
        if sys.argv[1:] == ['--all']:
            check_all(out)
        elif sys.argv[1:] == []:
            check_hook(out)
        else:
            fail('usage: check_wheels.py [--all]')


if __name__ == '__main__':
    main()
