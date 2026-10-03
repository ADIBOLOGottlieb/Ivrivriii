// Comptes : normalisation des numéros, jetons (iid / tv), codes OTP, admin par défaut (node --test).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-auth-'));
process.env.DB_PATH = path.join(dir, 'auth.db');
process.env.LOG_DIR = path.join(dir, 'logs');
process.env.LOG_CONSOLE = '0';
process.env.JWT_SECRET = 'secret-de-test';
process.env.SMS_PROVIDER = 'none';

const jwt = require('jsonwebtoken');
const { db } = require('../src/db');
const auth = require('../src/auth');
const { _otp: otp } = require('../src/account');
const { createDefaultAdmin } = require('../src/seed');

/** Appelle requireAuth avec un jeton ; renvoie { status, body } ou { next: true, user }. */
function callAuth(token) {
  return new Promise((resolve) => {
    const req = { headers: { authorization: `Bearer ${token}` } };
    const res = {
      statusCode: 200,
      status(c) { this.statusCode = c; return this; },
      json(b) { resolve({ status: this.statusCode, body: b }); },
    };
    auth.requireAuth(req, res, () => resolve({ next: true, user: req.user }));
  });
}

function addUser(phone, extra = {}) {
  const info = db
    .prepare('INSERT INTO users (name, phone, password_hash, role) VALUES (?, ?, ?, ?)')
    .run(extra.name || 'Test', phone, 'x', extra.role || 'customer');
  return db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid);
}

test('normalizePhone : numéros togolais et étrangers', () => {
  const n = auth.normalizePhone;
  for (const v of ['90000001', '90 00 00 01', '90-00-00-01', '+22890000001', '+228 90 00 00 01', '0022890000001', '22890000001', '00 228 90.00.00.01']) {
    assert.equal(n(v), '+22890000001', v);
  }
  assert.equal(n('+33 6 12 34 56 78'), '+33612345678');
  assert.equal(n('0033612345678'), '+33612345678');
  assert.equal(n('0700000000'), '0700000000');
  assert.equal(n('supprime-3-abc'), '');
  assert.equal(n(''), '');
  assert.equal(n(null), '');
  assert.equal(n({}), '');
  assert.ok(auth.isValidPhone('+22890000001'));
  assert.ok(!auth.isValidPhone('+123'));
});

test('migration des numéros : normalisés, doublons renommés (le plus ancien garde le numéro), audit', () => {
  const a = addUser('91000001');
  const b = addUser('+228 91 00 00 01');
  const c = addUser('22891000001');
  const d = addUser('supprime-9-abc');
  const e = addUser('92 00 00 02');
  const r = auth.migratePhones();
  assert.deepEqual(r, { updated: 2, duplicates: 2 });
  const phone = (u) => db.prepare('SELECT phone FROM users WHERE id = ?').get(u.id).phone;
  assert.equal(phone(a), '+22891000001');
  assert.equal(phone(b), `doublon-${b.id}-+228 91 00 00 01`);
  assert.equal(phone(c), `doublon-${c.id}-22891000001`);
  assert.equal(phone(d), 'supprime-9-abc');
  assert.equal(phone(e), '+22892000002');
  const logs = db.prepare(`SELECT * FROM audit_logs WHERE action = 'phone_duplicate_renamed'`).all();
  assert.equal(logs.length, 2);
  assert.deepEqual(auth.migratePhones(), { updated: 0, duplicates: 0 }, 'idempotente');
});

test('jetons : iid et tv vérifiés', async () => {
  const u = addUser('+22893000003');
  const token = auth.signToken(u);
  const payload = jwt.decode(token);
  assert.equal(payload.iid, auth.instanceId());
  assert.equal(payload.tv, 0);
  assert.equal(db.prepare(`SELECT value FROM settings WHERE key = 'db_instance_id'`).get().value, auth.instanceId());

  const ok = await callAuth(token);
  assert.equal(ok.next, true);
  assert.equal(ok.user.id, u.id);

  // Jeton d'une autre base (même id, même clé, autre iid) : refusé.
  const foreign = jwt.sign({ id: u.id, role: 'customer', iid: 'autre-base', tv: 0 }, 'secret-de-test', { expiresIn: '1h' });
  assert.equal((await callAuth(foreign)).status, 401);
  // Ancien format sans iid : refusé.
  const legacy = jwt.sign({ id: u.id, role: 'customer' }, 'secret-de-test', { expiresIn: '1h' });
  assert.equal((await callAuth(legacy)).status, 401);

  // Changement de mot de passe : token_version + 1 → l'ancien jeton est refusé, le nouveau accepté.
  auth.bumpTokenVersion(u.id);
  assert.equal((await callAuth(token)).status, 401);
  const fresh = auth.signToken({ id: u.id, role: 'customer' });
  assert.equal(jwt.decode(fresh).tv, 1);
  assert.equal((await callAuth(fresh)).next, true);
});

test('OTP : code correct → jeton à usage unique', () => {
  const phone = '+22894000001';
  const { code } = otp.issueOtp(phone, 'register');
  assert.match(code, /^\d{6}$/);
  const row = db.prepare('SELECT * FROM otp_codes WHERE phone = ? ORDER BY id DESC').get(phone);
  assert.notEqual(row.code_hash, code, 'code haché');
  const token = otp.verifyOtp(phone, 'register', code);
  assert.throws(() => otp.checkOtpCode(phone, 'register', code), /expiré|invalide/i, 'code consommé');
  assert.throws(() => otp.consumeOtpToken(phone, 'reset', token), /expirée/, 'autre usage refusé');
  assert.throws(() => otp.consumeOtpToken('+22894000009', 'register', token), /expirée/, 'autre numéro refusé');
  otp.consumeOtpToken(phone, 'register', token);
  assert.throws(() => otp.consumeOtpToken(phone, 'register', token), /expirée/, 'usage unique');
});

test('OTP : 5 essais maximum, puis même le bon code est refusé', () => {
  const phone = '+22894000002';
  const { code } = otp.issueOtp(phone, 'reset');
  const wrong = code === '000000' ? '111111' : '000000';
  for (let i = 1; i <= 4; i++) assert.throws(() => otp.checkOtpCode(phone, 'reset', wrong), new RegExp(`${5 - i} essai`));
  assert.throws(() => otp.checkOtpCode(phone, 'reset', wrong), /Trop d'essais/);
  assert.throws(() => otp.checkOtpCode(phone, 'reset', code), /expiré|invalide/i);
});

test('OTP : code expiré (10 min), jeton expiré (15 min), nouveau code invalide l\'ancien', () => {
  const phone = '+22894000003';
  let { id, code } = otp.issueOtp(phone, 'register');
  db.prepare('UPDATE otp_codes SET expires_at = ? WHERE id = ?').run(Date.now() - 1, id);
  assert.throws(() => otp.checkOtpCode(phone, 'register', code), /expiré/);

  const first = otp.issueOtp(phone, 'register');
  const second = otp.issueOtp(phone, 'register');
  assert.throws(() => otp.checkOtpCode(phone, 'register', first.code === second.code ? 'xxxxxx' : first.code), /incorrect|invalide/i);

  ({ id, code } = otp.issueOtp(phone, 'register'));
  const token = otp.verifyOtp(phone, 'register', code);
  db.prepare('UPDATE otp_codes SET token_expires_at = ? WHERE id = ?').run(Date.now() - 1, id);
  assert.throws(() => otp.consumeOtpToken(phone, 'register', token), /expirée/);
  const ttl = db.prepare('SELECT expires_at - created_at AS t FROM otp_codes WHERE id = ?').get(id).t;
  assert.equal(ttl, 10 * 60 * 1000);
});

test('OTP : limite par numéro (3 codes / 15 min)', () => {
  const phone = '+22894000004';
  for (let i = 0; i < 3; i++) {
    otp.checkOtpLimits(phone, '10.0.0.1');
    otp.issueOtp(phone, 'reset', { ip: '10.0.0.1' });
  }
  assert.throws(() => otp.checkOtpLimits(phone, '10.0.0.2'), (e) => e.status === 429);
});

test('admin par défaut : refusé en production sans ADMIN_PASSWORD', () => {
  db.prepare(`DELETE FROM users WHERE role = 'admin'`).run();
  const env = { ...process.env };
  try {
    process.env.NODE_ENV = 'production';
    delete process.env.ADMIN_PASSWORD;
    const errors = [];
    const orig = console.error;
    console.error = (m) => errors.push(m);
    try {
      assert.equal(createDefaultAdmin(), false);
    } finally {
      console.error = orig;
    }
    assert.match(errors.join('\n'), /ADMIN_PASSWORD/);
    assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM users WHERE role = 'admin'`).get().n, 0);

    process.env.ADMIN_PASSWORD = 'Un-Vrai-Mot-De-Passe';
    process.env.ADMIN_PHONE = '+228 99 00 00 00';
    assert.equal(createDefaultAdmin(), true);
    assert.equal(db.prepare(`SELECT phone FROM users WHERE role = 'admin'`).get().phone, '+22899000000');
  } finally {
    for (const k of ['NODE_ENV', 'ADMIN_PASSWORD', 'ADMIN_PHONE']) {
      if (env[k] === undefined) delete process.env[k];
      else process.env[k] = env[k];
    }
  }
});

test.after(() => {
  db.close();
  fs.rmSync(dir, { recursive: true, force: true });
});
