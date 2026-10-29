'''Checks `tools/setu_docs.py` on the fixture `test/docs/` (Setu's test extension as a site): docstring and
Markdown rendering, the grouping, the `llms.txt` / `llms-full.txt` text, every example (with the fixture's hooks),
the site it writes and the server. Standard library only; needs `zig build develop` (the extension and its stub)
and `zig` (the site's `docs.wasm`).

python3 tools/check_docs.py
'''

import ast
import html
import html.parser
import json
import os
import pathlib
import re
import shutil
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
BOX, COPY = '<div class="codebox">', '<button class="copy" type="button" hidden>Copy</button></div>'  # `code_box`
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
        # a bare URL is a link (its trailing `.` text), not in a link's text or in code
        ('Docs: https://x.org/a. **https://x.org/b** [https://x.org/c](https://x.org/d) `https://x.org/e`',
         '<p>Docs: <a href="https://x.org/a">https://x.org/a</a>. <strong><a href="https://x.org/b">https://x.org/b'
         '</a></strong> <a href="https://x.org/d">https://x.org/c</a> <code>https://x.org/e</code></p>'),
        # a badge: brackets in the image's URL (balanced) stay in it
        ('[![abi](https://x.io/abi-abi3t%20(PEP%20803)-blue)](https://p.org/a)',
         '<p><a href="https://p.org/a"><img src="https://x.io/abi-abi3t%20(PEP%20803)-blue" alt="abi"></a></p>'),
        ('```sh\nls  # list\n```\n\n```\nplain <x>\n```',
         BOX + '<pre class="code" data-lang="sh"><span class="fn">ls</span>  <span class="com"># list</span></pre>'
         + COPY + BOX + '<pre class="code">plain &lt;x&gt;</pre>' + COPY),
        ('> q\n\n---\n\n<div>raw</div>', '<blockquote><p>q</p></blockquote><hr><div>raw</div>'),
        ('## X\n\n### Y\n\n#### Z\n\n## X', '<section class="part" id="x"><h2>X<a class="anchor" href="#x">#</a></h2>'
         '<section class="part" id="y"><h3>Y<a class="anchor" href="#y">#</a></h3><h4 id="z">Z<a class="anchor" '
         'href="#z">#</a></h4></section></section><section class="part" id="x-2"><h2>X<a class="anchor" '
         'href="#x-2">#</a></h2></section>'),
        ('```bash\nX=1 cc -o "$OUT" <file> 2>&1 | grep -v x && echo ${A}; if true; then ls; fi\n```',
         BOX + '<pre class="code" data-lang="bash">X=1 <span class="fn">cc</span> <span class="arg">-o</span> '
         '<span class="str">&quot;$OUT&quot;</span> <span class="arg">&lt;file&gt;</span> '
         '<span class="op">2&gt;&amp;1</span> <span class="op">|</span> <span class="fn">grep</span> '
         '<span class="arg">-v</span> x <span class="op">&amp;&amp;</span> <span class="fn">echo</span> '
         '<span class="bi">${A}</span><span class="op">;</span> <span class="kw">if</span> <span class="fn">true</span>'
         '<span class="op">;</span> <span class="kw">then</span> <span class="fn">ls</span><span class="op">;</span> '
         '<span class="kw">fi</span></pre>' + COPY),
        ('```console\n$ echo hi\nhi\n```', BOX + '<pre class="code" data-lang="console"><span class="pr">$ </span>'
         '<span class="fn">echo</span> hi\n<span class="out">hi</span></pre>' + COPY),
        ('```c\n#include <a.h>\nint f(void) { return NULL; } // c\n```',
         BOX + '<pre class="code" data-lang="c"><span class="dec">#include</span><span class="str"> &lt;a.h&gt;'
         '</span>\n<span class="ty">int</span> <span class="fn">f</span>(<span class="ty">void</span>) { <span '
         'class="kw">return</span> <span class="con">NULL</span><span class="op">;</span> } <span class="com">// c'
         '</span></pre>' + COPY),
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


def check_split(site, out, files):
    '''`split = true` (`docs/tour.md`): a page per `##` chapter, listed in the nav under the page, with the text before
    the first chapter and a list of them on the page; Previous / Next links; a link to a heading goes to its chapter.'''
    same(
        'chapters: a code block `##` line is no chapter, headings one level up',
        setu_docs.chapters('# T\nHi.\n## 1. A\n```\n## x\n```\n### B\n## 2. C\n'),
        ('# T\nHi.', [('1. A', '# 1. A\n```\n## x\n```\n## B'), ('2. C', '# 2. C')]),
    )
    for name in ('tour.html', 'tour-first-steps.html', 'tour-more.html'):
        if name not in files:
            fail(f'split: no {name}')
    tour, first, more = ((out / f'{n}.html').read_text() for n in ('tour', 'tour-first-steps', 'tour-more'))
    nav = '<a href="tour-first-steps.html" class="sub">1. First steps</a>'
    if nav not in tour or '<a href="tour-more.html" class="sub on">2. More</a>' not in more:
        fail('split: a chapter not in the nav under its page, or not `on` on its own')
    if 'this text stays here' not in tour or '<ul class="chapters">' not in tour or 'First steps</a></li>' not in tour:
        fail('tour.html: not the text before the first chapter and the chapter list')
    if '<h1 id="1-first-steps">1. First steps' not in first or 'not a chapter' not in first:
        fail('tour-first-steps.html: the chapter heading not its `<h1>`, or the code block not on it')
    if not re.search(r'<section class="part" id="a-subsection">\s*<h2>', more):
        fail('tour-more.html: `### A subsection` not a level 2 heading')
    pager = (
        '<nav class="pager"><a class="prev" href="tour.html">← Tour</a>'
        '<a class="next" href="tour-more.html">2. <code>More</code> →</a></nav>'
    )
    if pager not in first or '<a class="prev" href="tour-first-steps.html">' not in more or 'class="next"' in more:
        fail('split: wrong Previous / Next links')
    if (
        'href="tour-more.html#a-subsection"' not in first
        or 'href="tour-first-steps.html#1-first-steps"' not in more
        or 'href="tour.html"' not in more
    ):
        fail('split: a link to a heading of the file not to its chapter')
    index = setu_docs.llms_index(site.project.config, site.chapters)
    if '- [Tour](tour.html)\n  - [1. First steps](tour-first-steps.html)\n' not in index:
        fail('llms.txt: the chapters not under their page')


def check_site(project, out):
    site = setu_docs.Site(project)
    files = site.write(out)
    pages = ('index', 'guide', 'functions', 'classes', 'types', 'constants', 'examples', 'coverage')
    for name in (*(f'{p}.html' for p in pages), 'search.json', 'style.css', 'app.js', 'docs.wasm', 'llms.txt',
                 'llms-full.txt'):  # fmt: skip
        if name not in files:
            fail(f'site: no {name}')
    if (out / 'docs.wasm').read_bytes()[:4] != b'\0asm':
        fail('docs.wasm is not WebAssembly')
    check_split(site, out, files)
    for name in files:
        if name.endswith('.html') and setu_docs.pretty_html(text := (out / name).read_text()) != text:
            fail(f'{name}: `pretty_html` changes its own output')
    same(
        'pretty_html: a line break in text, then a block',
        setu_docs.pretty_html('<li>a\nb\n<ul><li>c</li></ul></li><p>d\xa0\n<b>e</b></p>'),
        '<li>a\n  b\n  <ul>\n    <li>c</li>\n  </ul>\n</li>\n<p>d\xa0\n  <b>e</b></p>\n',
    )
    same(
        'pretty_html: a `<pre>` in `.ln` lines, only a line break between them (the first line break and a last one'
        ' dropped), unless empty;'
        ' `<textarea>` content on its own line',
        setu_docs.pretty_html(
            '<div><pre class="code">a\n\n b</pre><pre hidden></pre><pre>\nc\n</pre><textarea>t</textarea></div>'
        ),
        '<div>\n  <pre class="code">\n<span class="ln">a</span>\n<span class="ln"></span>\n<span class="ln"> b</span>'
        '</pre>\n  <pre hidden></pre>\n  <pre>\n<span class="ln">c</span></pre>\n  <textarea>\nt</textarea>\n</div>\n',
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
    guide = (out / 'guide.html').read_text()
    if '<span class="ln">' not in guide:
        fail('guide.html: no `<pre>` in `.ln` lines')
    # written for no `docs.wasm` (opened from disk): app.js turns these on, it builds no elements
    for text, why in (
        ('<input id="q" type="search" placeholder="Search needs a server" autocomplete="off" disabled>', 'search'),
        ('title="Themes need a server" aria-haspopup="menu" aria-expanded="false" disabled>', 'the ◐ button'),
    ):
        if text not in guide:
            fail(f'guide.html: {why} not off as written ({text!r})')
    if not re.search(rf'<div class="codebox">\s*<pre class="code"[^>]*>.*?</pre>\s*{COPY[:-6]}\s*</div>', guide, re.S):
        fail('guide.html: no `<pre>` in a `.codebox` with a hidden Copy button')
    if 'createElement' in setu_docs.JS:
        fail('app.js: builds elements (setu_docs.py writes them, hidden)')
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
    if '&#x27;hi from&#x27;' not in guide or '@@example/hi.py@@' in guide:
        fail('guide.html: the `@@example/hi.py@@` line not replaced by the file')
    hi = (project.root / 'example/hi.py').read_text().rstrip()
    included = setu_docs.include_files('a\n@@example/hi.py@@\nb', project.root)
    same('include_files', included, f'a\n```python\n{hi}\n```\nb')
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
    project.homepage, homepage = '', project.homepage
    project.repo, repo = 'https://example.org/me/pkg', project.repo
    footer = re.search(r'docstrings of <a href="([^"]*)"', site.page('index', 'Home', ''))
    project.homepage, project.repo = homepage, repo
    same('footer: the name links the repository without a homepage', footer and footer[1], 'https://example.org/me/pkg')
    repo = '<a class="repo" href="https://github.com/YoSTEALTH/Setu"'
    if repo not in home or 'data-repo="YoSTEALTH/Setu"' not in home:
        fail('index.html: no repository link from the `[project]` homepage')
    web = (SETU / 'tools/setu_docs_web.zig').read_text()
    if '"{s}/releases?per_page=10"' not in web or '/releases/latest' in web:
        fail('docs.wasm: the latest release from `releases/latest` (a 404 in the console without releases)')
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
    # each palette's light and dark set, and the system's dark before a pick (Nord Night): each sets every color
    blocks = re.findall(r':root[^{]*\{([^}]*--bg:[^}]*)\}', setu_docs.CSS)
    themes = [set(re.findall(r'(--[\w-]+):', b)) for b in blocks]
    if len(themes) != 2 * len(setu_docs.THEMES) + 1 or any(t != themes[0] for t in themes):
        fail(f'CSS: the theme blocks set different variables: {[sorted(t) for t in themes]}')
    for key in setu_docs.THEME_NAMES:
        sets = re.findall(rf':root\[data-palette="{key}"\][^{{]*\{{[^}}]*--bg:', setu_docs.CSS)
        if len(sets) != 2:
            fail(f'CSS: theme {key!r} has not a light and a dark set')

    def colors(selector):
        found = re.search(rf'{re.escape(selector)} \{{([^}}]*)\}}', setu_docs.CSS)
        return found and found[1].split()

    if not colors(':root:not([data-theme])') or colors(':root:not([data-theme])') != colors(
        ':root[data-palette="nord"][data-theme="dark"]'
    ):
        fail("CSS: the system's dark before a pick is not Nord Night (setu_docs_web.zig's `default_theme`)")
    index = (out / 'index.html').read_text()
    for text, why in (
        ('<button id="theme" class="theme" type="button" aria-label="Theme"', 'no ◐ button'),
        ('<div id="themes" class="theme-menu" role="menu" hidden>', 'no theme menu'),
        ('data-palette="nord" data-mode="light">Nord Day</button>', 'no Nord Day in the menu'),
        ('data-palette="" data-mode="dark">Tokyo Night</button>', 'no Tokyo Night in the menu'),
        ("if (p && ['nord'].includes(p)) r.dataset.palette = p;", 'the saved theme not set in <head>'),
    ):
        if text not in index:
            fail(f'index.html: {why} ({text!r})')
    names = re.findall(r'role="menuitemradio"[^>]*>([^<]*)</button>', index)
    same('the ◐ menu', names, ['Nord Day', 'Nord Night', 'Tokyo Day', 'Tokyo Night'])
    examples = (out / 'examples.html').read_text()
    if 'data-target="example/forever.py"' in examples or 'data-target="example/hi.py"' not in examples:
        fail('examples.html: `scripts_skip` not applied')
    check_coverage_page(project, out)
    check_profile_page(project, out)
    check_old_files(out)
    check_js_binding()
    check_selectors(out)
    check_app(out)
    check_version()


# What `app.js` must not use: each is logic (formatting, picking, parsing text, arithmetic), which belongs in
# `docs.wasm` (tools/setu_docs_web.zig); `app.js` only binds it to the page.
JS_LOGIC = (
    '% .toFixed( .filter( .find( .sort( .reduce( RegExp .match( .replace( .test( .slice( .substring( '
    'parseInt parseFloat toLocaleString'
).split()


# Every string `app.js` may have: it is a fixed loop over `docs.wasm`'s commands, so a selector, an element id or a
# feature's text in it is feature code, which belongs in `docs.wasm`.
JS_STRINGS = {
    'docs.wasm',
    '(prefers-color-scheme: dark)',
    'string',
    'docs.wasm: out of memory',
    'POST',
    'Content-Type',
    'text/plain',
    ' ',
    '\\x1f',
    '',
    '[data-n="',
    '"]',
}


def check_js_binding():
    '''`app.js` is only the loop that runs `docs.wasm`'s commands: none of `JS_LOGIC` in its code (comments aside),
    no string but `JS_STRINGS`, and an entry in `ops` per `Op` of `tools/setu_docs_web.zig`, in its order.'''
    code = re.sub(r'^\s*//.*$|\s//.*$', '', setu_docs.JS, flags=re.M)
    found = [x for x in JS_LOGIC if x in code]
    if found:
        fail(f'app.js: logic belongs in docs.wasm (tools/setu_docs_web.zig), not app.js: {found}')
    strings = set(re.findall(r"'((?:[^'\\]|\\.)*)'", code)) - JS_STRINGS
    if strings:
        fail(f'app.js: names an element or a feature (docs.wasm does): {sorted(strings)}')
    web = (SETU / 'tools/setu_docs_web.zig').read_text()
    enum = re.search(r'pub const Op = enum\(u8\) \{(.*?)\n\};', web, re.S).group(1)
    ops = re.findall(r'^    (\w+),$', enum, re.M)
    entries = re.findall(r'^      \(\) => .*?// (\w+)', setu_docs.JS, re.M)
    same('app.js: an `ops` entry per `Op`, in order (each with its name in a comment)', entries, ops)


class Element:
    '''An element of a page, for `select`: its tag, attributes and parent.'''

    def __init__(self, tag, attrs, parent):
        self.tag, self.attrs, self.parent = tag, dict(attrs), parent


def elements(text):
    '''Every element of the HTML `text`, in document order.'''
    found, stack = [], []

    class Parser(html.parser.HTMLParser):
        def handle_starttag(self, tag, attrs):
            found.append(Element(tag, ((k, v or '') for k, v in attrs), stack[-1] if stack else None))
            if tag not in setu_docs.VOID_TAGS:
                stack.append(found[-1])

        def handle_endtag(self, tag):
            while stack and stack.pop().tag != tag:
                pass

    Parser().feed(text)
    return found


# A compound selector's parts: a tag, `#id`, `.class`, `[a]` / `[a="v"]`, `:not(` one of those `)`
SIMPLE = re.compile(r'(:not\()?(?:([\w-]+)|#([\w-]+)|\.([\w-]+)|\[([\w-]+)(?:="([^"]*)")?\])\)?')


def matches(e, compound):
    '''Whether element `e` matches `compound` (`SIMPLE`'s parts, no space).'''
    for m in SIMPLE.finditer(compound):
        neg, tag, id_, cls, attr, value = m.groups()
        if tag:
            ok = e.tag == tag
        elif id_:
            ok = e.attrs.get('id') == id_
        elif cls:
            ok = cls in e.attrs.get('class', '').split()
        else:
            ok = attr in e.attrs and (value is None or e.attrs[attr] == value)
        if ok == bool(neg):
            return False
    return True


def select(found, selector):
    '''The elements of `found` that match `selector` (compounds joined by spaces: descendants), in order.'''
    *outer, last = selector.split()
    out = []
    for e in found:
        if not matches(e, last):
            continue
        need, at = list(outer), e.parent
        while need and at:
            if matches(at, need[-1]):
                need.pop()
            at = at.parent
        if not need:
            out.append(e)
    return out


def check_selectors(out):
    '''Every selector `docs.wasm` binds matches on the fixture's pages, and the groups that go together (a row, its
    view, its `<pre>`; a Run box's parts; a code block and its Copy button) are as many on each page.'''
    web = (SETU / 'tools/setu_docs_web.zig').read_text()
    unquote = lambda text: text.replace('\\"', '"')  # noqa: E731
    top = re.findall(r'\.\{ el\.\w+, "([#.][^"]*)" \}', web)  # `bind`'s list in `begin`
    top += re.findall(r'bindAll\(el\.document, \.(\w+), "((?:[^"\\]|\\.)*)"', web)
    inner = {'#themes button': 1, '.repo .facts': 1, 'table.prof tr.src-view pre': 1}  # the ones bound in an element
    names = ('index.html', 'guide.html', 'coverage.html', 'functions.html', 'examples.html')
    pages = {name: elements((out / name).read_text()) for name in names}
    pages['profile.html'] = elements(setu_docs.Site(setu_docs.Project(FIXTURE / 'pyproject.toml')).profile_page())
    counts = {}
    for entry in [*top, *inner]:
        group, selector = entry if isinstance(entry, tuple) else ('', entry)
        selector = unquote(selector)
        hits = {name: len(select(found, selector)) for name, found in pages.items()}
        if not any(hits.values()):
            fail(f'docs.wasm binds {selector!r}: nothing matches on the fixture\'s pages')
        counts[group] = hits
    for groups in (('cov_rows', 'cov_views', 'cov_pres'), ('prof_rows', 'prof_views'), ('code_pres', 'copies'),
                   ('run_boxes', 'run_buttons', 'run_statuses', 'run_results')):  # fmt: skip
        if len({tuple(counts[g].values()) for g in groups}) != 1:
            fail(f'docs.wasm: {", ".join(groups)} not as many on each page: {[counts[g] for g in groups]}')


def check_app(out):
    '''The site's `app.js` and `docs.wasm` in deno, against a recording stand-in for the browser
    (`test/docs/app_test.js`): what the page saw is `test/docs/app_test.txt`.'''
    deno = shutil.which('deno')
    if not deno:
        fail('deno not found: it runs test/docs/app_test.js (https://deno.com)')
    run = subprocess.run([deno, 'run', '--allow-read', str(FIXTURE / 'app_test.js'), str(out)],
                         capture_output=True, text=True, timeout=60)  # fmt: skip
    if run.returncode:
        fail(f'test/docs/app_test.js failed:\n{run.stderr}')
    same('test/docs/app_test.js: what the page saw', run.stdout, (FIXTURE / 'app_test.txt').read_text())


def check_version():
    '''`version = 'build.zig.zon'`: its `.version`, a commented-out one skipped.'''
    with tempfile.TemporaryDirectory() as tmp:
        zon = pathlib.Path(tmp) / 'build.zig.zon'
        zon.write_text('.{\n    // .version = "0.1",\n    .name = .x,\n    .version = "2026.10.28-2",\n}\n')
        same('zon_version', setu_docs.zon_version(zon), '2026.10.28-2')


def check_old_files(out):
    '''A file the last build wrote and this one does not is removed (and its empty folders); others stay.'''
    if 'coverage.html' not in (out / setu_docs.MANIFEST).read_text().splitlines():
        fail(f'site: {setu_docs.MANIFEST} does not list the files written')
    with tempfile.TemporaryDirectory() as tmp:
        site = pathlib.Path(tmp)
        for name in ('a.html', 'gone.html', 'source/old/x.zig', 'mine.txt', 'source/keep/y.zig'):
            (site / name).parent.mkdir(parents=True, exist_ok=True)
            (site / name).write_text('x')
        (site / setu_docs.MANIFEST).write_text('a.html\ngone.html\nsource/old/x.zig\nsource/keep/y.zig\n../out\n')
        setu_docs.forget_old_files(site, ['a.html', 'source/keep/y.zig'])
        left = sorted(str(p.relative_to(site)) for p in site.rglob('*'))
        same('forget_old_files', left, [setu_docs.MANIFEST, 'a.html', 'mine.txt', 'source', 'source/keep',
                                        'source/keep/y.zig'])  # fmt: skip
        same('forget_old_files: the record', (site / setu_docs.MANIFEST).read_text(), 'a.html\nsource/keep/y.zig\n')


def check_coverage_page(project, out):
    '''`coverage`: the page from the fixture's snapshot, a section per owner, its sources for the viewer; without the
    file, no page.'''
    page = (out / 'coverage.html').read_text()
    for text, why in (
        ('<h2 id="setu_classes">setu_classes<a', 'no section of the own files'),
        ('aria-label="setu_classes: 90.0% covered"', 'no donut of the own files'),
        ('<h2 id="dep-setu">Setu<a', 'no section of the dependency, by its display name (its pyproject.toml)'),
        ('aria-label="Setu run by setu_classes&#x27;s tests: 66.7% covered"', 'no donut of the dependency'),
        ('aria-label="setu_classes + Setu: 81.2% covered"', 'no donut of both'),
        ('CPython 3.15 and CPython 3.14', 'not the interpreters'),
        ('CPython 3.14: <b>81.2%</b>, 13 / 16 lines', 'not a run on its own'),
        ('<td class="missed"><span class="miss-fn">11-12</span></td>', 'not the missed lines as a range'),
        ('<td class="missed"><span class="miss-fn"><code>norm2</code> 4</span></td>', 'missed lines not by function'),
        (
            '<small class="runs" title="The interpreters ran different lines of this file">CPython 3.15: 3 / 6, '
            'CPython 3.14: 4 / 6</small>',
            'no note where the interpreters differ',
        ),
        ('<p class="src-hint" hidden>Click a file', 'no hint for the viewer, hidden'),
        ('<p class="src-hint">The sources need a server', 'not the hint without `docs.wasm` as the default'),
        (
            '<tr class="src-row" data-src="source/example/vec.zig" data-hit="1-3, 5-10" data-miss="4" title=',
            'the own file: not a viewer row (its source found, not changed)',
        ),
        (
            '<tr class="src-row" data-src="source/setu/src/args.zig" data-hit="10, 13-15" data-miss="11-12" '
            'data-stale="1"',
            "the dependency's file: not a viewer row (found through build.zig.zon), or not flagged changed",
        ),
        ('<small class="stale"', 'no `changed` by a changed file'),
        ('<a href="coverage.html" class="on">Coverage</a>', 'no nav item'),
        ('aria-label="Coverage history: 3 versions, 1.0 to 1.2"', 'no history chart'),
        ('<title>1.1: 75.0% (12 / 16 lines)</title>', 'no point of a version'),
        ('<text x="20" y="136">75%</text>', 'not the lowest percent, rounded down, at the bottom'),
    ):
        if text not in page:
            fail(f'coverage.html: {why} ({text!r})')
    views = re.findall(r'</tr>\s*<tr class="src-view" hidden>\s*<td colspan="5">\s*<pre class="cov-src"></pre>', page)
    if len(views) != 2:
        fail(f'coverage.html: {len(views)} hidden, empty view rows (all 5 columns), not 2 (one per viewer row)')
    if page.index('example/vec.zig') > page.index('id="dep-setu"'):
        fail('coverage.html: the own file not before the dependency')
    for path, real in (('example/vec.zig', 'example/vec.zig'), ('setu/src/args.zig', '../../src/args.zig')):
        copy = out / 'source' / path
        if not copy.is_file() or copy.read_bytes() != (project.root / real).read_bytes():
            fail(f'site: source/{path} is not a copy of its source')
    same('line_ranges', setu_docs.line_ranges([3, 4, 5, 9, 11, 12]), '3-5, 9, 11-12')
    zig = 'const a = 1;\npub fn f() void {\n    x();\n}\ninline fn g(y: u8) void {\n    _ = y;\n    z();\n}\n'
    same('missed_functions: before any function, one never run, one partly',
         setu_docs.missed_functions(zig, {1: 0, 3: 0, 6: 1, 7: 0}),
         [('', [1], False), ('f', [3], True), ('g', [7], False)])  # fmt: skip
    site = setu_docs.Site(project)
    same('missed_html: a function Python has linked, `never run`',
         site.missed_html([('vec_norm2', [3, 4], True), ('', [9], False)]),
         '<span class="miss-fn"><code><a href="functions.html#vec_norm2">vec_norm2</a></code> 3-4 '
         '<small class="never">never run</small></span> <span class="miss-fn">9</span>')  # fmt: skip
    same('missed_html: ranges linked to the file at the commit',
         site.missed_html([('', [3, 4, 9], False)], 'https://g/f.zig'),
         '<span class="miss-fn"><a href="https://g/f.zig#L3-L4">3-4</a>, '
         '<a href="https://g/f.zig#L9">9</a></span>')  # fmt: skip
    check_coverage_commit(project)
    same('slug', setu_docs.slug('Liburing + Setu'), 'liburing-setu')
    same('dependency_root', setu_docs.dependency_root(project.root, 'setu'), (project.root / '../..').resolve())
    same('dependency_root', setu_docs.dependency_root(project.root, 'nope'), None)
    same('display_name', setu_docs.display_name(project.root, 'x'), 'x')  # no `name` in its [tool.setu_docs]
    project.config['coverage'], snapshot = 'missing.json', project.config['coverage']
    try:
        site = setu_docs.Site(project)
        if site.coverage or 'coverage.html' in site.nav('index'):
            fail('a missing `coverage` file: still a Coverage page')
    finally:
        project.config['coverage'] = snapshot
    check_coverage_history(project)


def check_coverage_history(project):
    '''`coverage_history`: a version's entry set in place or added (`check_coverage.py --history`), the file one entry
    per line; the chart of one run; a missing file no chart, a file of another kind refused.'''
    sys.path.insert(0, str(SETU / 'tools'))
    import check_coverage

    one = check_coverage.history(None, '1.0', 9, 10, [('3.15', 9, 10)])
    two = check_coverage.history(one, '1.1', 10, 10, [])
    same('history: a new version last', [r['version'] for r in two['runs']], ['1.0', '1.1'])
    same('history: a version set in place', check_coverage.history(two, '1.0', 8, 10, [])['runs'][0],
         {'version': '1.0', 'covered': 8, 'lines': 10, 'interpreters': {}})  # fmt: skip
    same(
        'history_text',
        check_coverage.history_text(one),
        '{"runs": [\n {"version": "1.0", "covered": 9, "lines": 10, "interpreters": {"3.15": [9, 10]}}\n]}\n',
    )
    same('history_text: no runs', check_coverage.history_text({'runs': []}), '{"runs": [\n]}\n')
    chart = setu_docs.coverage_history_chart(one['runs'])
    for text in ('aria-label="Coverage history: 1 version, 1.0"', '<circle cx="150.0" cy="120.0"', '>90%</text>'):
        if text not in chart:
            fail(f'coverage_history_chart: one run: {text!r} missing')
    same('coverage_history_chart: no runs', setu_docs.coverage_history_chart([]), '')
    snapshot = project.config['coverage_history']
    with tempfile.TemporaryDirectory() as tmp:
        try:
            project.config['coverage_history'] = 'missing.json'
            same('coverage_history: a missing file', setu_docs.Site(project).coverage_history, [])
            bad = Path(tmp) / 'h.json'
            bad.write_text('{"schemaVersion": 1, "label": "coverage"}')  # a badge
            same('is_history: a badge', check_coverage.is_history(str(bad)), False)
            project.config['coverage_history'] = str(bad)
            try:
                setu_docs.Site(project)
                fail('coverage_history: a badge taken for a history')
            except SystemExit as e:
                if 'is not a `--history` file' not in str(e.code):
                    raise
            bad.write_text(check_coverage.history_text(one))
            same('is_history: a history', check_coverage.is_history(str(bad)), True)
        finally:
            project.config['coverage_history'] = snapshot


def check_coverage_commit(project):
    '''`coverage`'s `commit`: read, and the project's files linked at it on GitHub (the fixture is `test/docs/` in
    Setu's repository); `check_coverage.py` records it only for a tree as committed.'''
    snapshot = project.config['coverage']
    with tempfile.TemporaryDirectory() as tmp:
        data = json.loads((project.root / snapshot).read_text())
        (Path(tmp) / 'c.json').write_text(json.dumps({**data, 'commit': 'abc123'}))
        project.config['coverage'] = str(Path(tmp) / 'c.json')
        try:
            site = setu_docs.Site(project)
            same('blob_url', site.blob_url('example/vec.zig'),
                 'https://github.com/YoSTEALTH/Setu/blob/abc123/test/docs/example/vec.zig')  # fmt: skip
            site.sources = {}
            table = site.coverage_table([('example/vec.zig', 9, 10, [4], [1])], project.root)
            if 'href="https://github.com/YoSTEALTH/Setu/blob/abc123/test/docs/example/vec.zig#L4">4</a>' not in table:
                fail('coverage.html: a missed line of the project\'s file not linked at the commit')
        finally:
            project.config['coverage'] = snapshot
    if setu_docs.Site(project).blob_url('example/vec.zig') is not None:
        fail('blob_url: a link without a `commit`')
    sys.path.insert(0, str(SETU / 'tools'))
    import check_coverage

    with tempfile.TemporaryDirectory() as tmp:
        cwd = os.getcwd()
        os.chdir(tmp)
        try:
            same('clean_commit: not a git work tree', check_coverage.clean_commit(), None)
            git = ['git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false']
            subprocess.run(['git', 'init', '-q'], check=True)
            Path('a.zig').write_text('a\n')
            subprocess.run(['git', 'add', 'a.zig'], check=True)
            subprocess.run([*git, 'commit', '-q', '-m', 'a'], check=True)
            head = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
            same('clean_commit: as committed', check_coverage.clean_commit(), head)
            Path('b.zig').write_text('untracked\n')
            same('clean_commit: an untracked file', check_coverage.clean_commit(), head)
            Path('c.zig').write_text('c\n')
            subprocess.run(['git', 'add', 'c.zig'], check=True)
            subprocess.run([*git, 'commit', '-q', '-m', 'c'], check=True)
            head = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
            Path('c.zig').write_text('changed, not measured\n')
            same('clean_commit: a change in a file not measured', check_coverage.clean_commit(['a.zig']), head)
            same('clean_commit: a changed file', check_coverage.clean_commit(), None)
            Path('a.zig').write_text('changed\n')
            same('clean_commit: a measured file changed', check_coverage.clean_commit([str(Path('a.zig').resolve())]),
                 None)  # fmt: skip
        finally:
            os.chdir(cwd)


def check_profile_page(project, out):
    '''`profile`: only `serve` writes the page (live), not `build`: the nav item is there, shown when live; the page
    from the fixture's snapshot has a row per case with its files for the view; without the file, a page that says
    how to make it.'''
    if (out / 'profile.html').exists():
        fail('site: profile.html written by `build` (only `serve` has it)')
    item = '<a href="profile.html" class="live-only">Profile</a>'
    if item not in (out / 'index.html').read_text():
        fail(f'index.html: no Profile nav item shown only live ({item!r})')
    if 'body.can-run .side a.live-only { display: block; }' not in setu_docs.CSS:
        fail('CSS: the live-only nav item not shown when live')
    site = setu_docs.Site(project)
    page = setu_docs.pretty_html(site.profile_page())
    for text, why in (
        ('<th>CPython 3.15</th>', 'no column per interpreter'),
        ('title="200.0 per call: 50.0 in the extension (25%), 150.0 in the interpreter"', 'not the bar\'s numbers'),
        ('<span class="pbar" style="width:50.0%"><i style="width:25.0%"></i>', 'not the bar scaled to the top case'),
        ('<td>-</td>', 'a case one interpreter does not have: not `-`'),
        ('<a href="profile.html" class="live-only on">Profile</a>', 'no nav item'),
    ):
        if text not in page:
            fail(f'profile.html: {why} ({text!r})')
    if not re.search(r'<div class="prof-wrap">\s*<table class="prof">', page):
        fail('profile.html: the table not in its scrolling holder (it would overflow into the menu)')
    if 'tr.src-view pre.cov-src { width: 0; min-width: 100%;' not in setu_docs.CSS:
        fail('CSS: a source view widens its table (the columns go out of view)')
    rows = re.findall(r'<tr class="prof-row" [^>]*>.*?</tr>\s*<tr class="src-view" hidden>(.*?)</tr>', page, re.S)
    if len(rows) != 2:
        fail(f'profile.html: {len(rows)} case rows with a hidden view under them, not 2')
    files = re.findall(
        r'<div class="prof-file"><code>([^<]*)</code> ([^<]*)</div>\s*'
        r'<pre class="cov-src prof-src" data-src="([^"]*)" data-lines="([^"]*)"></pre>',
        rows[0],
    )
    same(
        'profile.html: the first case\'s files (a heading and an empty `<pre>` each)',
        files,
        [
            ('test/functions.zig', '30.0 per call', 'source/test/functions.zig', '0:2.0,25:8.0,26:20.0'),
            ('setu/src/args.zig', '20.0 per call', '', '90:20.0'),
        ],
    )  # fmt: skip
    if '<td colspan="3">' not in rows[0]:
        fail('profile.html: the view\'s cell does not span the case and the 2 interpreters')
    if site.sources.get('test/functions.zig', Path()).resolve() != (project.root / '../functions.zig').resolve():
        fail(f'profile.html: source/test/functions.zig not served from its source ({site.sources})')
    if (out / 'source/test/functions.zig').exists():
        fail('site: source/test/functions.zig copied by `build` (only the Profile page shows it)')
    check_profile_paths()
    project.config['profile'], snapshot = 'missing.json', project.config['profile']
    try:
        site = setu_docs.Site(project)
        if site.profile or 'No profile yet: run <code>zig build profile</code>' not in site.profile_page():
            fail('a missing `profile` file: not a page that says how to make it')
    finally:
        project.config['profile'] = snapshot
    del project.config['profile']
    try:
        if 'profile.html' in setu_docs.Site(project).nav('index'):
            fail('no `profile` setting: still a Profile nav item')
    finally:
        project.config['profile'] = snapshot


def check_profile_paths():
    '''`check_profile.py` names a dependency's file `<its .name>/<path in it>` (as the Coverage page does), not
    through the project with `..`, which the Profile page's `source/<path>` could not fetch.'''
    sys.path.insert(0, str(SETU / 'tools'))
    import check_profile

    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / 'proj').mkdir()
        (Path(tmp) / 'dep/src').mkdir(parents=True)
        (Path(tmp) / 'dep/build.zig.zon').write_text('.{ .name = .dep, .version = "1" }\n')
        cwd = os.getcwd()
        os.chdir(Path(tmp) / 'proj')
        try:
            shown = [check_profile.display(os.path.join(os.getcwd(), p)) for p in ('src/a.zig', '../dep/src/b.zig')]
        finally:
            os.chdir(cwd)
    same('check_profile.display: the project\'s file, a dependency\'s', shown, ['src/a.zig', 'dep/src/b.zig'])


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
        if b'<tr class="prof-row"' not in urllib.request.urlopen(f'{base}/profile.html').read():
            fail('the server does not make the Profile page')
        served = urllib.request.urlopen(f'{base}/source/test/functions.zig').read()
        if served != (project.root / '../functions.zig').read_bytes():
            fail('the server does not serve the Profile page\'s source/test/functions.zig')

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
