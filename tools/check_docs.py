'''Checks `tools/setu_docs.py`: its Markdown conversion, the grouping and the `llms.txt` / `llms-full.txt` text, and
the site of the fixture `test/docs/`.

python3 tools/check_docs.py              # conversion, grouping, llms text (no extra packages)
python3 tools/check_docs.py --site       # also `mkdocs build --strict` (needs mkdocs-material,
                                         # mkdocstrings[python], mkdocs-gen-files; after `zig build develop`)
'''

import os
import subprocess
import sys

SETU = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(SETU, 'test', 'docs')
sys.path.insert(0, os.path.join(SETU, 'tools'))
import setu_docs  # noqa: E402


def fail(msg):
    raise SystemExit(f'check_docs: {msg}')


def check_convert():
    got = setu_docs.convert('Adds.\n\nExample\n    >>> add(1)\n    1\n\nNote\n    Careful.\n\n>>> bare()\n1')
    want = (
        'Adds.\n\n**Example**\n\n```pycon\n>>> add(1)\n1\n```\n\n'
        '!!! note "Note"\n\n    Careful.\n\n```pycon\n>>> bare()\n1\n```'
    )
    if got != want:
        fail(f'convert:\n{got!r}\n!=\n{want!r}')


def check_group():
    config = setu_docs.load_config(os.path.join(FIXTURE, 'pyproject.toml'))
    stub = os.path.join(FIXTURE, config['stub'])
    if not os.path.exists(stub):
        fail(f'{stub} missing: run `zig build develop` first')
    with open(stub) as f:
        members, constants = setu_docs.group(config, f.read())
    if 'Vec' not in members['classes'] or 'Vec' in members['types']:
        fail('Vec is not on the classes page')
    if not members['functions'] or not constants:
        fail('no functions or constants found')
    named = [n for names in members.values() for n in names]
    if len(named) != len(set(named)):
        fail('a name on two pages')


def check_llms():
    '''`llms.txt` / `llms-full.txt` text from the fixture's stub.'''
    config = setu_docs.load_config(os.path.join(FIXTURE, 'pyproject.toml'))
    with open(os.path.join(FIXTURE, config['stub'])) as f:
        full = setu_docs.llms_full(f.read(), config['module'])
    for text in (
        '# setu_classes\n',
        '\n## @disjoint_base class Vec\n',
        '\n### def __init__(self, x: int = ..., y: int = ...) -> None\n',
        '\n### @property def link(self) -> object\n',
        '\n### @link.setter def link(self, value: object) -> None\n',
        '\n## def vec_norm2(v: Vec) -> int\n',
        '\n```pycon\n>>> vec_norm2(Vec(3, 4))\n25\n',
        '\n## class Mode(IntEnum)\n',
        '\n## ANSWER: int\n',
    ):
        if text not in full:
            fail(f'llms-full.txt lacks {text!r}')
    index = setu_docs.llms_index(config)
    wanted = ('# setu_classes\n', '> The Python API of `setu_classes`', '- [Classes](api/classes/):', 'llms-full.txt')
    for text in wanted:
        if text not in index:
            fail(f'llms.txt lacks {text!r}')


def check_site():
    out = os.path.join(FIXTURE, 'site')
    subprocess.run(
        [sys.executable, '-m', 'mkdocs', 'build', '--strict', '-q', '-f', 'mkdocs.yml'], cwd=FIXTURE, check=True
    )
    pages = ('index.html', 'api/functions/index.html', 'api/classes/index.html', 'api/constants/index.html')
    for page in pages + ('llms.txt', 'llms-full.txt'):
        if not os.path.exists(os.path.join(out, page)):
            fail(f'site/{page} missing')


check_convert()
check_group()
check_llms()
if '--site' in sys.argv:
    check_site()
print('ok  setu_docs')
