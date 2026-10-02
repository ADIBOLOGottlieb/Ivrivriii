// Migration de la table users (rôle 'driver') sur une base existante remplie (node --test).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { DatabaseSync } = require('node:sqlite');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-migr-'));
const dbPath = path.join(dir, 'old.db');

// Base « avant livreurs » : ancien CHECK + colonnes ajoutées par account.js + données liées.
function createLegacyDb() {
  const old = new DatabaseSync(dbPath);
  old.exec(`
    PRAGMA foreign_keys = ON;
    CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      phone TEXT NOT NULL UNIQUE,
      email TEXT,
      password_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'customer' CHECK (role IN ('customer', 'admin')),
      address TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    ALTER TABLE users ADD COLUMN avatar_url TEXT;
    ALTER TABLE users ADD COLUMN momo_phone TEXT;
    ALTER TABLE users ADD COLUMN deleted_at TEXT;
    CREATE INDEX idx_users_name ON users(name);
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      status TEXT NOT NULL DEFAULT 'pending',
      mode TEXT NOT NULL CHECK (mode IN ('delivery', 'pickup')),
      address TEXT,
      phone TEXT NOT NULL,
      note TEXT,
      payment_method TEXT NOT NULL,
      subtotal INTEGER NOT NULL,
      delivery_fee INTEGER NOT NULL DEFAULT 0,
      total INTEGER NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE user_addresses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      label TEXT NOT NULL, address TEXT NOT NULL, lat REAL, lng REAL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
  `);
  const insUser = old.prepare('INSERT INTO users (name, phone, password_hash, role, avatar_url, momo_phone, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?)');
  insUser.run('Administrateur', '0700000000', 'h0', 'admin', null, null, null);
  insUser.run('Ama', '90000001', 'h1', 'customer', '/uploads/avatars/1.jpg', '90000001', null);
  insUser.run('Compte supprimé', 'supprime-3-abc', 'h2', 'customer', null, null, '2026-01-01 00:00:00');
  insUser.run('Kofi', '90000004', 'h4', 'customer', null, '91000004', null);
  old.prepare('DELETE FROM users WHERE id = 4').run(); // id max supprimé : la séquence doit être conservée
  const insOrder = old.prepare(`INSERT INTO orders (user_id, mode, address, phone, payment_method, subtotal, total, status)
                                VALUES (?, 'delivery', 'Lomé', '90000001', 'cash', 3000, 4000, ?)`);
  insOrder.run(2, 'delivered');
  insOrder.run(2, 'ready');
  insOrder.run(3, 'cancelled');
  old.prepare(`INSERT INTO user_addresses (user_id, label, address) VALUES (2, 'Maison', 'Bè')`).run();
  old.close();
}

createLegacyDb();
process.env.DB_PATH = dbPath;
const { db, migrateUsersRole } = require('../src/db');

test('la migration accepte le rôle driver et conserve tout', () => {
  const sql = db.prepare(`SELECT sql FROM sqlite_master WHERE name = 'users'`).get().sql;
  assert.match(sql, /'driver'/);
  const users = db.prepare('SELECT * FROM users ORDER BY id').all();
  assert.equal(users.length, 3);
  const ama = users.find((u) => u.id === 2);
  assert.equal(ama.avatar_url, '/uploads/avatars/1.jpg');
  assert.equal(ama.momo_phone, '90000001');
  assert.equal(users.find((u) => u.id === 3).deleted_at, '2026-01-01 00:00:00');
  assert.ok(users.every((u) => u.active === 1));
  // Index recréé, clés étrangères intactes, séquence conservée.
  assert.ok(db.prepare(`SELECT 1 FROM sqlite_master WHERE name = 'idx_users_name'`).get());
  assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
  assert.equal(db.prepare('PRAGMA foreign_keys').get().foreign_keys, 1);
  assert.equal(db.prepare(`SELECT seq FROM sqlite_sequence WHERE name = 'users'`).get().seq, 4);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM orders').get().n, 3);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM user_addresses').get().n, 1);
  const cols = db.prepare('PRAGMA table_info(orders)').all().map((c) => c.name);
  for (const c of ['driver_id', 'picked_up_at', 'driver_delivered_at', 'received_at']) assert.ok(cols.includes(c), c);
});

test('un livreur peut être créé et attribué ; la FK orders.driver_id fonctionne', () => {
  const id = Number(db.prepare(`INSERT INTO users (name, phone, password_hash, role) VALUES ('Yao', '90000009', 'h', 'driver')`).run().lastInsertRowid);
  assert.equal(id, 5);
  db.prepare(`UPDATE orders SET driver_id = ?, status = 'delivering' WHERE id = 2`).run(id);
  assert.throws(() => db.prepare(`UPDATE orders SET driver_id = 999 WHERE id = 2`).run(), /FOREIGN KEY/);
  assert.throws(() => db.prepare(`UPDATE users SET role = 'chef' WHERE id = 2`).run(), /CHECK/);
});

test('la migration rejouée ne fait rien (idempotente), y compris après réouverture', () => {
  assert.equal(migrateUsersRole(db), false);
  const again = new DatabaseSync(dbPath);
  assert.equal(migrateUsersRole(again), false);
  assert.equal(again.prepare('SELECT COUNT(*) AS n FROM users').get().n, 4);
  again.close();
});

test.after(() => {
  db.close();
  fs.rmSync(dir, { recursive: true, force: true });
});
