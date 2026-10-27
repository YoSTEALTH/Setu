'''Checks `tools/setu_docs.py` on the fixture `test/docs/` (Setu's test extension as a site): docstring and
Markdown rendering, the grouping, the `llms.txt` / `llms-full.txt` text, every example (with the fixture's hooks),
the site it writes and the server. Standard library only; needs `zig build develop` (the extension and its stub)
and `zig` (the site's `docs.wasm`).

python3 tools/check_docs.py
'''

import ast
import html
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
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
        'parts',
        setu_docs.parts('Read it.\n\nExample #1\n    >>> 1\n    1\nExample #2\n    >>> 2\n    2\n'),
        [('', 'Read it.'), ('Example #1', '>>> 1\n1'), ('Example #2', '>>> 2\n2')],
    )
    same('example_blocks', setu_docs.example_blocks('A.\n\nExample\n    >>> 1\nExample\nExample\n    >>> 2'),
         ['>>> 1', '>>> 2'])  # fmt: skip
    same('example_blocks: numbered', setu_docs.example_blocks('A.\n\nExample #1\n    >>> 1\nExample #2\n    >>> 2'),
         ['>>> 1', '>>> 2'])  # fmt: skip
    same('convert: numbered', setu_docs.convert('Example #1\n    >>> 1\nExample #2\n    >>> 2'),
         '**Example #1**\n\n```pycon\n>>> 1\n```\n\n**Example #2**\n\n```pycon\n>>> 2\n```')  # fmt: skip
    same('sections: a repeated header keeps the first', setu_docs.sections('Note\n    a\nNote\n    b'),
         {'': '', 'Note': 'a'})  # fmt: skip
    for text, want in (
        ('(see https://en.wikipedia.org/wiki/Io_(moon).)', '(see <a href="https://en.wikipedia.org/wiki/Io_(moon)">'
         'https://en.wikipedia.org/wiki/Io_(moon)</a>.)'),
        ('https://x.org/a), b', '<a href="https://x.org/a">https://x.org/a</a>), b'),
        ('https://x.org/?a=1&b=<2>', '<a href="https://x.org/?a=1&amp;b=">https://x.org/?a=1&amp;b=</a>&lt;2&gt;'),
        ('http://. or http://', 'http://. or http://'),
    ):  # fmt: skip
        same(f'autolink {text!r}', setu_docs.autolink(text), want)
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
         '<pre class="code" data-lang="sh"><span class="fn">ls</span>  <span class="com"># list</span></pre>'
         '<pre class="code">plain &lt;x&gt;</pre>'),
        ('> q\n\n---\n\n<div>raw</div>', '<blockquote><p>q</p></blockquote><hr><div>raw</div>'),
        ('## X\n\n### Y\n\n#### Z\n\n## X', '<section class="part" id="x"><h2>X<a class="anchor" href="#x">#</a></h2>'
         '<section class="part" id="y"><h3>Y<a class="anchor" href="#y">#</a></h3><h4 id="z">Z<a class="anchor" '
         'href="#z">#</a></h4></section></section><section class="part" id="x-2"><h2>X<a class="anchor" '
         'href="#x-2">#</a></h2></section>'),
        ('```bash\nX=1 cc -o "$OUT" <file> 2>&1 | grep -v x && echo ${A}; if true; then ls; fi\n```',
         '<pre class="code" data-lang="bash">X=1 <span class="fn">cc</span> <span class="arg">-o</span> '
         '<span class="str">&quot;$OUT&quot;</span> <span class="arg">&lt;file&gt;</span> '
         '<span class="op">2&gt;&amp;1</span> <span class="op">|</span> <span class="fn">grep</span> '
         '<span class="arg">-v</span> x <span class="op">&amp;&amp;</span> <span class="fn">echo</span> '
         '<span class="bi">${A}</span><span class="op">;</span> <span class="kw">if</span> <span class="fn">true</span>'
         '<span class="op">;</span> <span class="kw">then</span> <span class="fn">ls</span><span class="op">;</span> '
         '<span class="kw">fi</span></pre>'),
        ('```console\n$ echo hi\nhi\n```', '<pre class="code" data-lang="console"><span class="pr">$ </span><span '
         'class="fn">echo</span> hi\n<span class="out">hi</span></pre>'),
        ('```c\n#include <a.h>\nint f(void) { return NULL; } // c\n```',
         '<pre class="code" data-lang="c"><span class="dec">#include</span><span class="str"> &lt;a.h&gt;</span>\n'
         '<span class="ty">int</span> <span class="fn">f</span>(<span class="ty">void</span>) { <span class="kw">'
         'return</span> <span class="con">NULL</span><span class="op">;</span> } <span class="com">// c</span></pre>'),
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
        'X <span class="op">=</span> {<span class="str">&#x27;.js&#x27;</span><span class="op">:</span> '
        '<span class="str">&#x27;utf-8&#x27;</span>}  '
        '<span class="com"># it&#x27;s</span>\n'
    ))  # fmt: skip
    code = '@functools.cache\nclass C(B):\n  def f(self, x=None):\n    return self.g(x, y=1) == x.__len__() @ z'
    same('highlight kinds', site.highlight(code), (
        '<span class="dec">@functools.cache</span>\n'
        '<span class="kw">class</span> <span class="ty">C</span>(B)<span class="op">:</span>\n'
        '  <span class="kw">def</span> <span class="fn">f</span>(<span class="slf">self</span>'
        '<span class="op">,</span> <span class="arg">x</span><span class="op">=</span><span class="con">None</span>)'
        '<span class="op">:</span>\n'
        '    <span class="kw">return</span> <span class="slf">self</span><span class="op">.</span>'
        '<span class="fn">g</span>(x<span class="op">,</span> <span class="arg">y</span><span class="op">=</span>'
        '<span class="num">1</span>) <span class="op">==</span> x<span class="op">.</span>'
        '<span class="fn">__len__</span>() <span class="op">@</span> z'
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
        '\n**Example #1**\n\n```pycon\n',  # `vec_scale`: two blocks, numbered by Setu
        '\n**Example #2**\n\n```pycon\n',
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
    blocks = setu_docs.run_target(project, 'vec_scale')
    same('Example blocks', (blocks['ok'], [s['block'] for s in blocks['steps']]), (True, [1, 1, 1, 2, 2, 2]))
    second = setu_docs.run_target(project, 'vec_scale:2')
    same('the 2nd Example block', [s['source'] for s in second['steps']][0], 'w = Vec(1, -2)')
    project.blocks = lambda name: ['>>> v = 1', '>>> v\n1']  # a block does not see the one before
    try:
        same('a new namespace per block', [s.status for s in setu_docs.run_example(project, 'x')], ['ok', 'fail'])
    finally:
        del project.blocks
    result = setu_docs.run_target(project, 'example/hi.py')
    if not result['ok'] or 'hi from setu_classes' not in result['output']:
        fail(f'example/hi.py: {result}')
    for target in ('example/forever.py', '/etc/passwd.py', 'nothing', 'vec_scale:0', 'vec_scale:3', 'vec_scale:x'):
        try:
            setu_docs.run_target(project, target)
        except LookupError:
            continue
        fail(f'run_target({target!r}) ran')


def check_site(project, out):
    site = setu_docs.Site(project)
    files = site.write(out)
    pages = ('index', 'guide', 'functions', 'classes', 'types', 'constants', 'examples')
    for name in (*(f'{p}.html' for p in pages), 'search.json', 'style.css', 'app.js', 'docs.wasm', 'llms.txt',
                 'llms-full.txt'):  # fmt: skip
        if name not in files:
            fail(f'site: no {name}')
    if (out / 'docs.wasm').read_bytes()[:4] != b'\0asm':
        fail('docs.wasm is not WebAssembly')
    for name in files:
        if name.endswith('.html') and setu_docs.pretty_html(text := (out / name).read_text()) != text:
            fail(f'{name}: `pretty_html` changes its own output')
    same(
        'pretty_html: a line break in text, then a block',
        setu_docs.pretty_html('<li>a\nb\n<ul><li>c</li></ul></li><p>d\xa0\n<b>e</b></p>'),
        '<li>a\n  b\n  <ul>\n    <li>c</li>\n  </ul>\n</li>\n<p>d\xa0\n  <b>e</b></p>\n',
    )
    same(
        'pretty_html: a `<pre>` in `.ln` lines (the first line break and a last one dropped), unless empty;'
        ' `<textarea>` content on its own line',
        setu_docs.pretty_html(
            '<div><pre class="code">a\n\n b</pre><pre hidden></pre><pre>\nc\n</pre><textarea>t</textarea></div>'
        ),
        '<div>\n  <pre class="code">\n    <span class="ln">a</span>\n    <span class="ln"></span>\n'
        '    <span class="ln"> b</span>\n  </pre>\n  <pre hidden></pre>\n  <pre>\n    <span class="ln">c</span>\n'
        '  </pre>\n  <textarea>\nt</textarea>\n</div>\n',
    )
    same(
        'pre_lines: a tag open at a line break is closed and opened again; `.ln` lines come back as they are',
        (
            setu_docs.pre_lines('x = <span class="str">\'\'\'a\nb\'\'\'</span><br>\ny'),
            setu_docs.pre_lines('\n  <span class="ln">a</span>\n  <span class="ln"> <b>b</b></span>\n'),
        ),
        (
            ['x = <span class="str">\'\'\'a</span>', '<span class="str">b\'\'\'</span><br>', 'y'],
            ['a', ' <b>b</b>'],
        ),
    )
    if '<span class="ln">' not in (out / 'guide.html').read_text():
        fail('guide.html: no `<pre>` in `.ln` lines')
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
    if 'data-target="vec_scale:2"' not in page or 'data-target="vec_scale"' in page:
        fail('functions.html: `vec_scale` without a Run per `Example` block')
    if '<a href="#seq_buffer_len">seq_<wbr>buffer_<wbr>len</a>' not in page:
        fail('functions.html: an "On this page" name does not break after `_`')
    if '<h4>Example #2</h4>' not in page or '<h4>Example</h4>' not in page:
        fail('functions.html: `vec_scale` blocks not numbered, or a single block numbered')
    if 'class="needs"' in page:
        fail('functions.html: an example without Run')
    flags = (
        '<ul class="flags described">\n'
        '            <li><code><a href="constants.html#K_ONE">K_ONE</a></code> the first <code>K_</code> constant,'
        ' linked like <code><a href="constants.html#ANSWER">ANSWER</a></code></li>\n'
        '            <li><code><a href="constants.html#K_TWO">K_TWO (default)</a></code></li>\n'
        '            <li><code>0</code> none, see <a href="https://man7.org/linux/man-pages/man2/recv.2.html" '
        'target="_blank" rel="noopener">https://man7.org/linux/man-pages/man2/recv.2.html</a>.</li>\n'
    )
    if flags not in page:
        fail('functions.html: `bench_recv` Flags: a name or URL not linked, or its `# comment` not text')
    recv = 'https://man7.org/linux/man-pages/man3/io_uring_prep_recv.3.html'
    if f'(<a href="{recv}" target="_blank" rel="noopener">{recv}</a>), converted' not in page:
        fail('functions.html: `bench_recv` URL in its description not linked, or not in a new tab')
    same('inline: a URL in backticks stays code', site.inline('`https://x.org`'), '<code>https://x.org</code>')
    same(
        'flags: names only wrap as a row',
        site.flags('O_RDONLY\nO_WRONLY'),
        '<ul class="flags"><li><code>O_RDONLY</code></li><li><code>O_WRONLY</code></li></ul>',
    )
    home = (out / 'index.html').read_text()
    if 'data-target="example/hi.py"' not in home or 'href="guide.html"' not in home:
        fail('index.html: no featured script, or no link to the guide')
    footer = 'of <a href="https://github.com/YoSTEALTH/Setu" target="_blank" rel="noopener">setu_classes</a> 0.0'
    if f'{footer} (CPython 3.14+).</footer>' not in home:
        fail('index.html: footer without the `[project]` homepage or `requires-python`, or not in a new tab')
    repo = '<a class="repo" href="https://github.com/YoSTEALTH/Setu"'
    if repo not in home or 'data-repo="YoSTEALTH/Setu"' not in home:
        fail('index.html: no repository link from the `[project]` homepage')
    app = (out / 'app.js').read_text()
    if "fetch(api + '/releases?per_page=10')" not in app or "'/releases/latest'" in app:
        fail('app.js: the latest release from `releases/latest` (a 404 in the console without releases)')
    external, target = r'<a\b[^>]*href="https?://[^>]*>', r'<a\b[^>]* target='
    if any(not re.match(target, a) for a in re.findall(external, home + guide + page)):
        fail('index.html / guide.html / functions.html: an external link that does not open a new tab')
    if re.search(target, re.sub(external, '', home + guide + page)):
        fail('index.html / guide.html / functions.html: a site link that opens a new tab')
    group = '<section class="group" id="g-Other">\n          <h2>Other<a class="anchor" href="#g-Other">#</a>'
    if group not in (out / 'constants.html').read_text():
        fail('constants.html: a group is not a `section` with an anchor, or not formatted')
    if '--accent: #1b6fb4' not in (out / 'style.css').read_text():
        fail('style.css: `css` not appended')
    icon = (project.root / 'docs/icon.svg').read_bytes()
    if 'favicon.svg' not in files or (out / 'favicon.svg').read_bytes() != icon:
        fail('site: `favicon` not copied to favicon.svg')
    if '<link rel="icon" href="favicon.svg">' not in home:
        fail('index.html: no link to `favicon`')
    project.favicon, favicon = '', project.favicon
    icon = re.search(r'<link rel="icon" href="data:image/svg\+xml,([^"]*)">', site.page('index', 'Home', ''))
    project.favicon = favicon
    if not icon or '>S</text></svg>' not in urllib.parse.unquote(html.unescape(icon[1])):
        fail('a site without `favicon`: no inline letter icon (else the browser asks for /favicon.ico, a 404)')
    icons = [urllib.parse.unquote(setu_docs.letter_icon(n)) for n in ('_x', '9', '_')]
    letters = [re.search(r'>([^<]*)</text>', i)[1] for i in icons]
    same('letter_icon: the first letter or digit, upper case', letters, ['X', '9', '?'])
    # the light theme, the system's dark and the ◐ button's dark: each sets every color
    blocks = re.findall(r':root[^{]*\{([^}]*--bg:[^}]*)\}', setu_docs.CSS)
    themes = [set(re.findall(r'(--[\w-]+):', b)) for b in blocks]
    if len(themes) != 3 or themes[0] != themes[1] or themes[0] != themes[2]:
        fail(f'CSS: the theme blocks set different variables: {[sorted(t) for t in themes]}')
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

        def run(origin, target=b'vec_norm2'):
            request = urllib.request.Request(f'{base}/api/run', target, {'Origin': origin}, method='POST')
            try:
                return json.loads(urllib.request.urlopen(request).read())
            except urllib.error.HTTPError as e:
                return e.code

        if not run(base)['ok']:
            fail('Run vec_norm2 failed')
        if [len(run(base, t).get('steps', ())) for t in (b'vec_scale:2', b'vec_scale')] != [3, 6]:
            fail('Run vec_scale:2 (an `Example` block) or vec_scale (both) failed')
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
