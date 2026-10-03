// Routes de comptes : inscription (CGU, OTP), connexion sans énumération, mot de passe oublié /
// réinitialisation (SMS, repli admin), changement de mot de passe, pages légales (node --test).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-authr-'));
process.env.DB_PATH = path.join(dir, 'routes.db');
process.env.LOG_DIR = path.join(dir, 'logs');
process.env.LOG_CONSOLE = '0';
process.env.JWT_SECRET = 'secret-de-test';
process.env.SMS_PROVIDER = 'none';

const express = require('express');
const bcrypt = require('bcryptjs');
const { db } = require('../src/db');
const account = require('../src/account');

// Faux prestataire SMS : enregistre les messages, peut échouer à la demande.
const sms = { messages: [], fail: false };
const smsServer = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  sms.messages.push({ to: url.searchParams.get('to'), text: url.searchParams.get('msg') });
  res.writeHead(sms.fail ? 500 : 200).end('ok');
});

let base;
let server;
const call = async (method, p, body, token) => {
  const r = await fetch(`${base}${p}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let data = text;
  try { data = JSON.parse(text); } catch {}
  return { status: r.status, data, headers: r.headers };
};
const useSms = (on) => {
  process.env.SMS_PROVIDER = on ? 'http' : 'none';
  process.env.SMS_HTTP_URL = on ? `http://127.0.0.1:${smsServer.address().port}/send?to={phone}&msg={text}` : '';
};
const lastCode = () => sms.messages.at(-1).text.match(/\d{6}/)[0];
const waitFor = async (fn) => { for (let i = 0; i < 50 && !fn(); i++) await new Promise((r) => setTimeout(r, 20)); };

let adminToken;

test.before(async () => {
  await new Promise((r) => smsServer.listen(0, '127.0.0.1', r));
  const app = express();
  app.set('trust proxy', 'loopback');
  app.use(express.json());
  app.use(account.router);
  server = app.listen(0, '127.0.0.1');
  await new Promise((r) => server.once('listening', r));
  base = `http://127.0.0.1:${server.address().port}`;
  db.prepare(`INSERT INTO users (name, phone, password_hash, role) VALUES ('Admin', '0700000000', ?, 'admin')`)
    .run(bcrypt.hashSync('admin123', 4));
  adminToken = (await call('POST', '/api/auth/login', { phone: '0700000000', password: 'admin123' })).data.token;
  assert.ok(adminToken);
});

test('inscription : CGU obligatoires, numéro normalisé, doublon refusé, types vérifiés', async () => {
  const body = { name: 'Ama', phone: '90 00 00 01', password: 'secret1' };
  let r = await call('POST', '/api/auth/register', body);
  assert.equal(r.status, 400);
  assert.match(r.data.error, /conditions/);
  r = await call('POST', '/api/auth/register', { ...body, accept_terms: 'oui' });
  assert.equal(r.status, 400);
  r = await call('POST', '/api/auth/register', { ...body, name: 42, accept_terms: true });
  assert.equal(r.status, 400);
  r = await call('POST', '/api/auth/register', { ...body, accept_terms: true });
  assert.equal(r.status, 201);
  assert.equal(r.data.user.phone, '+22890000001');
  assert.equal(r.data.user.phone_verified, false);
  assert.ok(r.data.user.terms_accepted_at);
  assert.equal(r.data.user.terms_version, '2026-10');
  r = await call('POST', '/api/auth/register', { ...body, phone: '+22890000001', accept_terms: true });
  assert.equal(r.status, 409);
});

test('connexion : numéro saisi librement, pas d\'énumération', async () => {
  let r = await call('POST', '/api/auth/login', { phone: '+228 90-00-00-01', password: 'secret1' });
  assert.equal(r.status, 200);
  assert.ok(r.data.token && r.data.user.id);
  const wrong = await call('POST', '/api/auth/login', { phone: '90000001', password: 'mauvais' });
  const unknown = await call('POST', '/api/auth/login', { phone: '99999999', password: 'mauvais' });
  assert.equal(wrong.status, 401);
  assert.equal(unknown.status, 401);
  assert.deepEqual(wrong.data, unknown.data);
  r = await call('POST', '/api/auth/login', { phone: { $ne: 1 }, password: ['x'] });
  assert.equal(r.status, 401);
});

test('changement de mot de passe : nouveau jeton, autres appareils déconnectés', async () => {
  const a = (await call('POST', '/api/auth/login', { phone: '90000001', password: 'secret1' })).data.token;
  const b = (await call('POST', '/api/auth/login', { phone: '90000001', password: 'secret1' })).data.token;
  const r = await call('PUT', '/api/auth/me/password', { old_password: 'secret1', new_password: 'secret2' }, a);
  assert.equal(r.status, 200);
  assert.ok(r.data.token && r.data.user);
  assert.equal((await call('GET', '/api/auth/me', null, a)).status, 401);
  assert.equal((await call('GET', '/api/auth/me', null, b)).status, 401);
  assert.equal((await call('GET', '/api/auth/me', null, r.data.token)).status, 200);
});

test('mot de passe oublié sans SMS : demande chez l\'admin, code valable, jetons révoqués', async () => {
  useSms(false);
  const old = (await call('POST', '/api/auth/login', { phone: '90000001', password: 'secret2' })).data.token;
  const unknown = await call('POST', '/api/auth/password/forgot', { phone: '98 76 54 32' });
  let r = await call('POST', '/api/auth/password/forgot', { phone: '90 00 00 01' });
  assert.equal(r.status, 200);
  assert.deepEqual(r.data, { sent: true, channel: 'admin' });
  assert.deepEqual(unknown.data, r.data, 'même réponse pour un numéro inconnu');

  assert.equal((await call('GET', '/api/admin/password-resets', null, old)).status, 403);
  const list = (await call('GET', '/api/admin/password-resets', null, adminToken)).data;
  assert.equal(list.length, 1);
  const req = list[0];
  assert.equal(req.phone, '+22890000001');
  assert.match(req.code, /^\d{6}$/);
  assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM alerts WHERE type = 'password_reset' AND resolved = 0`).get().n, 1);

  r = await call('POST', '/api/auth/password/reset', { phone: '90000001', code: req.code === '000000' ? '111111' : '000000', new_password: 'nouveau1' });
  assert.equal(r.status, 400);
  r = await call('POST', '/api/auth/password/reset', { phone: '90000001', code: req.code, new_password: 'court' });
  assert.equal(r.status, 400);
  assert.equal((await call('POST', `/api/admin/password-resets/${req.id}/done`, null, adminToken)).status, 200);
  assert.equal((await call('GET', '/api/admin/password-resets', null, adminToken)).data.length, 0);
  r = await call('POST', '/api/auth/password/reset', { phone: '+22890000001', code: req.code, new_password: 'nouveau1' });
  assert.equal(r.status, 200);
  assert.ok(r.data.token);
  assert.equal((await call('GET', '/api/auth/me', null, old)).status, 401, 'ancienne session fermée');
  assert.equal((await call('GET', '/api/auth/me', null, r.data.token)).status, 200);
  assert.equal((await call('POST', '/api/auth/login', { phone: '90000001', password: 'nouveau1' })).status, 200);
  r = await call('POST', '/api/auth/password/reset', { phone: '90000001', code: req.code, new_password: 'encore1' });
  assert.equal(r.status, 400, 'code à usage unique');
  // Numéro inconnu : le code ne fonctionne jamais.
  r = await call('POST', '/api/auth/password/reset', { phone: '98765432', code: '123456', new_password: 'nouveau1' });
  assert.equal(r.status, 400);
  assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM alerts WHERE type = 'password_reset' AND resolved = 0`).get().n, 0);
});

test('mot de passe oublié avec SMS : code envoyé par SMS, invisible pour l\'admin ; échec SMS → repli admin', async () => {
  useSms(true);
  db.prepare('DELETE FROM otp_codes').run(); // limites par numéro remises à zéro
  let r = await call('POST', '/api/auth/otp/request', { phone: '90000001', purpose: 'reset' });
  assert.deepEqual(r.data, { sent: true, channel: 'sms' });
  await waitFor(() => sms.messages.length === 1);
  assert.equal(sms.messages[0].to, '+22890000001');
  assert.equal((await call('GET', '/api/admin/password-resets', null, adminToken)).data.length, 0);
  const v = await call('POST', '/api/auth/otp/verify', { phone: '90000001', code: lastCode(), purpose: 'reset' });
  assert.equal(v.status, 200);
  r = await call('POST', '/api/auth/password/reset', { phone: '90000001', otp_token: v.data.otp_token, new_password: 'parsms1' });
  assert.equal(r.status, 200);
  assert.equal(r.data.user.phone_verified, true);

  sms.fail = true;
  r = await call('POST', '/api/auth/password/forgot', { phone: '90000001' });
  assert.deepEqual(r.data, { sent: true, channel: 'sms' });
  let list = [];
  await waitFor(() => (list = db.prepare(`SELECT * FROM password_resets WHERE status = 'pending' AND channel = 'admin'`).all()).length === 1);
  list = (await call('GET', '/api/admin/password-resets', null, adminToken)).data;
  assert.equal(list.length, 1, 'repli admin');
  assert.match(list[0].code, /^\d{6}$/);
  sms.fail = false;
});

test('inscription avec OTP obligatoire (prestataire SMS configuré)', async () => {
  useSms(true);
  const body = { name: 'Kofi', phone: '91 11 11 11', password: 'secret1', accept_terms: true };
  let r = await call('POST', '/api/auth/register', body);
  assert.equal(r.status, 400, 'otp_token requis');
  r = await call('POST', '/api/auth/otp/request', { phone: '90000001', purpose: 'register' });
  assert.equal(r.status, 409, 'numéro déjà inscrit');
  r = await call('POST', '/api/auth/otp/request', { phone: body.phone, purpose: 'register' });
  assert.deepEqual(r.data, { sent: true, channel: 'sms' });
  r = await call('POST', '/api/auth/otp/verify', { phone: '+22891111111', code: lastCode(), purpose: 'register' });
  assert.equal(r.status, 200);
  const reg = await call('POST', '/api/auth/register', { ...body, otp_token: r.data.otp_token });
  assert.equal(reg.status, 201);
  assert.equal(reg.data.user.phone_verified, true);
  r = await call('POST', '/api/auth/otp/request', { phone: '92222222', purpose: 'autre' });
  assert.equal(r.status, 400);
  useSms(false);
});

test('suppression du compte : sessions fermées', async () => {
  const reg = await call('POST', '/api/auth/register', { name: 'Efi', phone: '93333333', password: 'secret1', accept_terms: true });
  assert.equal(reg.status, 201);
  assert.equal((await call('DELETE', '/api/auth/me', { password: 'secret1' }, reg.data.token)).status, 204);
  assert.equal((await call('GET', '/api/auth/me', null, reg.data.token)).status, 401);
  assert.equal(db.prepare('SELECT token_version FROM users WHERE id = ?').get(reg.data.user.id).token_version, 1);
});

test('pages légales et /api/legal', async () => {
  let r = await call('GET', '/api/legal');
  assert.equal(r.data.terms_version, '2026-10');
  assert.match(r.data.terms_url, /\/legal\/cgu$/);
  assert.match(r.data.privacy_url, /\/legal\/confidentialite$/);
  for (const p of ['/legal/cgu', '/legal/confidentialite']) {
    r = await call('GET', p);
    assert.equal(r.status, 200);
    assert.match(r.headers.get('content-type'), /text\/html/);
    assert.match(r.data, /juriste/);
    assert.doesNotMatch(r.data, /\{\{/);
  }
  assert.match((await call('GET', '/legal/confidentialite')).data, /code PIN/);
});

test.after(() => {
  server.close();
  smsServer.close();
  db.close();
  fs.rmSync(dir, { recursive: true, force: true });
});
