'''The Python sessions of `docs/setu-guide.md` (its `pycon` blocks), run with `doctest` against `setu_classes`.

The guide calls the module `pkg`, the reader's package (`from pkg import ...`, `pkg.ExtraError: ...`): each block is
read with `setu_classes` in its place.
'''

import doctest
import pathlib
import re

import pytest

GUIDE = pathlib.Path(__file__).parent.parent / 'docs' / 'setu-guide.md'
BLOCKS = [
    re.sub(r'^(>>> from |)pkg\b', r'\1setu_classes', b, flags=re.M)
    for b in re.findall(r'^```pycon\n(.*?)^```$', GUIDE.read_text(), re.M | re.S)
]


def test_blocks_found():
    assert len(BLOCKS) >= 5


@pytest.mark.parametrize('block', BLOCKS, ids=lambda b: b.splitlines()[1 if b.startswith('>>> import') else 0][4:40])
def test_session(block, tmp_path, monkeypatch):
    '''Each block in a new namespace, in an empty current directory: it imports what it uses.'''
    monkeypatch.chdir(tmp_path)
    test = doctest.DocTestParser().get_doctest(block, {}, 'setu-guide.md', str(GUIDE), 0)
    out = []
    runner = doctest.DocTestRunner(optionflags=doctest.ELLIPSIS)
    runner.run(test, out=out.append)
    assert runner.failures == 0, ''.join(out)
