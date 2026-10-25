'''Documentation site helpers for a Zig + Setu extension: a MkDocs site built from its generated `.pyi`.

Kept in Setu (`tools/setu_docs.py`) and copied unchanged into each project that uses Setu
(`zig build setu-docs-sync` / `setu-docs-check`, see `addSetuDocsSteps` in Setu's `build.zig`). Project settings
go in `pyproject.toml`, never in a copy. Needs `mkdocs-material`, `mkdocstrings[python]` and `mkdocs-gen-files`.

Two parts, both used from `mkdocs.yml`:

    plugins:
      - gen-files:
          scripts: [docs/gen_api.py]            # `import setu_docs; setu_docs.write_api()`, see below
      - mkdocstrings:
          handlers:
            python:
              paths: [src]
              options:
                extensions: [tools/setu_docs.py:Markdown]
                docstring_style: null

`Markdown` is a griffe extension: the stub's docstrings are the Zig `///` docs, a description, then sections
(a header on its own line such as `Example`, `Note`, `Type`, `Flags`, its content indented 4 spaces). Markdown reads
that as code and quotes, so each section is rewritten: `Note` / `Warning` become admonitions, `Example` (and a bare
`>>>` session) a `pycon` block, anything else a `text` block.

`write_api()` writes the API reference pages (`api/index.md` and `api/<slug>.md`) from the stub; `write_llms()`
writes `llms.txt` (an index of the pages, for AI readers) and `llms-full.txt` (every class, function and constant
with its signature and docstring, one page) into the site root. The grouping is the project's, in `pyproject.toml`:

    [tool.setu_docs]
    stub = 'src/pkg/pkg.pyi'        # the generated stub (`zig build develop`)
    module = 'pkg.pkg'              # the module mkdocstrings loads (`::: pkg.pkg.name`)
    summary = 'io_uring for Python' # optional: the one-line summary of `llms.txt`

    [[tool.setu_docs.pages]]        # first match wins, in this order
    slug = 'ring'
    title = 'Ring and setup'
    text = 'Create, configure and tear down a `Ring`.'
    classes = ['Ring', 'Param']                     # exact class names
    functions = ['probe']                           # exact function names
    patterns = ['^io_uring_(queue_|setup)']         # `re.search` on function names

    [[tool.setu_docs.pages]]
    slug = 'types'
    title = 'Types'
    text = 'Everything else.'
    default = true                  # exactly one: the names no page claims

    [[tool.setu_docs.pages]]
    slug = 'constants'
    title = 'Constants'
    text = 'Grouped by the prefix before the first `_`.'
    constants = true                # at most one: the UPPER_CASE names of the stub

Example
    >>> convert('Adds.\\n\\nExample\\n    >>> add(1)\\n    1')
    'Adds.\\n\\n**Example**\\n\\n```pycon\\n>>> add(1)\\n1\\n```'
'''

import ast
import re
import textwrap
import tomllib
from pathlib import Path

try:
    import griffe
except ImportError:  # only the site build needs it
    griffe = None

HEADER = re.compile(r'[A-Z][A-Za-z ]*')
ADMONITION = {'Note': 'note', 'Warning': 'warning'}


def convert(text: str) -> str:
    '''The Zig doc `text` as Markdown.'''
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if HEADER.fullmatch(line) and i + 1 < len(lines) and lines[i + 1].startswith(' '):
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or lines[j].startswith(' ')):
                j += 1
            block = textwrap.dedent('\n'.join(lines[i + 1 : j])).strip('\n')
            if line in ADMONITION:
                out += [f'!!! {ADMONITION[line]} "{line}"', '', textwrap.indent(block, '    '), '']
            else:
                out += [f'**{line}**', '', '```pycon' if line == 'Example' else '```text', block, '```', '']
            i = j
        elif line.startswith('>>>'):  # a bare session, no `Example` header: up to the next blank line
            j = i
            while j < len(lines) and lines[j].strip():
                j += 1
            out += ['```pycon', *lines[i:j], '```']
            i = j
        else:
            out.append(line)
            i += 1
    return '\n'.join(out).strip('\n')


def raw_docstring(node) -> str | None:
    '''The docstring as written: griffe's `value` has the section indent stripped (`inspect.cleandoc`).

    Griffe loads the module twice, the stub (an `ast` node) and the compiled module (`__doc__`); both get
    converted, the compiled one wins when the `.so` sits next to the `.pyi`.
    '''
    if isinstance(node, ast.AST):
        raw = ast.get_docstring(node, clean=False)  # type: ignore[arg-type]
        if raw is None:
            return None
        first, *rest = raw.split('\n')
        base = ' ' * (getattr(node, 'col_offset', -4) + 4)  # the docstring's own indent (a module has no offset)
        return '\n'.join([first, *(line.removeprefix(base) for line in rest)])
    doc = getattr(getattr(node, 'obj', None), '__doc__', None)
    return doc if isinstance(doc, str) else None


if griffe is not None:

    class Markdown(griffe.Extension):
        '''Griffe extension: every docstring through `convert`.'''

        def on_instance(self, *, node, obj, agent=None, **kwargs) -> None:
            if obj.docstring is not None and (raw := raw_docstring(node)) is not None:
                obj.docstring.value = convert(raw)


def load_config(pyproject: str | Path = 'pyproject.toml') -> dict:
    '''`[tool.setu_docs]` of `pyproject`, checked.'''
    path = Path(pyproject)
    config = tomllib.loads(path.read_text()).get('tool', {}).get('setu_docs')
    if config is None:
        raise SystemExit(f'setu_docs: no [tool.setu_docs] in {path}')
    for key in ('stub', 'module', 'pages'):
        if key not in config:
            raise SystemExit(f'setu_docs: [tool.setu_docs] needs `{key}`')
    pages = config['pages']
    for page in pages:
        for key in ('slug', 'title', 'text'):
            if key not in page:
                raise SystemExit(f'setu_docs: every page needs `{key}`: {page}')
    if len({p['slug'] for p in pages}) != len(pages):
        raise SystemExit('setu_docs: a page slug twice')
    if sum(bool(p.get('default')) for p in pages) != 1:
        raise SystemExit('setu_docs: exactly one page needs `default = true`')
    if sum(bool(p.get('constants')) for p in pages) > 1:
        raise SystemExit('setu_docs: at most one page can have `constants = true`')
    return config


def page_of(pages: list[dict], kind: str, name: str) -> str:
    '''The slug of the page that lists the class or function `name`: the first claiming it, else the default.'''
    for page in pages:
        if kind == 'class' and name in page.get('classes', ()):
            return page['slug']
        if kind == 'def' and (
            name in page.get('functions', ()) or any(re.search(rx, name) for rx in page.get('patterns', ()))
        ):
            return page['slug']
    return next(p['slug'] for p in pages if p.get('default'))


def group(config: dict, stub: str) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    '''The names of the stub text `stub` by page slug, and its constants by prefix.'''
    pages = config['pages']
    members: dict[str, list[str]] = {p['slug']: [] for p in pages}
    constants: dict[str, list[str]] = {}
    for node in ast.parse(stub).body:
        if isinstance(node, ast.ClassDef | ast.FunctionDef):
            kind = 'class' if isinstance(node, ast.ClassDef) else 'def'
            members[page_of(pages, kind, node.name)].append(node.name)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            name = node.target.id
            if name != '__version__':
                constants.setdefault(name.split('_')[0], []).append(name)
    if constants and not any(p.get('constants') for p in pages):
        raise SystemExit('setu_docs: the stub has constants but no page has `constants = true`')
    return members, constants


def write_api(pyproject: str | Path = 'pyproject.toml') -> None:
    '''Writes `api/index.md` and `api/<slug>.md` (call it from a `mkdocs-gen-files` script).'''
    import mkdocs_gen_files

    config = load_config(pyproject)
    root = Path(pyproject).parent
    members, constants = group(config, (root / config['stub']).read_text())
    pages = config['pages']

    index = ['# API reference', '', 'Generated from the type stubs, which Setu builds from the `///` docs in the',
            'Zig source.', '', '| Page | Contents | Entries |', '| --- | --- | --- |']  # fmt: skip
    for page in pages:
        count = sum(map(len, constants.values())) if page.get('constants') else len(members[page['slug']])
        index.append(f'| [{page["title"]}]({page["slug"]}.md) | {page["text"]} | {count} |')
    with mkdocs_gen_files.open('api/index.md', 'w') as out:
        out.write('\n'.join(index) + '\n')

    for page in pages:
        lines = [f'# {page["title"]}', '', page['text'], '']
        if page.get('constants'):
            for prefix in sorted(constants):
                names = constants[prefix]
                lines += [f'## {prefix}_*' if len(names) > 1 else f'## {names[0]}', '']
                lines += [' '.join(f'`{n}`' for n in names), '']
        else:
            lines += [f'::: {config["module"]}.{name}\n' for name in members[page['slug']]]
        with mkdocs_gen_files.open(f'api/{page["slug"]}.md', 'w') as out:
            out.write('\n'.join(lines))


def signature(stub: list[str], node: ast.FunctionDef) -> str:
    '''`def name(args) -> R` of a stub function, as the stub writes it (the `def` line, or the lines of a
    parameter-per-line one joined), without the `:` and the body.'''
    text = '\n'.join(stub[node.lineno - 1 : node.body[0].lineno])
    body = re.search(r":(\s*#[^\n]*)?\s*(\.\.\.|''')", text)
    text = text[: body.start()] if body else text.rstrip().removesuffix(':')
    return re.sub(r', \)', ')', re.sub(r'\( ', '(', re.sub(r'\s*\n\s*', ' ', text.strip())))


def entry(stub: list[str], node: ast.AST, level: int) -> list[str]:
    '''The Markdown of one declaration of the stub (its `lines`): a heading of `level` with the signature, the
    converted docstring, and for a class the same for each member.'''
    head = '#' * level
    decorators = ''.join(f'@{ast.unparse(d)} ' for d in getattr(node, 'decorator_list', ()))
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
        return [f'{head} {node.target.id}: {ast.unparse(node.annotation)}', '']
    if isinstance(node, ast.FunctionDef):
        lines = [f'{head} {decorators}{signature(stub, node)}', '']
    elif isinstance(node, ast.ClassDef):
        params = ', '.join(ast.unparse(p) for p in node.type_params)
        bases = ', '.join(ast.unparse(b) for b in node.bases)
        name = node.name + (f'[{params}]' if params else '') + (f'({bases})' if bases else '')
        lines = [f'{head} {decorators}class {name}', '']
    else:
        return []
    raw = raw_docstring(node)
    if raw:
        lines += [convert(raw), '']
    if isinstance(node, ast.ClassDef):
        for member in node.body:
            lines += entry(stub, member, level + 1)
    return lines


def llms_full(stub: str, module: str) -> str:
    '''`llms-full.txt`: every declaration of the stub text `stub`, in order, with signature and docstring.'''
    lines = [f'# {module}', '', 'Every class, function and constant of the module, with its signature and docstring',
             '(from the type stubs Setu generates from the `///` docs in the Zig source).', '']  # fmt: skip
    source = stub.splitlines()
    for node in ast.parse(stub).body:
        lines += entry(source, node, 2)
    return '\n'.join(lines).rstrip('\n') + '\n'


def llms_index(config: dict) -> str:
    '''`llms.txt` (the llms.txt convention): the module, its summary, the API pages and `llms-full.txt`.'''
    module = config['module']
    summary = config.get('summary', f'The Python API of `{module}`, from its type stubs.')
    lines = [f'# {module}', '', f'> {summary}', '', '## API reference', '']
    lines += [f'- [{p["title"]}](api/{p["slug"]}/): {p["text"]}' for p in config['pages']]
    lines += ['', '## Full text', '', '- [llms-full.txt](llms-full.txt): every signature and docstring on one page', '']
    return '\n'.join(lines)


def write_llms(pyproject: str | Path = 'pyproject.toml') -> None:
    '''Writes `llms.txt` and `llms-full.txt` into the site root (call it from a `mkdocs-gen-files` script).'''
    import mkdocs_gen_files

    config = load_config(pyproject)
    stub = (Path(pyproject).parent / config['stub']).read_text()
    with mkdocs_gen_files.open('llms.txt', 'w') as out:
        out.write(llms_index(config))
    with mkdocs_gen_files.open('llms-full.txt', 'w') as out:
        out.write(llms_full(stub, config['module']))
