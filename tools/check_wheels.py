'''Checks `tools/setu_build.py` on the fixture project `test/wheel/` (Setu's test extension
`setu_classes`): run by `tools/check.sh`, offline, with each interpreter (3.14, 3.14t, 3.15, 3.15t),
since every one of them must import the same `cp314.cp315-abi3.abi3t.cp314t.cp315t` wheel.

    python3.15t tools/check_wheels.py --all   # the release wheels: glibc + musl
    python3.14 tools/check_wheels.py          # the PEP 517 `build_wheel` hook

Note
    - `test/wheel/tools/setu_build.py` must be there first: `zig build setu-build-sync` (in
      `test/wheel/`) copies Setu's, the step projects use; `check.sh` runs it and `setu-build-check`.
    - `--all` builds the `[tool.setu_build]` targets of `test/wheel/pyproject.toml`
      (`x86_64-linux-gnu.2.28`, `x86_64-linux-musl`) and checks each wheel's name, `WHEEL` tags,
      files, `RECORD` hashes, `METADATA`, and the extension's `NEEDED` libc (`readelf -d`); the
      glibc wheel is also imported with this interpreter.
    - Without `--all`: `build_wheel` (what `pip install` calls), checked the same way and imported.
'''

import base64
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import zipfile

SETU = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(SETU, 'test', 'wheel')
SCRIPT = os.path.join(FIXTURE, 'tools', 'setu_build.py')
NAME = 'setu_classes'
VERSION = '1.2.3.post4'  # `test/wheel/build.zig.zon` `1.2.3-4`, in its PEP 440 form
# `--all`: platform tag -> the libc the extension must link
PLATFORMS = {
    'manylinux_2_28_x86_64': 'libc.so.6',
    'musllinux_1_2_x86_64': 'libc.musl-x86_64.so.1',
}
TAG = 'cp314.cp315-abi3.abi3t.cp314t.cp315t'  # every wheel: CPython 3.14+, with and without the GIL


def fail(msg):
    raise SystemExit(f'check_wheels: {msg}')


def check_wheel(path, platform):
    '''Checks the wheel at `path` (built for `platform`); returns the libraries its extension needs.'''
    name = os.path.basename(path)
    tag = f'{TAG}-{platform}'
    if name != f'{NAME}-{VERSION}-{tag}.whl':
        fail(f'{name}: expected {NAME}-{VERSION}-{tag}.whl')
    ext = f'{NAME}/{NAME}.so'  # one name every CPython 3.14+ imports
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
        tags = [  # the expanded tag set: every python x abi, nothing else
            f'Tag: {python}-{abi}-{platform}'
            for python in ('cp314', 'cp315')
            for abi in ('abi3', 'abi3t', 'cp314t', 'cp315t')
        ]
        if sorted(t for t in wheel.splitlines() if t.startswith('Tag: ')) != sorted(tags):
            fail(f'{name}: WHEEL is\n{wheel}')
        if 'Root-Is-Purelib: false' not in wheel:
            fail(f'{name}: WHEEL is\n{wheel}')
        meta = z.read(f'{dist}/METADATA').decode()
        for line in (f'Name: {NAME}', f'Version: {VERSION}', 'Requires-Python: >=3.14', 'License-Expression: CC0-1.0'):
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
    '''Installs the wheel at `path` with this interpreter's pip (which must accept its tags; offline) and
    imports the extension from there.'''
    with tempfile.TemporaryDirectory() as tmp:
        pip = [sys.executable, '-m', 'pip', 'install', '-q', '--no-index', '--no-deps', '--disable-pip-version-check']
        out = subprocess.run([*pip, '--target', tmp, path], capture_output=True, text=True)
        if out.returncode != 0:
            fail(f'{os.path.basename(path)}: pip install failed\n{out.stdout}{out.stderr}')
        code = f'import {NAME}; assert {NAME}.vec_norm2({NAME}.Vec(3, 4)) == 25; print({NAME}.__file__)'
        # `-I`: nothing from the checkout or the environment, only the installed wheel on `sys.path`.
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
    want = [f'{NAME}-{VERSION}-{TAG}-{p}.whl' for p in PLATFORMS]
    if [os.path.basename(p) for p in built] != want:
        fail(f'--all built {built}, expected {want}')
    for path, platform in zip(built, PLATFORMS):
        needed = PLATFORMS[platform]
        libs = check_wheel(path, platform)
        if needed not in libs or (platform.startswith('musl') and 'libc.so' in libs):
            fail(f'{os.path.basename(path)}: NEEDED {libs}, expected {needed}')
        if platform.startswith('manylinux'):
            check_import(path)
        print(f'ok  {os.path.basename(path)}  NEEDED {", ".join(libs)}')


def check_hook(out):
    '''The PEP 517 `build_wheel` hook, for this interpreter (a native `linux_x86_64` wheel).'''
    spec = importlib.util.spec_from_file_location('setu_build', SCRIPT)
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    if backend.get_requires_for_build_wheel() != []:
        fail('get_requires_for_build_wheel() is not []')
    for ver, want in (('2026.10.20', '2026.10.20'), ('2026.10.20-2', '2026.10.20.post2'), ('1.2.3-4', '1.2.3.post4')):
        if backend.pep440(ver) != want:
            fail(f'pep440({ver!r}) is {backend.pep440(ver)!r}, expected {want!r}')
    for ver in ('2026.10.20.3', '2026.10.20-rc.1', '2026.10.20+1', '2026.10'):
        try:
            backend.pep440(ver)
        except SystemExit:
            continue
        fail(f'pep440({ver!r}) did not raise')
    path = os.path.join(out, backend.build_wheel(out))
    libs = check_wheel(path, 'linux_x86_64')
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
