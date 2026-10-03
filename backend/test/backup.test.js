// Tests de la sauvegarde GitHub (backup.js / start.js) avec un faux serveur GitHub local (port 4431).
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');
const { DatabaseSync } = require('node:sqlite');
const { configFromEnv, createBackup, isLocalDbEmpty, gitBlobSha } = require('../src/backup');

const PORT = 4431;
const TOKEN = 'github_pat_TEST_SECRET_0123456789abcdef';
const REPO = 'resto/sauvegardes';
const API = `http://127.0.0.1:${PORT}`;
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-backup-test-'));

// ---------- Faux GitHub (API git data + contents), en mémoire ----------
const gh = {
  blobs: new Map(),
  trees: new Map(), // sha → Map(chemin → sha blob)
  commits: new Map(), // sha → { tree, parents, message }
  refs: new Map(), // branche → sha commit
  requests: [],
  failNext: 0, // nombre de requêtes à couper (erreur réseau)
  reset() {
    this.blobs.clear();
    this.trees.clear();
    this.commits.clear();
    this.refs.clear();
    this.requests = [];
    this.failNext = 0;
  },
  id: () => crypto.randomBytes(20).toString('hex'),
  addBlob(buf) {
    const sha = gitBlobSha(buf);
    this.blobs.set(sha, buf);
    return sha;
  },
  /** Crée un commit contenant ces fichiers ({ chemin: Buffer }) sur la branche. */
  seed(files, branch = 'main') {
    const tree = new Map();
    for (const [p, buf] of Object.entries(files)) tree.set(p, this.addBlob(buf));
    const treeSha = this.id();
    this.trees.set(treeSha, tree);
    const sha = this.id();
    this.commits.set(sha, { tree: treeSha, parents: [], message: 'Sauvegarde initiale (n°1)' });
    this.refs.set(branch, sha);
    return sha;
  },
  headFiles(branch = 'main') {
    const c = this.commits.get(this.refs.get(branch));
    return c ? this.trees.get(c.tree) : null;
  },
  writes() {
    return this.requests.filter((r) => r.method !== 'GET');
  },
};

function json(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

const fake = http.createServer((req, res) => {
  let chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const url = new URL(req.url, API);
    gh.requests.push({ method: req.method, path: url.pathname });
    if (gh.failNext > 0) {
      gh.failNext--;
      req.socket.destroy();
      return;
    }
    if (req.headers.authorization !== `Bearer ${TOKEN}`) return json(res, 401, { message: `Bad credentials (${req.headers.authorization})` });
    const prefix = `/repos/${REPO}/`;
    if (!url.pathname.startsWith(prefix)) return json(res, 404, { message: 'Not Found' });
    const p = decodeURIComponent(url.pathname.slice(prefix.length));
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};
    const empty = gh.refs.size === 0;
    let m;
    if (req.method === 'GET' && (m = p.match(/^git\/ref\/heads\/(.+)$/))) {
      if (empty) return json(res, 409, { message: 'Git Repository is empty.' });
      const sha = gh.refs.get(m[1]);
      return sha ? json(res, 200, { object: { sha, type: 'commit' } }) : json(res, 404, { message: 'Not Found' });
    }
    if (req.method === 'GET' && (m = p.match(/^git\/commits\/(\w+)$/))) {
      const c = gh.commits.get(m[1]);
      return c ? json(res, 200, { sha: m[1], tree: { sha: c.tree }, message: c.message, parents: c.parents.map((sha) => ({ sha })) }) : json(res, 404, {});
    }
    if (req.method === 'GET' && (m = p.match(/^git\/trees\/(\w+)$/))) {
      const t = gh.trees.get(m[1]);
      if (!t) return json(res, 404, {});
      return json(res, 200, { sha: m[1], truncated: false, tree: [...t].map(([path, sha]) => ({ path, type: 'blob', mode: '100644', sha, size: gh.blobs.get(sha).length })) });
    }
    if (req.method === 'GET' && (m = p.match(/^git\/blobs\/(\w+)$/))) {
      const b = gh.blobs.get(m[1]);
      if (!b) return json(res, 404, {});
      if (/raw/.test(req.headers.accept || '')) {
        res.writeHead(200, { 'Content-Type': 'application/vnd.github.raw' });
        return res.end(b);
      }
      return json(res, 200, { sha: m[1], encoding: 'base64', content: b.toString('base64'), size: b.length });
    }
    if (req.method === 'POST' && p === 'git/blobs') {
      if (empty) return json(res, 409, { message: 'Git Repository is empty.' });
      return json(res, 201, { sha: gh.addBlob(Buffer.from(body.content, 'base64')) });
    }
    if (req.method === 'POST' && p === 'git/trees') {
      const t = new Map(body.base_tree ? gh.trees.get(body.base_tree) : []);
      for (const e of body.tree) t.set(e.path, e.sha);
      const sha = gh.id();
      gh.trees.set(sha, t);
      return json(res, 201, { sha });
    }
    if (req.method === 'POST' && p === 'git/commits') {
      const sha = gh.id();
      gh.commits.set(sha, { tree: body.tree, parents: body.parents, message: body.message });
      return json(res, 201, { sha });
    }
    if (req.method === 'PATCH' && (m = p.match(/^git\/refs\/heads\/(.+)$/))) {
      const cur = gh.refs.get(m[1]);
      if (!cur) return json(res, 422, { message: 'Reference does not exist' });
      if (!body.force && gh.commits.get(body.sha).parents[0] !== cur) return json(res, 422, { message: 'Update is not a fast forward' });
      gh.refs.set(m[1], body.sha);
      return json(res, 200, { object: { sha: body.sha } });
    }
    if (req.method === 'POST' && p === 'git/refs') {
      const branch = body.ref.replace('refs/heads/', '');
      if (gh.refs.has(branch)) return json(res, 422, { message: 'Reference already exists' });
      gh.refs.set(branch, body.sha);
      return json(res, 201, { ref: body.ref });
    }
    if (req.method === 'PUT' && (m = p.match(/^contents\/(.+)$/))) {
      const branch = body.branch || 'main';
      const parent = gh.refs.get(branch);
      const t = new Map(parent ? gh.trees.get(gh.commits.get(parent).tree) : []);
      t.set(m[1], gh.addBlob(Buffer.from(body.content, 'base64')));
      const treeSha = gh.id();
      gh.trees.set(treeSha, t);
      const sha = gh.id();
      gh.commits.set(sha, { tree: treeSha, parents: parent ? [parent] : [], message: body.message });
      gh.refs.set(branch, sha);
      return json(res, 201, { commit: { sha } });
    }
    json(res, 404, { message: 'Not Found' });
  });
});

// ---------- Outils ----------
const logs = [];
const logger = {
  info: (message, data) => logs.push({ level: 'info', message, data }),
  warn: (message, data) => logs.push({ level: 'warn', message, data }),
  error: (message, data) => logs.push({ level: 'error', message, data }),
};

let n = 0;
/** Dossier de travail neuf : { dir, dbPath, uploadsDir, cfg }. */
function workspace(overrides = {}) {
  const dir = path.join(TMP, `w${++n}`);
  fs.mkdirSync(dir, { recursive: true });
  const cfg = {
    ...configFromEnv({ BACKUP_GITHUB_REPO: REPO, BACKUP_GITHUB_TOKEN: TOKEN, BACKUP_GITHUB_API_URL: API }),
    dbPath: path.join(dir, 'app.db'),
    uploadsDir: path.join(dir, 'uploads'),
    ...overrides,
  };
  return { dir, dbPath: cfg.dbPath, uploadsDir: cfg.uploadsDir, cfg };
}

function makeDb(file, rows = ['a']) {
  const db = new DatabaseSync(file);
  db.exec('CREATE TABLE IF NOT EXISTS t (x TEXT)');
  for (const r of rows) db.prepare('INSERT INTO t VALUES (?)').run(r);
  db.close();
}

/** Base telle qu'envoyée par la sauvegarde (instantané VACUUM INTO). */
function dbBuffer(rows) {
  const f = path.join(TMP, `buf-${++n}.db`);
  makeDb(f, rows);
  const db = new DatabaseSync(f);
  db.prepare('VACUUM INTO ?').run(`${f}.snap`);
  db.close();
  return fs.readFileSync(`${f}.snap`);
}

const readRows = (file) => {
  const db = new DatabaseSync(file, { readOnly: true });
  try {
    return db.prepare('SELECT x FROM t ORDER BY rowid').all().map((r) => r.x);
  } finally {
    db.close();
  }
};

test.before(() => new Promise((r) => fake.listen(PORT, '127.0.0.1', r)));
test.after(() => {
  fake.close();
  try {
    fs.rmSync(TMP, { recursive: true, force: true });
  } catch {}
});
test.beforeEach(() => gh.reset());

// ---------- Tests ----------
test('configuration : absente, incomplète, adresse complète', () => {
  assert.equal(configFromEnv({}), null);
  const warns = [];
  const log = { warn: (m) => warns.push(m) };
  assert.equal(configFromEnv({ BACKUP_GITHUB_REPO: 'a/b' }, log), null);
  assert.equal(configFromEnv({ BACKUP_GITHUB_TOKEN: TOKEN }, log), null);
  assert.equal(warns.length, 2);
  assert.ok(!warns.join(' ').includes(TOKEN));
  const c = configFromEnv({ BACKUP_GITHUB_REPO: 'https://github.com/resto/sauvegardes.git', BACKUP_GITHUB_TOKEN: TOKEN });
  assert.equal(c.repo, 'resto/sauvegardes');
  assert.equal(c.branch, 'main');
  assert.equal(c.prefix, 'ivrivrii');
  assert.equal(c.intervalMs, 60000);
  assert.equal(c.apiBase, 'https://api.github.com');
});

test('restauration : base vide remplacée (avec -wal/-shm), photos restaurées', async () => {
  const w = workspace();
  // Base « vide » : fichier de 0 octet + -wal/-shm résiduels incohérents.
  fs.writeFileSync(w.dbPath, '');
  fs.writeFileSync(`${w.dbPath}-wal`, 'n’importe quoi');
  fs.writeFileSync(`${w.dbPath}-shm`, 'x');
  assert.equal(isLocalDbEmpty(w.dbPath), true);
  gh.seed({
    'ivrivrii/ivrivrii.db': dbBuffer(['commande 1', 'commande 2']),
    'ivrivrii/uploads/plat.jpg': Buffer.from('jpeg-plat'),
    'ivrivrii/uploads/avatars/u1.png': Buffer.from('png-avatar'),
    'ivrivrii/uploads/../evasion.txt': Buffer.from('non'),
    'autre/fichier.txt': Buffer.from('ignoré'),
  });
  const b = createBackup(w.cfg, { log: logger });
  const r = await b.restore();
  assert.equal(r.db, true);
  assert.equal(r.uploads, 2);
  assert.deepEqual(readRows(w.dbPath), ['commande 1', 'commande 2']);
  assert.equal(fs.existsSync(`${w.dbPath}-wal`), false);
  assert.equal(fs.existsSync(`${w.dbPath}-shm`), false);
  assert.equal(fs.readFileSync(path.join(w.uploadsDir, 'plat.jpg'), 'utf8'), 'jpeg-plat');
  assert.equal(fs.readFileSync(path.join(w.uploadsDir, 'avatars', 'u1.png'), 'utf8'), 'png-avatar');
  assert.equal(fs.existsSync(path.join(w.dir, 'evasion.txt')), false);
  assert.equal(gh.writes().length, 0);
  // Rien n'a changé depuis la restauration : aucun envoi.
  const again = await b.run();
  assert.equal(again.pushed, false, JSON.stringify(again));
  assert.equal(gh.writes().length, 0);
  await b.stop();
});

test('restauration : base absente', async () => {
  const w = workspace({ dbPath: path.join(TMP, 'nouveau-dossier', 'data.db') });
  gh.seed({ 'ivrivrii/ivrivrii.db': dbBuffer(['x']) });
  const r = await createBackup(w.cfg, { log: logger }).restore();
  assert.equal(r.db, true);
  assert.deepEqual(readRows(w.cfg.dbPath), ['x']);
});

test('pas de restauration si la base locale n’est pas vide (photos manquantes quand même)', async () => {
  const w = workspace();
  makeDb(w.dbPath, ['locale']);
  fs.mkdirSync(w.uploadsDir, { recursive: true });
  fs.writeFileSync(path.join(w.uploadsDir, 'a.jpg'), 'version locale');
  gh.seed({
    'ivrivrii/ivrivrii.db': dbBuffer(['distante']),
    'ivrivrii/uploads/a.jpg': Buffer.from('version distante'),
    'ivrivrii/uploads/b.jpg': Buffer.from('b'),
  });
  const r = await createBackup(w.cfg, { log: logger }).restore();
  assert.equal(r.db, false);
  assert.deepEqual(readRows(w.dbPath), ['locale']);
  assert.equal(fs.readFileSync(path.join(w.uploadsDir, 'a.jpg'), 'utf8'), 'version locale');
  assert.equal(fs.readFileSync(path.join(w.uploadsDir, 'b.jpg'), 'utf8'), 'b');
});

test('sauvegarde : dépôt vide, envoi après changement, rien si inchangé, historique', async () => {
  const w = workspace();
  makeDb(w.dbPath, ['a']);
  const b = createBackup(w.cfg, { log: logger });
  await b.restore();
  const r1 = await b.run();
  assert.equal(r1.pushed, true, JSON.stringify(r1));
  assert.deepEqual(r1.files, ['ivrivrii/ivrivrii.db']);
  // Le dépôt vide a été initialisé via l'API contents puis le commit de sauvegarde ajouté.
  assert.ok(gh.headFiles().has('ivrivrii/LISEZMOI.md'));
  const pushed = gh.blobs.get(gh.headFiles().get('ivrivrii/ivrivrii.db'));
  const copy = path.join(w.dir, 'copie.db');
  fs.writeFileSync(copy, pushed);
  assert.deepEqual(readRows(copy), ['a']);

  // Inchangée : aucune requête d'écriture.
  const before = gh.writes().length;
  const r2 = await b.run();
  assert.equal(r2.pushed, false);
  assert.equal(gh.writes().length, before);

  // Écriture par une autre connexion (le serveur) → nouvel envoi, enchaîné au précédent.
  makeDb(w.dbPath, ['b']);
  const head1 = gh.refs.get('main');
  const r3 = await b.run();
  assert.equal(r3.pushed, true);
  const c = gh.commits.get(gh.refs.get('main'));
  assert.deepEqual(c.parents, [head1]);
  assert.match(c.message, /n°2/);
  fs.writeFileSync(copy, gh.blobs.get(gh.headFiles().get('ivrivrii/ivrivrii.db')));
  assert.deepEqual(readRows(copy), ['a', 'b']);
  await b.stop();
});

test('sauvegarde : base ouverte en WAL par une autre connexion (instantané cohérent)', async () => {
  const w = workspace();
  const server = new DatabaseSync(w.dbPath);
  server.exec('PRAGMA journal_mode = WAL; CREATE TABLE t (x TEXT); INSERT INTO t VALUES (1);');
  const b = createBackup(w.cfg, { log: logger });
  await b.restore();
  assert.equal((await b.run()).pushed, true);
  server.exec('INSERT INTO t VALUES (2)'); // reste dans le -wal
  assert.equal((await b.run()).pushed, true);
  const copy = path.join(w.dir, 'copie.db');
  fs.writeFileSync(copy, gh.blobs.get(gh.headFiles().get('ivrivrii/ivrivrii.db')));
  assert.deepEqual(readRows(copy), ['1', '2']);
  server.close();
  await b.stop();
});

test('photos : seules les nouvelles sont envoyées', async () => {
  const w = workspace();
  makeDb(w.dbPath);
  fs.mkdirSync(path.join(w.uploadsDir, 'avatars'), { recursive: true });
  fs.writeFileSync(path.join(w.uploadsDir, '.gitkeep'), '');
  fs.writeFileSync(path.join(w.uploadsDir, 'p1.jpg'), 'photo 1');
  const b = createBackup(w.cfg, { log: logger });
  await b.restore();
  const r1 = await b.run();
  assert.deepEqual(r1.files.sort(), ['ivrivrii/ivrivrii.db', 'ivrivrii/uploads/p1.jpg']);
  fs.writeFileSync(path.join(w.uploadsDir, 'avatars', 'a1.png'), 'avatar');
  const r2 = await b.run();
  assert.deepEqual(r2.files, ['ivrivrii/uploads/avatars/a1.png']);
  const files = gh.headFiles();
  assert.ok(files.has('ivrivrii/uploads/p1.jpg'));
  assert.ok(!files.has('ivrivrii/uploads/.gitkeep'));
  assert.equal(gh.blobs.get(files.get('ivrivrii/uploads/avatars/a1.png')).toString(), 'avatar');
  assert.equal((await b.run()).pushed, false);
  // Une photo déjà présente dans le dépôt n'est pas renvoyée après un redémarrage.
  const b2 = createBackup(w.cfg, { log: logger });
  await b2.restore();
  const writes = gh.writes().length;
  assert.equal((await b2.run()).pushed, false);
  assert.equal(gh.writes().length, writes);
  await b.stop();
  await b2.stop();
});

test('fichier de plus de 1 Mo : aller-retour sauvegarde → restauration', async () => {
  const w = workspace();
  makeDb(w.dbPath);
  fs.mkdirSync(w.uploadsDir, { recursive: true });
  const big = crypto.randomBytes(3 * 1024 * 1024);
  fs.writeFileSync(path.join(w.uploadsDir, 'grande.jpg'), big);
  const b = createBackup(w.cfg, { log: logger });
  await b.restore();
  assert.equal((await b.run()).pushed, true);
  await b.stop();
  const w2 = workspace();
  const r = await createBackup(w2.cfg, { log: logger }).restore();
  assert.equal(r.db, true);
  assert.ok(fs.readFileSync(path.join(w2.uploadsDir, 'grande.jpg')).equals(big));
});

test('reprise après erreur réseau (sans exception)', async () => {
  const w = workspace();
  makeDb(w.dbPath, ['a']);
  gh.seed({ 'ivrivrii/LISEZMOI.md': Buffer.from('x') });
  const b = createBackup(w.cfg, { log: logger, retryBaseMs: 100 });
  await b.restore();
  gh.failNext = 1;
  const r1 = await b.run();
  assert.ok(r1.error, JSON.stringify(r1));
  assert.ok(b.state.backoffUntil > Date.now());
  assert.equal((await b.run()).skipped, 'backoff');
  await new Promise((r) => setTimeout(r, 150));
  const r2 = await b.run();
  assert.equal(r2.pushed, true, JSON.stringify(r2));
  assert.ok(gh.headFiles().has('ivrivrii/ivrivrii.db'));
  assert.equal(b.state.failures, 0);
  await b.stop();
});

test('dépôt injoignable au démarrage avec une base vide : rien n’écrase la sauvegarde', async () => {
  const w = workspace();
  gh.seed({ 'ivrivrii/ivrivrii.db': dbBuffer(['précieux']) });
  gh.failNext = 3; // les 3 essais de restauration échouent
  const alerts = [];
  const b = createBackup(w.cfg, { log: logger, alert: (m) => alerts.push(m), restoreDelaysMs: [10, 10] });
  const r = await b.restore();
  assert.equal(r.db, false);
  assert.equal(b.state.hold, true);
  makeDb(w.dbPath, ['base neuve']); // le serveur démarre sur une base neuve
  const r2 = await b.run();
  assert.equal(r2.skipped, 'hold');
  assert.equal(gh.writes().length, 0);
  assert.equal(alerts.length, 1);
  assert.deepEqual(readRows(path.join(w.dir, 'app.db')), ['base neuve']);
  const remote = path.join(w.dir, 'remote.db');
  fs.writeFileSync(remote, gh.blobs.get(gh.headFiles().get('ivrivrii/ivrivrii.db')));
  assert.deepEqual(readRows(remote), ['précieux']);
  await b.stop();
});

test('arrêt (SIGTERM) : dernière sauvegarde envoyée même pendant une attente', async () => {
  const w = workspace();
  makeDb(w.dbPath, ['a']);
  const b = createBackup(w.cfg, { log: logger, retryBaseMs: 60000 });
  await b.restore();
  b.start();
  gh.failNext = 1;
  await b.run(); // échec → attente d'une minute
  makeDb(w.dbPath, ['b']);
  const r = await b.stop();
  assert.equal(r.pushed, true, JSON.stringify(r));
  const copy = path.join(w.dir, 'copie.db');
  fs.writeFileSync(copy, gh.blobs.get(gh.headFiles().get('ivrivrii/ivrivrii.db')));
  assert.deepEqual(readRows(copy), ['a', 'b']);
});

test('historique borné : nouveau commit sans parent au-delà de maxCommits', async () => {
  const w = workspace({ maxCommits: 2 });
  makeDb(w.dbPath, ['1']);
  const b = createBackup(w.cfg, { log: logger });
  await b.restore();
  for (const v of ['2', '3', '4']) {
    assert.equal((await b.run()).pushed, true);
    makeDb(w.dbPath, [v]);
  }
  // Commits : init LISEZMOI (sans n°) → n°1 → n°2 → n°1 sans parent.
  const head = gh.commits.get(gh.refs.get('main'));
  assert.deepEqual(head.parents, []);
  assert.match(head.message, /n°1\).*nouvel historique/);
  assert.ok(gh.headFiles().has('ivrivrii/LISEZMOI.md'));
  await b.stop();
});

test('jeton refusé (401) : erreur claire, jeton jamais journalisé', async () => {
  const w = workspace({ token: 'mauvais-jeton-SECRET' });
  makeDb(w.dbPath);
  const alerts = [];
  const b = createBackup(w.cfg, { log: logger, alert: (m) => alerts.push(m) });
  await b.restore();
  const r = await b.run();
  assert.match(r.error, /401/);
  assert.ok(!r.error.includes('mauvais-jeton-SECRET'));
  assert.equal(alerts.length, 1);
  const all = JSON.stringify(logs);
  assert.ok(!all.includes('mauvais-jeton-SECRET'), 'jeton dans les journaux');
  await b.stop();
});

test('start.js : restauration avant ouverture de la base puis sauvegarde (port 4430)', async () => {
  const dir = path.join(TMP, 'e2e');
  fs.mkdirSync(dir, { recursive: true });
  // Sauvegarde distante : une base minimale avec un réglage reconnaissable.
  const src = path.join(dir, 'src.db');
  const s = new DatabaseSync(src);
  s.exec(`CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          INSERT INTO settings VALUES ('restaurant_address', 'Adresse restaurée');`);
  s.close();
  gh.seed({ 'ivrivrii/ivrivrii.db': fs.readFileSync(src) });
  const env = {
    ...process.env,
    DB_PATH: path.join(dir, 'api.db'),
    LOG_DIR: path.join(dir, 'logs'),
    LOG_CONSOLE: '0',
    PORT: '4430',
    NODE_ENV: 'test',
    BACKUP_GITHUB_REPO: REPO,
    BACKUP_GITHUB_TOKEN: TOKEN,
    BACKUP_GITHUB_API_URL: API,
    BACKUP_INTERVAL_SECONDS: '1',
  };
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'src', 'start.js')], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  child.stderr.on('data', (d) => (out += d));
  try {
    let settings;
    for (let i = 0; i < 100 && !settings; i++) {
      await new Promise((r) => setTimeout(r, 100));
      try {
        settings = await (await fetch('http://127.0.0.1:4430/api/settings')).json();
      } catch {}
    }
    assert.ok(settings, out);
    assert.equal(settings.restaurant_address, 'Adresse restaurée');
    // La base restaurée a été migrée / complétée par le serveur → sauvegarde envoyée.
    let pushed = false;
    for (let i = 0; i < 100 && !pushed; i++) {
      await new Promise((r) => setTimeout(r, 100));
      pushed = gh.writes().some((r) => r.method === 'PATCH');
    }
    assert.ok(pushed, out);
    const copy = path.join(dir, 'copie.db');
    fs.writeFileSync(copy, gh.blobs.get(gh.headFiles().get('ivrivrii/ivrivrii.db')));
    const db = new DatabaseSync(copy, { readOnly: true });
    assert.ok(db.prepare('SELECT COUNT(*) AS n FROM users').get().n >= 1);
    assert.equal(db.prepare(`SELECT value FROM settings WHERE key = 'restaurant_address'`).get().value, 'Adresse restaurée');
    db.close();
    assert.ok(!out.includes(TOKEN));
    for (const f of fs.readdirSync(env.LOG_DIR)) assert.ok(!fs.readFileSync(path.join(env.LOG_DIR, f), 'utf8').includes(TOKEN));
  } finally {
    child.kill();
    await new Promise((r) => child.once('exit', r));
  }
});

test('aucun jeton dans les journaux de tous les tests', () => {
  assert.ok(logs.length > 0);
  assert.ok(!JSON.stringify(logs).includes(TOKEN));
});
