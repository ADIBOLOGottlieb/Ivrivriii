// Journal des erreurs : log.error → table error_logs (sans ouvrir la base trop tôt, sans boucle),
// troncature et conservation. Textes des notifications au personnel (notify.js). node --test.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-errlog-'));
process.env.DB_PATH = path.join(dir, 'errors.db');
process.env.LOG_DIR = path.join(dir, 'logs');
process.env.LOG_CONSOLE = '0';
process.env.JWT_SECRET = 'secret-errlog';

// logger.js d'abord : la base ne doit pas être ouverte par un log.error (start.js restaure avant).
const { log } = require('../src/logger');

test('log.error avant l\'ouverture de la base : rien n\'est ouvert', () => {
  const original = console.error;
  console.error = () => {};
  try {
    log.error('avant la base', { error: 'x' });
  } finally {
    console.error = original;
  }
  assert.equal(require.cache[require.resolve('../src/db')], undefined);
  assert.equal(fs.existsSync(process.env.DB_PATH), false);
});

test('log.error copie l\'erreur dans error_logs (source server), secrets masqués', () => {
  const { db } = require('../src/db');
  const original = console.error;
  console.error = () => {};
  try {
    log.error('erreur serveur', { path: '/api/orders', error: 'boum', stack: 'Error: boum\n  at x', token: 'abc' });
    log.error('tâche', { error: 'timeout', jobId: 3, password: 'secret' });
    log.error('http', { status: 500 }); // ligne d'accès : non copiée
  } finally {
    console.error = original;
  }
  const rows = db.prepare('SELECT * FROM error_logs ORDER BY id').all();
  assert.equal(rows.length, 2);
  assert.equal(rows[0].source, 'server');
  assert.equal(rows[0].message, 'erreur serveur : boum');
  assert.equal(rows[0].context, '/api/orders');
  assert.match(rows[0].stack, /Error: boum/);
  assert.equal(rows[1].message, 'tâche : timeout');
  assert.ok(!rows[1].context.includes('secret'), 'mot de passe masqué');
  assert.match(rows[1].context, /jobId/);
});

test('échec d\'écriture : pas de boucle ni d\'exception', () => {
  const { db } = require('../src/db');
  db.exec('ALTER TABLE error_logs RENAME TO error_logs_tmp');
  const original = console.error;
  let lines = 0;
  console.error = () => { lines++; };
  try {
    assert.doesNotThrow(() => log.error('base cassée', { error: 'x' }));
  } finally {
    console.error = original;
    db.exec('ALTER TABLE error_logs_tmp RENAME TO error_logs');
  }
  assert.equal(lines, 1, 'une seule ligne journalisée');
});

test('troncature et conservation (2 000 lignes, 30 jours)', () => {
  const { db } = require('../src/db');
  const { recordError, MAX_ROWS } = require('../src/error-log');
  db.exec('DELETE FROM error_logs');
  const id = recordError({ source: 'app', message: 'm'.repeat(900), stack: 's'.repeat(5000), context: 'c'.repeat(400), user_id: 7 });
  const r = db.prepare('SELECT * FROM error_logs WHERE id = ?').get(id);
  assert.equal(r.message.length, 500);
  assert.equal(r.stack.length, 4000);
  assert.equal(r.context.length, 300);
  assert.equal(r.user_id, 7);
  db.prepare(`UPDATE error_logs SET created_at = datetime('now', '-31 days') WHERE id = ?`).run(id);
  const insert = db.prepare(`INSERT INTO error_logs (source, message) VALUES ('app', 'x')`);
  db.exec('BEGIN');
  for (let i = 0; i < MAX_ROWS + 50; i++) insert.run();
  db.exec('COMMIT');
  recordError({ source: 'server', message: 'dernière' });
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM error_logs').get().n, MAX_ROWS);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM error_logs WHERE id = ?').get(id).n, 0, 'plus de 30 jours : supprimée');
  assert.equal(db.prepare('SELECT message FROM error_logs ORDER BY id DESC LIMIT 1').get().message, 'dernière');
});

test('notifications au personnel et au client (textes)', () => {
  const sent = [];
  require.cache[require.resolve('../src/push')] = {
    id: 'push', filename: 'push', loaded: true,
    exports: {
      notifyUser: async (userId, m) => sent.push({ to: `user-${userId}`, ...m }),
      notifyRole: async (role, m) => sent.push({ to: role, ...m }),
    },
  };
  const notify = require('../src/notify');
  const order = { id: 42, user_id: 5, mode: 'delivery', driver_name: 'Yao' };
  notify.driverTook(order, 'Koffi');
  notify.statusChanged(order, 'delivering', { driverName: 'Koffi' });
  notify.driverDelivered(order);
  notify.deliveryReceived(order);
  const find = (to, title) => sent.find((m) => m.to === to && m.title === title);
  assert.equal(find('admin', 'Livraison prise en charge').body, 'Koffi a pris la livraison n°42');
  assert.equal(find('user-5', 'Commande n°42').body, 'Votre commande est en route avec Koffi. Suivez-la en direct dans l\'app.');
  assert.equal(find('admin', 'Livraison faite').body, 'Commande n°42 livrée par Yao');
  assert.equal(find('admin', 'Réception confirmée').body, 'Commande n°42 : réception confirmée par le client');
});
