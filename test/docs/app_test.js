// The site's `app.js` with the fixture's `docs.wasm`, in deno, against a recording stand-in for the browser, through
// a fixed script of events: prints what the page saw, one line per call (`tools/check_docs.py` compares it with
// `app_test.txt`). deno has no DOM: the stand-in answers only the selectors `docs.wasm` asks for, and it covers the
// command format and the loop; what each feature does is tested in Zig (`tools/setu_docs_web.zig`).
//     deno run --allow-read test/docs/app_test.js test/docs/site
const site = Deno.args[0];
const log = [];
const say = line => log.push(line);
const realTimeout = setTimeout;
const settle = () => new Promise(done => realTimeout(done, 20));
const short = text => JSON.stringify(text.length > 70 ? text.substring(0, 70) + '…' : text);

class El {
  constructor(name, attrs = {}, text = '', parent = null) {
    Object.assign(this, { name, attrs, text, parent, kids: {}, listeners: {}, clientHeight: 300 });
    this.classList = { toggle: (c, on) => say(`${name} class ${c} ${on}`) };
  }
  querySelector(sel) {
    const line = /^\[data-n="(\d+)"\]$/.exec(sel);  // a source view's line
    return line ? { offsetTop: 20 * Number(line[1]) } : (this.kids[sel] ?? [null])[0];
  }
  querySelectorAll(sel) { return this.kids[sel] ?? []; }
  getAttribute(name) { return this.attrs[name] ?? null; }
  setAttribute(name, value) { this.attrs[name] = value; say(`${this.name} ${name}=${JSON.stringify(value)}`); }
  removeAttribute(name) { delete this.attrs[name]; say(`${this.name} -${name}`); }
  get textContent() { return this.text; }
  set textContent(text) { this.text = text; say(`${this.name} text ${short(text)}`); }
  set innerHTML(html) { say(`${this.name} html ${short(html)}`); }
  set scrollTop(top) { say(`${this.name} scrollTop ${top}`); }
  focus() { say(`${this.name} focus`); fire(this, 'focus', {}, false); }
  addEventListener(type, f) { (this.listeners[type] ??= []).push(f); }
}

// `type` on `target`, then (`bubbles`) on each parent up to the document
function fire(target, type, props = {}, bubbles = true) {
  say(`-- ${type} ${target.name} ${JSON.stringify(props)}`);
  const e = { type, target, ...props, preventDefault: () => say('prevented') };
  for (let at = target; at; at = bubbles ? at.parent : null) (at.listeners[type] ?? []).forEach(f => f(e));
}

const doc = new El('document'), root = new El('html', { 'data-palette': 'nord', 'data-theme': 'dark' }, '', doc);
const body = new El('body', {}, '', root), dark = new El('dark');
Object.assign(doc, { documentElement: root, body });
dark.matches = false;
const el = (name, attrs = {}, text = '', parent = body) => new El(name, attrs, text, parent);
const search = el('search'), q = el('q', { disabled: '' }, '', search), hits = el('hits', { hidden: '' }, '', search);
const themes = el('themes'), theme = el('theme', { disabled: '' }, '', themes);
const menu = el('menu', { hidden: '' }, '', themes);
const items = [['nord', 'light'], ['nord', 'dark'], ['', 'light'], ['', 'dark']].map(([palette, mode], i) =>
  el(`item${i}`, { 'data-palette': palette, 'data-mode': mode }, '', menu));
menu.kids.button = items;
const live = el('live');
const box = el('codebox'), pre = el('pre', { class: 'code session' }, '>>> 1 + 1\n2', box);
const copy = el('copy', { hidden: '' }, 'Copy', box);
const zig = el('zig', {}, 'const x = 1;');
const repo = el('repo', { 'data-repo': 'YoSTEALTH/Setu' }), facts = el('facts', { hidden: '' }, '', repo);
repo.kids['.facts'] = [facts];
for (const fact of ['tag', 'stars', 'forks']) repo.kids[`[data-fact="${fact}"]`] = [el(fact, {}, '', facts)];
const covRow = el('cov-row', { 'data-src': 'source/example/vec.zig', 'data-hit': '1-3', 'data-miss': '4' });
const covView = el('cov-view', { hidden: '' }), covPre = el('cov-pre', {}, '', covView);
const profRow = el('prof-row'), profView = el('prof-view', { hidden: '' });
profView.kids.pre = [
  el('prof-pre0', { 'data-src': 'source/test/functions.zig', 'data-lines': '25:8.0' }, '', profView),
  el('prof-pre1', { 'data-src': '', 'data-lines': '90:20.0' }, '', profView),
];
const run = el('run', { 'data-target': 'vec_norm2' }), button = el('run-button', {}, 'Run', run);
const status = el('run-status', {}, '', run), result = el('run-result', { hidden: '' }, '', run);
Object.assign(doc.kids, {
  '#q': [q], '#hits': [hits], '.search': [search], '#theme': [theme], '#themes': [menu], '.themes': [themes],
  '#live': [live], '.src-hint[hidden]': [el('hint')], '.src-hint:not([hidden])': [el('no-server-hint')],
  '.codebox pre': [pre], '.codebox .copy': [copy], 'pre.code[data-lang="zig"]': [zig],
  '.repo[data-repo]:not([data-repo=""])': [repo], 'table.cov tr[data-src]': [covRow],
  'table.cov tr.src-view': [covView], 'table.cov tr.src-view pre': [covPre], 'table.prof tr.prof-row': [profRow],
  'table.prof tr.src-view': [profView], '.run': [run], '.run button': [button], '.run .status': [status],
  '.run .result': [result],
});

const answers = {
  '/api/ping': '{"module": "setu_classes", "version": "1.2.3", "python": "3.15"}',
  '/api/run': '{"ok": true, "steps": [{"source": "vec_norm2(Vec(3, 4))", "got": "25", "status": "ok"}]}',
  'https://api.github.com/repos/YoSTEALTH/Setu': '{"stargazers_count": 1250, "forks_count": 3}',
  'https://api.github.com/repos/YoSTEALTH/Setu/releases?per_page=10': '[{"tag_name": "v2026.10.28"}]',
  'source/test/functions.zig': 'const a = 1;\nconst b = 2;\n',  // a Profile source: `serve` has it, not the site
};
const storage = (name, kept) => ({
  getItem: key => kept[key] ?? null,
  setItem: (key, value) => say(`${name} ${key}=${JSON.stringify(value)}`),
});
let now = 0, timers = [];
Object.assign(globalThis, {
  document: doc,
  matchMedia: () => dark,
  getSelection: () => '',
  location: { hostname: '127.0.0.1', set href(url) { say(`go ${url}`); } },
  performance: { now: () => (now += 50) },
  setTimeout: (f, ms) => { say(`timer ${ms}`); timers.push(f); },
  fetch: async (url, init) => {
    if (url !== 'docs.wasm') say(`fetch ${url}${init ? ` ${init.method} ${JSON.stringify(init.body)}` : ''}`);
    if (url in answers) return new Response(answers[url]);
    try {
      const type = url.endsWith('.wasm') ? 'application/wasm' : 'text/plain';
      return new Response(await Deno.readFile(`${site}/${url}`), { headers: { 'Content-Type': type } });
    } catch (e) {
      return new Response('', { status: 404 });
    }
  },
});
Object.defineProperties(globalThis, {  // deno has its own (kept on disk): not these
  localStorage: { value: storage('localStorage', { palette: 'nord', theme: 'dark' }) },
  sessionStorage: { value: storage('sessionStorage', {}) },
  navigator: { value: { clipboard: { writeText: async text => say(`clipboard ${JSON.stringify(text)}`) } } },
});

const app = await Deno.readTextFile(`${site}/app.js`);
new Function(app)();
await settle();
fire(theme, 'click');  // the ◐ menu: open, an arrow key, a theme picked
fire(items[1], 'keydown', { key: 'ArrowDown' });
fire(items[2], 'click');
fire(theme, 'click');  // open again, closed by Escape
fire(doc, 'keydown', { key: 'Escape' });
fire(doc, 'keydown', { key: '/' });  // search
q.value = 'vec';
fire(q, 'input');
fire(q, 'keydown', { key: 'ArrowDown' });
fire(q, 'keydown', { key: 'Enter' });
fire(doc, 'click');
fire(copy, 'click');  // Copy
await settle();
timers.splice(0).forEach(f => f());
fire(covRow, 'click');  // the Coverage view: loaded, then hidden
await settle();
fire(covRow, 'click');
fire(profRow, 'click');  // the Profile view: two files, one fetched
await settle();
fire(button, 'click');  // Run
await settle();
dark.matches = true;
fire(dark, 'change', { matches: true });
console.log(log.join('\n'));
