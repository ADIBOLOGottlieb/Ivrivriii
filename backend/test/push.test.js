// Notifications push : faux serveur OAuth + FCM local (port 4440), routes de jeton (node --test).
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-push-'));
process.env.DB_PATH = path.join(dir, 'push.db');
process.env.LOG_DIR = path.join(dir, 'logs');
process.env.LOG_CONSOLE = '0';
delete process.env.FIREBASE_SERVICE_ACCOUNT;

const express = require('express');
const { db } = require('../src/db');
const { signToken } = require('../src/auth');
const push = require('../src/push');

const PORT = 4440;
const BASE = `http://127.0.0.1:${PORT}`;
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });

function serviceAccount(tokenUri) {
  return JSON.stringify({
    type: 'service_account',
    project_id: 'ivrivrii-test',
    client_email: 'push@ivrivrii-test.iam.gserviceaccount.com',
    private_key: pem,
    token_uri: tokenUri,
  });
}

// ---------- Faux serveur Google ----------
const fake = { tokenCalls: 0, sends: [], invalid: new Set(), lastAssertion: null };

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { data += c; });
    req.on('end', () => resolve(data));
  });
}

const server = http.createServer(async (req, res) => {
  const body = await readBody(req);
  if (req.url === '/token') {
    fake.tokenCalls++;
    const assertion = new URLSearchParams(body).get('assertion');
    fake.lastAssertion = assertion;
    const [h, c, s] = assertion.split('.');
    const ok = crypto.verify('RSA-SHA256', Buffer.from(`${h}.${c}`), publicKey, Buffer.from(s, 'base64url'));
    if (!ok) { res.writeHead(400); return res.end('{"error":"invalid_grant"}'); }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ access_token: 'ya29.test', expires_in: 3600, token_type: 'Bearer' }));
  }
  if (req.url === '/v1/projects/ivrivrii-test/messages:send') {
    if (req.headers.authorization !== 'Bearer ya29.test') { res.writeHead(401); return res.end('{}'); }
    const msg = JSON.parse(body).message;
    fake.sends.push(msg);
    if (fake.invalid.has(msg.token)) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: { code: 404, status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }));
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ name: `projects/ivrivrii-test/messages/${fake.sends.length}` }));
  }
  res.writeHead(404);
  res.end();
});

// ---------- Données ----------
const insertUser = db.prepare("INSERT INTO users (name, phone, password_hash, role) VALUES (?, ?, 'x', ?)");
const client = Number(insertUser.run('Client', '+22890000001', 'customer').lastInsertRowid);
const admin1 = Number(insertUser.run('Admin 1', '+22890000002', 'admin').lastInsertRowid);
const admin2 = Number(insertUser.run('Admin 2', '+22890000003', 'admin').lastInsertRowid);
const addToken = (userId, token) => db.prepare('INSERT INTO push_tokens (token, user_id) VALUES (?, ?)').run(token, userId);
const tokensOf = (userId) => db.prepare('SELECT token FROM push_tokens WHERE user_id = ? ORDER BY token').all(userId).map((r) => r.token);

test.before(() => new Promise((resolve) => server.listen(PORT, '127.0.0.1', resolve)));
test.after(() => new Promise((resolve) => server.close(resolve)));

test('sans FIREBASE_SERVICE_ACCOUNT : aucun envoi, aucune erreur', async () => {
  addToken(client, 'tok-client-a-000');
  assert.equal(push.isConfigured(), false);
  await push.notifyUser(client, { title: 'x', body: 'y' });
  await push.notifyRole('admin', { title: 'x', body: 'y' });
  assert.equal(fake.sends.length, 0);
  assert.equal(fake.tokenCalls, 0);
});

test('envoi FCM v1 : JWT RS256 vérifié, jeton d\'accès en cache, data en chaînes', async () => {
  process.env.FIREBASE_SERVICE_ACCOUNT = Buffer.from(serviceAccount(`${BASE}/token`)).toString('base64');
  process.env.FCM_API_URL = BASE;
  addToken(client, 'tok-client-b-000');
  await push.notifyUser(client, { title: 'Commande #12', body: 'Confirmée', data: { type: 'order', order_id: 12 } });
  assert.equal(fake.sends.length, 2);
  assert.equal(fake.tokenCalls, 1);
  const msg = fake.sends[0];
  assert.deepEqual(msg.notification, { title: 'Commande #12', body: 'Confirmée' });
  assert.deepEqual(msg.data, { type: 'order', order_id: '12' });
  assert.equal(msg.android.notification.channel_id, 'commandes');
  const claims = JSON.parse(Buffer.from(fake.lastAssertion.split('.')[1], 'base64url').toString());
  assert.equal(claims.aud, `${BASE}/token`);
  assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');

  // Rôle : les deux admins, sans redemander de jeton d'accès.
  addToken(admin1, 'tok-admin-1-000');
  addToken(admin2, 'tok-admin-2-000');
  await push.notifyRole('admin', { title: 'Nouvelle commande', body: '#13' });
  assert.equal(fake.sends.length, 4);
  assert.equal(fake.tokenCalls, 1);
  assert.deepEqual(fake.sends.slice(2).map((m) => m.token).sort(), ['tok-admin-1-000', 'tok-admin-2-000']);
});

test('jeton invalide (UNREGISTERED) supprimé, les autres gardés', async () => {
  fake.invalid.add('tok-client-a-000');
  await push.notifyUser(client, { title: 't', body: 'b' });
  assert.deepEqual(tokensOf(client), ['tok-client-b-000']);
});

test('compte désactivé : rien n\'est envoyé', async () => {
  db.prepare('UPDATE users SET active = 0 WHERE id = ?').run(admin2);
  const before = fake.sends.length;
  await push.notifyRole('admin', { title: 't', body: 'b' });
  assert.deepEqual(fake.sends.slice(before).map((m) => m.token), ['tok-admin-1-000']);
});

test('échec réseau : aucune exception, jetons conservés', async () => {
  // Nouvelle configuration (cache vidé) pointant vers un port fermé.
  process.env.FIREBASE_SERVICE_ACCOUNT = serviceAccount('http://127.0.0.1:4449/token');
  await assert.doesNotReject(push.notifyUser(client, { title: 't', body: 'b' }));
  process.env.FIREBASE_SERVICE_ACCOUNT = serviceAccount(`${BASE}/token`);
  process.env.FCM_API_URL = 'http://127.0.0.1:4449';
  await assert.doesNotReject(push.notifyRole('admin', { title: 't', body: 'b' }));
  assert.deepEqual(tokensOf(client), ['tok-client-b-000']);
  // Configuration illisible : désactivé, sans exception.
  process.env.FIREBASE_SERVICE_ACCOUNT = 'pas du json';
  assert.equal(push.isConfigured(), false);
  await assert.doesNotReject(push.notifyUser(client, { title: 't', body: 'b' }));
  process.env.FCM_API_URL = BASE;
});

test('routes POST / DELETE /api/push/token', async () => {
  const app = express();
  app.use(express.json());
  app.use(push.router);
  const srv = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const url = `http://127.0.0.1:${srv.address().port}/api/push/token`;
  const call = (method, user, body) => fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${signToken({ id: user, role: 'customer' })}` },
    body: JSON.stringify(body),
  });
  try {
    assert.equal((await fetch(url, { method: 'POST' })).status, 401);
    assert.equal((await call('POST', client, { token: 123 })).status, 400);
    assert.equal((await call('POST', client, { token: 'tok-partage-000', platform: 'android' })).status, 200);
    assert.ok(tokensOf(client).includes('tok-partage-000'));
    // Un autre compte se connecte sur le même téléphone : le jeton change de propriétaire.
    assert.equal((await call('POST', admin1, { token: 'tok-partage-000', platform: 'android' })).status, 200);
    assert.ok(!tokensOf(client).includes('tok-partage-000'));
    assert.ok(tokensOf(admin1).includes('tok-partage-000'));
    // Le client ne peut pas supprimer le jeton d'un autre compte.
    await call('DELETE', client, { token: 'tok-partage-000' });
    assert.ok(tokensOf(admin1).includes('tok-partage-000'));
    assert.equal((await call('DELETE', admin1, { token: 'tok-partage-000' })).status, 200);
    assert.ok(!tokensOf(admin1).includes('tok-partage-000'));
  } finally {
    await new Promise((resolve) => srv.close(resolve));
  }
});
