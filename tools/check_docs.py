'''Checks `tools/setu_docs.py` on the fixture `test/docs/` (Setu's test extension as a site): docstring and
Markdown rendering, the grouping, the `llms.txt` / `llms-full.txt` text, every example (with the fixture's hooks),
the site it writes and the server. Standard library only; needs `zig build develop` (the extension and its stub)
and `zig` (the site's `docs.wasm`).

python3 tools/check_docs.py
'''

import ast
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

SETU = Path(__file__).resolve().parent.parent
FIXTURE = SETU / 'test' / 'docs'
sys.path.insert(0, str(SETU / 'tools'))
import setu_docs  # noqa: E402


def fail(msg):
    raise SystemExit(f'check_docs: {msg}')


def same(what, got, want):
    if got != want:
        fail(f'{what}:\n{got!r}\n!=\n{want!r}')


def check_text():
    '''The docstring helpers, as their own `Example`s say, and `convert` / `raw_docstring` for `llms-full.txt`.'''
    same('sections', setu_docs.sections('Read it.\n\nType\n    return: int\n'), {'': 'Read it.', 'Type': 'return: int'})
    same(
        'steps',
        [(s.source, s.expected) for s in setu_docs.steps('>>> x = 1\n>>> x + 1\n2')],
        [('x = 1', ''), ('x + 1', '2')],
    )
    got = setu_docs.convert('Adds.\n\nExample\n    >>> add(1)\n    1\n\nNote\n    Careful.\n\n>>> bare()\n1')
    same(
        'convert',
        got,
        'Adds.\n\n**Example**\n\n```pycon\n>>> add(1)\n1\n```\n\n**Note**\n\nCareful.\n\n```pycon\n>>> bare()\n1\n```',
    )
    tree = ast.parse(
        "'''M.\n\nNote\n    Careful.\n'''\n\n"
        "class C:\n    def f(self):\n        '''F.\n\n        Note\n            Careful.\n        '''\n"
    )
    method = tree.body[1].body[0]
    for node, want in ((tree, 'M.\n\nNote\n    Careful.\n'), (method, 'F.\n\nNote\n    Careful.\n')):
        same(f'raw_docstring({type(node).__name__})', setu_docs.raw_docstring(node), want)


def check_markdown(site):
    '''Markdown blocks and inline text, as HTML.'''
    md = (FIXTURE / 'docs' / 'guide.md').resolve()

    def render(text):
        site.ids = set()
        return site.markdown(text, md.parent)[0]

    for text, want in (
        ('# A `b`\n\ntext *em* **bold**', '<h1 id="a-b">A <code>b</code><a class="anchor" href="#a-b">#</a></h1>'
         '<p>text <em>em</em> <strong>bold</strong></p>'),
        ('[g](guide.md#x) [c](classes.md) [w](https://x.org/a.md) `vec_norm2()` `nope`',
         '<p><a href="guide.html#x">g</a> <a href="classes.html">c</a> <a href="https://x.org/a.md">w</a> '
         '<code><a href="functions.html#vec_norm2">vec_norm2()</a></code> <code>nope</code></p>'),
        ('| a | b |\n|:-|-:|\n| 1 | x \\| y |', '<table class="md"><thead><tr><th>a</th><th style="text-align: right">'
         'b</th></tr></thead><tbody><tr><td>1</td><td style="text-align: right">x | y</td></tr></tbody></table>'),
        ('- a\n  b\n  - c\n- d\n\n1. e', '<ul><li>a b<ul><li>c</li></ul></li><li>d</li></ul><ol><li>e</li></ol>'),
        ('```sh\nls  # list\n```\n\n```\nplain <x>\n```',
         '<pre class="code" data-lang="sh">ls  <span class="com"># list</span></pre>'
         '<pre class="code">plain &lt;x&gt;</pre>'),
        ('> q\n\n---\n\n<div>raw</div>', '<blockquote><p>q</p></blockquote><hr><div>raw</div>'),
        ('## X\n\n## X', '<h2 id="x">X<a class="anchor" href="#x">#</a></h2><h2 id="x-2">X<a class="anchor" '
         'href="#x-2">#</a></h2>'),
    ):  # fmt: skip
        same(f'markdown {text!r}', render(text), want)
    same('chart_number', [setu_docs.chart_number(c) for c in ('627,427', '**1.5k**', '48 ns', '-')],
         [627427.0, 1500.0, 48.0, None])  # fmt: skip
    chart = render('<!-- chart -->\n| a | x | n |\n|-|-|-:|\n| p q | - | 4 |\n| r, s | - | **2k** |\n| p | - | 0 |')
    same('chart', chart, (
        '<figure class="chart"><div class="legend"><span><i style="background: var(--s1)"></i>p</span>'
        '<span><i style="background: var(--s2)"></i>r</span></div><div class="bars">'
        '<div class="row" title="p q: 4"><span class="lbl">p q</span><span class="track">'
        '<i style="width: 0.2%; background: var(--s1)"></i></span><span class="val">4</span></div>'
        '<div class="row" title="r, s: 2k"><span class="lbl">r, s</span><span class="track">'
        '<i style="width: 100.0%; background: var(--s2)"></i></span><span class="val"><strong>2k</strong></span></div>'
        '<div class="row" title="p: 0"><span class="lbl">p</span><span class="track">'
        '<i style="width: 0.0%; background: var(--s1)"></i></span><span class="val">0</span></div>'
        '</div><figcaption>n</figcaption></figure>'
    ))  # fmt: skip
    table = '\n|a|b|\n|-|-|\n|x|1|'
    for text in ('<!-- chart -->\ntext', f'<!-- chart nope="1" -->{table}', f'<!-- chart -->{table[:-2]}y|'):
        try:
            render(text)
        except SystemExit:
            continue
        fail(f'markdown {text!r}: no error')
    code = "'''It's a doc.\n\nIt's long.'''\nX = {'.js': 'utf-8'}  # it's\n"
    same('highlight', site.highlight(code), (
        '<span class="str">&#x27;&#x27;&#x27;It&#x27;s a doc.\n\nIt&#x27;s long.&#x27;&#x27;&#x27;</span>\n'
        'X = {<span class="str">&#x27;.js&#x27;</span>: <span class="str">&#x27;utf-8&#x27;</span>}  '
        '<span class="com"># it&#x27;s</span>\n'
    ))  # fmt: skip


def check_api(project):
    '''Every exported name on one page, by the fixture's `classes`, `sources` and `default`.'''
    pages, constants = project.api()
    by_slug = {p['slug']: names for p, names in pages}
    placed = [n for names in by_slug.values() for n in names] + constants
    same('placed', sorted(placed), sorted(project.exported()))
    if by_slug['classes'] != ['Vec', 'Labeled', 'Ordered']:
        fail(f'classes page: {by_slug["classes"]}')
    if by_slug['functions'][:2] != ['vec_norm2', 'vec_scale'] or 'overridden' not in by_slug['types']:
        fail(f'functions page (`sources`, in file order): {by_slug["functions"]}')
    if 'ANSWER' not in constants or 'Vec' in constants:
        fail(f'constants: {constants}')


def check_llms(project):
    '''`llms.txt` / `llms-full.txt` text from the fixture's stub.'''
    full = setu_docs.llms_full(project.stub, 'setu_classes')
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
    index = setu_docs.llms_index(project.config)
    for text in ('# setu_classes\n', "> Setu's test extension", '- [Guide](guide.html)', '- [Classes](classes.html):',
                 'llms-full.txt'):  # fmt: skip
        if text not in index:
            fail(f'llms.txt lacks {text!r}')


def check_examples(project):
    '''Every example matches, the hooks apply, a script runs and a skipped or unknown one is refused.'''
    if setu_docs.check(project):
        fail('an example differs from its docs (above)')
    status = {s.source: s.status for s in setu_docs.run_example(project, 'buffer_len')}
    same('SKIP', status['buffer_len(None)'], 'skip')
    same('NAMESPACE', setu_docs.run_example(project, 'x', ">>> helper\n'from NAMESPACE'")[0].status, 'ok')
    same('FIXTURES', setu_docs.run_example(project, 'seq_sum', '>>> sum(numbers)\n6')[0].status, 'ok')
    same('LOOSE', setu_docs.run_example(project, 'vec_self', '>>> v = Vec()\n>>> vec_self(v) is v\nno')[1].status,
         'loose')  # fmt: skip
    for example, want in (
        ('>>> ring.submit()\n>>> sqe = 1\n>>> if x:\n>>> sqe + Vec().x + len(helper)', ['ring']),
        ('>>> import os as o\n>>> [o.sep for x in (1,)]\n>>> def f(a): return a\n>>> f(x, y)', ['x', 'y']),
        ('>>> class C:\n...     k = 1\n...     def m(self): return k\n>>> (lambda q: q + w)(await C.m)', ['k', 'w']),
        ('>>> for i in range(2): pass\n>>> (z := i)\n>>> try: pass\n... except OSError as e: e, z', []),
    ):
        same(f'needs {example!r}', project.needs('buffer_len', example), want)
    same('needs with a fixture', project.needs('seq_sum', '>>> sum(numbers)\n6'), [])
    result = setu_docs.run_target(project, 'example/hi.py')
    if not result['ok'] or 'hi from setu_classes' not in result['output']:
        fail(f'example/hi.py: {result}')
    for target in ('example/forever.py', '/etc/passwd.py', 'nothing'):
        try:
            setu_docs.run_target(project, target)
        except LookupError:
            continue
        fail(f'run_target({target!r}) ran')


def check_site(project, out):
    files = setu_docs.Site(project).write(out)
    pages = ('index', 'guide', 'functions', 'classes', 'types', 'constants', 'examples')
    for name in (*(f'{p}.html' for p in pages), 'search.json', 'style.css', 'app.js', 'docs.wasm', 'llms.txt',
                 'llms-full.txt'):  # fmt: skip
        if name not in files:
            fail(f'site: no {name}')
    if (out / 'docs.wasm').read_bytes()[:4] != b'\0asm':
        fail('docs.wasm is not WebAssembly')
    index = {e['n']: e for e in json.loads((out / 'search.json').read_text())}
    same(
        'search vec_norm2',
        (index['vec_norm2']['h'], index['vec_norm2']['p']),
        ('functions.html#vec_norm2', 'Functions'),
    )
    same('search Vec.norm2', index['Vec.norm2']['h'], 'classes.html#Vec.norm2')
    same('search ANSWER', index['ANSWER']['h'], 'constants.html#ANSWER')
    page = (out / 'functions.html').read_text()
    for text in ('id="vec_norm2"', 'data-target="vec_norm2"', '(v: Vec) -&gt; int', 'content="notranslate"'):
        if text not in page:
            fail(f'functions.html lacks {text!r}')
    guide = (out / 'guide.html').read_text()
    if (
        'notranslate' in guide
        or 'href="https://github.com/YoSTEALTH/Setu/edit/dev/test/docs/docs/guide.md"' not in guide
    ):
        fail('guide.html: an API meta, or no Edit link')
    if 'title="Liburing, 3.15 --tmpl: 501k"' not in guide or 'background: var(--s3)' not in guide:
        fail('guide.html: no chart')
    if 'class="needs"' in page:
        fail('functions.html: an example without Run')
    home = (out / 'index.html').read_text()
    if 'data-target="example/hi.py"' not in home or 'href="guide.html"' not in home:
        fail('index.html: no featured script, or no link to the guide')
    if '--accent: #1b6fb4' not in (out / 'style.css').read_text():
        fail('style.css: `css` not appended')
    examples = (out / 'examples.html').read_text()
    if 'data-target="example/forever.py"' in examples or 'data-target="example/hi.py"' not in examples:
        fail('examples.html: `scripts_skip` not applied')


def check_server(project):
    '''`serve` on a free port (building the fixture's `site/` if missing): ping, a page, Run, and a cross-origin
    Run refused.'''
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    cmd = [sys.executable, str(SETU / 'tools' / 'setu_docs.py'), '--config', str(project.pyproject), 'serve',
           '--port', str(port)]  # fmt: skip
    env = {**os.environ, 'PYTHONPATH': os.pathsep.join(project.path)}
    server = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    base = f'http://127.0.0.1:{port}'
    try:
        for _ in range(100):
            try:
                ping = json.loads(urllib.request.urlopen(f'{base}/api/ping').read())
                break
            except urllib.error.URLError:
                time.sleep(0.1)
        else:
            fail('the server did not start')
        same('ping', ping['module'], 'setu_classes')
        if b'id="vec_norm2"' not in urllib.request.urlopen(f'{base}/functions.html').read():
            fail('the server does not serve the site')

        def run(origin):
            request = urllib.request.Request(f'{base}/api/run', b'vec_norm2', {'Origin': origin}, method='POST')
            try:
                return json.loads(urllib.request.urlopen(request).read())
            except urllib.error.HTTPError as e:
                return e.code

        if not run(base)['ok']:
            fail('Run vec_norm2 failed')
        same('cross-origin Run', run('http://example.com'), 403)
    finally:
        server.terminate()
        server.wait()


if not (FIXTURE / setu_docs.load_config(FIXTURE / 'pyproject.toml')['stub']).exists():
    fail('the stub is missing: run `zig build develop` first')
project = setu_docs.Project(FIXTURE / 'pyproject.toml')
check_text()
check_api(project)
check_markdown(setu_docs.Site(project))
check_llms(project)
check_examples(project)
with tempfile.TemporaryDirectory() as tmp:
    check_site(project, Path(tmp))
check_server(project)
print('ok  setu_docs')
