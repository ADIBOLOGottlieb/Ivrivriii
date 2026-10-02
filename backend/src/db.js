const path = require('path');
const { DatabaseSync } = require('node:sqlite');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'ivrivrii.db');
const db = new DatabaseSync(DB_PATH);

db.exec(`
  PRAGMA foreign_keys = ON;
  PRAGMA journal_mode = WAL;

  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    phone TEXT NOT NULL UNIQUE,
    email TEXT,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'customer' CHECK (role IN ('customer', 'admin')),
    address TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS categories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    icon TEXT,
    position INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    description TEXT,
    price INTEGER NOT NULL,
    image_url TEXT,
    available INTEGER NOT NULL DEFAULT 1,
    popular INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS orders (
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

  CREATE TABLE IF NOT EXISTS order_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id INTEGER REFERENCES products(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    unit_price INTEGER NOT NULL,
    quantity INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  -- Tentatives de paiement mobile money (une commande peut en avoir plusieurs).
  CREATE TABLE IF NOT EXISTS payments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    reference TEXT,
    amount INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    raw TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- Journal d'audit des actions sensibles.
  CREATE TABLE IF NOT EXISTS audit_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    user_id INTEGER,
    action TEXT NOT NULL,
    details TEXT,
    ip TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs(created_at);
  CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_logs(action, created_at);

  -- Alertes de sécurité / monitoring (pics de transactions, attaques...).
  CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    type TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    message TEXT NOT NULL,
    details TEXT,
    resolved INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at);
`);

// Migrations : ajoute les colonnes manquantes sur une base existante.
function addColumn(table, column, definition) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!cols.includes(column)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}
addColumn('orders', 'delivery_lat', 'REAL');
addColumn('orders', 'delivery_lng', 'REAL');
addColumn('orders', 'delivery_accuracy', 'REAL');
addColumn('orders', 'payment_fee', 'INTEGER NOT NULL DEFAULT 0');
addColumn('orders', 'payment_status', "TEXT NOT NULL DEFAULT 'unpaid'");
addColumn('orders', 'payment_reference', 'TEXT');
addColumn('orders', 'payment_token', 'TEXT');
addColumn('orders', 'paid_at', 'TEXT');
// Taux des frais mobile money figé à la création (commission de l'agrégateur ou réglage admin).
addColumn('orders', 'payment_fee_percent', 'REAL');

// Paiements mobile money : suivi de l'argent (brut, frais, net, reversement, remboursement).
for (const [col, def] of [
  ['operator', 'TEXT'],
  ['phone', 'TEXT'],
  ['identifier', 'TEXT'],
  ['provider_reference', 'TEXT'],
  ['operator_reference', 'TEXT'],
  ['gross_amount', 'INTEGER'],
  ['provider_fee', 'INTEGER NOT NULL DEFAULT 0'],
  ['net_amount', 'INTEGER'],
  ['message', 'TEXT'],
  ['simulated', 'INTEGER NOT NULL DEFAULT 0'],
  ['provider_state', 'TEXT'],
  ['needs_review', 'INTEGER NOT NULL DEFAULT 0'],
  ['expires_at', 'TEXT'],
  ['paid_at', 'TEXT'],
  ['last_checked_at', 'TEXT'],
  ['validated_by', 'INTEGER'],
  ['settlement_status', 'TEXT'],
  ['settled_at', 'TEXT'],
  ['settlement_reference', 'TEXT'],
  ['refund_status', 'TEXT'],
  ['refund_reference', 'TEXT'],
  ['refunded_at', 'TEXT'],
  ['refunded_by', 'INTEGER'],
]) {
  addColumn('payments', col, def);
}
// Reprise des anciennes lignes (avant la refonte des paiements).
db.exec(`
  UPDATE payments SET operator = (SELECT payment_method FROM orders WHERE orders.id = payments.order_id)
    WHERE operator IS NULL;
  UPDATE payments SET provider_reference = reference WHERE provider_reference IS NULL AND reference IS NOT NULL;
  UPDATE payments SET gross_amount = amount, net_amount = amount, paid_at = COALESCE(paid_at, updated_at),
    settlement_status = 'en_attente' WHERE status = 'paid' AND gross_amount IS NULL;
  CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_identifier ON payments(identifier);
  CREATE INDEX IF NOT EXISTS idx_payments_order ON payments(order_id, id);
  CREATE INDEX IF NOT EXISTS idx_payments_status ON payments(status, paid_at);
  CREATE INDEX IF NOT EXISTS idx_payments_provider_ref ON payments(provider_reference);
`);

function transaction(fn) {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

function optionalNumber(value) {
  if (value == null || value === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function getSettings() {
  const rows = db.prepare('SELECT key, value FROM settings').all();
  const s = Object.fromEntries(rows.map((r) => [r.key, r.value]));
  return {
    delivery_fee: Number(s.delivery_fee ?? 1000),
    min_order: Number(s.min_order ?? 2000),
    is_open: (s.is_open ?? '1') === '1',
    restaurant_phone: s.restaurant_phone ?? '+228 97 98 02 79',
    restaurant_address: s.restaurant_address ?? 'Lomé, Togo',
    // Frais de paiement mobile money reportés sur le client (en %), utilisé seulement sans
    // commission d'agrégateur en variable d'environnement (voir payments/fees.js).
    payment_fee_percent: Number(s.payment_fee_percent ?? 2),
    // Seuils de détection de pic de transactions.
    spike_min_orders: Number(s.spike_min_orders ?? 10),
    spike_factor: Number(s.spike_factor ?? 3),
    high_amount_alert: Number(s.high_amount_alert ?? 100000),
    // Annulation automatique d'une commande mobile money non payée (minutes).
    momo_unpaid_cancel_minutes: Number(s.momo_unpaid_cancel_minutes ?? 30),
    // Position du restaurant (départ des itinéraires de livraison) : null tant que non définie.
    restaurant_lat: optionalNumber(s.restaurant_lat),
    restaurant_lng: optionalNumber(s.restaurant_lng),
  };
}

module.exports = { db, transaction, getSettings };
