// Compte client : profil, mot de passe, photo, statistiques, adresses enregistrées, suppression.
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const express = require('express');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const { rateLimit } = require('express-rate-limit');
const { db, transaction } = require('./db');
const { requireAuth } = require('./auth');
const { log } = require('./logger');
const { audit } = require('./monitor');

// ---------- Migrations (idempotentes) ----------

function addColumn(table, column, definition) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!cols.includes(column)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}
addColumn('users', 'avatar_url', 'TEXT');
addColumn('users', 'momo_phone', 'TEXT');
addColumn('users', 'deleted_at', 'TEXT');

db.exec(`
  CREATE TABLE IF NOT EXISTS user_addresses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    address TEXT NOT NULL,
    lat REAL,
    lng REAL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_user_addresses_user ON user_addresses(user_id);
`);

const MAX_ADDRESSES = 10;
const PHONE_RE = /^\+?[\d\s]{8,16}$/;

// ---------- Helpers ----------

const h = (fn) => async (req, res) => {
  try {
    await fn(req, res);
  } catch (err) {
    if (!err.status) log.error('erreur serveur', { path: req.path, error: err.message, stack: err.stack });
    res.status(err.status || 500).json({ error: err.status ? err.message : 'Erreur serveur' });
  }
};

function httpError(status, message) {
  const err = new Error(message);
  err.status = status;
  return err;
}

function publicUser(u) {
  return {
    id: u.id,
    name: u.name,
    phone: u.phone,
    email: u.email,
    role: u.role,
    address: u.address,
    created_at: u.created_at,
    avatar_url: u.avatar_url ?? null,
    momo_phone: u.momo_phone ?? null,
  };
}

function mapAddress(a) {
  return { id: a.id, label: a.label, address: a.address, lat: a.lat, lng: a.lng };
}

const getUser = (id) => db.prepare('SELECT * FROM users WHERE id = ?').get(id);

/** requireAuth + chargement de l'utilisateur ; un compte supprimé n'est plus accepté. */
function requireUser(req, res, next) {
  requireAuth(req, res, () => {
    const user = getUser(req.user.id);
    if (!user || user.deleted_at) return res.status(401).json({ error: 'Session expirée, reconnectez-vous' });
    req.account = user;
    next();
  });
}

// Limite les essais de mot de passe (changement, suppression du compte).
const passwordLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  keyGenerator: (req) => `user-${req.user.id}`,
  message: { error: 'Trop de tentatives. Réessayez dans 15 minutes.' },
});

// ---------- Photo de profil ----------

const AVATAR_DIR = path.join(__dirname, '..', 'uploads', 'avatars');
fs.mkdirSync(AVATAR_DIR, { recursive: true });

const avatarUpload = multer({
  storage: multer.diskStorage({
    destination: AVATAR_DIR,
    filename: (req, file, cb) => {
      const ext = (path.extname(file.originalname).toLowerCase().match(/^\.(jpe?g|png|webp)$/) || ['.jpg'])[0];
      cb(null, `${req.user.id}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}${ext}`);
    },
  }),
  limits: { fileSize: 5 * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => cb(null, /^image\/(jpeg|png|webp)$/.test(file.mimetype)),
}).single('image');

/** Supprime le fichier d'une photo de profil (uniquement dans uploads/avatars). */
function removeAvatarFile(url) {
  if (!url || !url.startsWith('/uploads/avatars/')) return;
  const file = path.join(AVATAR_DIR, path.basename(url));
  fs.unlink(file, (err) => {
    if (err && err.code !== 'ENOENT') log.warn('suppression avatar impossible', { file, error: err.message });
  });
}

// ---------- Validation ----------

function cleanText(value, max) {
  return typeof value === 'string' ? value.trim().slice(0, max) : '';
}

function parseCoord(value, limit, label) {
  if (value === undefined || value === null || value === '') return null;
  const n = Number(value);
  if (!Number.isFinite(n) || Math.abs(n) > limit) throw httpError(400, `${label} invalide`);
  return n;
}

function addressFields(body, current = {}) {
  const pick = (k) => (body[k] !== undefined ? body[k] : current[k]);
  const label = typeof pick('label') === 'string' ? pick('label').trim() : '';
  if (label.length < 1 || label.length > 40) throw httpError(400, 'Nom de l\'adresse requis (40 caractères max)');
  const address = cleanText(pick('address'), 300);
  if (!address) throw httpError(400, 'Adresse requise');
  const lat = parseCoord(pick('lat'), 90, 'Latitude');
  const lng = parseCoord(pick('lng'), 180, 'Longitude');
  if ((lat === null) !== (lng === null)) throw httpError(400, 'Position incomplète (latitude et longitude requises)');
  return { label, address, lat, lng };
}

// ---------- Routes ----------

const router = express.Router();

router.get('/api/auth/me', requireUser, h((req, res) => {
  res.json(publicUser(req.account));
}));

// Le mot de passe n'est plus modifiable ici : voir PUT /api/auth/me/password.
router.put('/api/auth/me', requireUser, h((req, res) => {
  const { name, email, address, momo_phone } = req.body || {};
  const user = req.account;
  let momo = user.momo_phone;
  if (momo_phone !== undefined) {
    momo = typeof momo_phone === 'string' ? momo_phone.trim() : momo_phone == null ? '' : String(momo_phone).trim();
    if (momo && !PHONE_RE.test(momo)) throw httpError(400, 'Numéro mobile money invalide');
    momo = momo || null;
  }
  db.prepare('UPDATE users SET name = ?, email = ?, address = ?, momo_phone = ? WHERE id = ?').run(
    cleanText(name, 80) || user.name,
    email !== undefined ? cleanText(email, 120) || null : user.email,
    address !== undefined ? cleanText(address, 300) || null : user.address,
    momo,
    user.id,
  );
  res.json(publicUser(getUser(user.id)));
}));

router.put('/api/auth/me/password', requireUser, passwordLimiter, h((req, res) => {
  const { old_password, new_password } = req.body || {};
  if (!old_password) throw httpError(400, 'Ancien mot de passe requis');
  if (typeof new_password !== 'string' || new_password.length < 6) {
    throw httpError(400, 'Le nouveau mot de passe doit contenir au moins 6 caractères');
  }
  if (!bcrypt.compareSync(String(old_password), req.account.password_hash)) {
    audit('password_change_failed', { userId: req.account.id, ip: req.ip });
    throw httpError(401, 'Ancien mot de passe incorrect');
  }
  db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(bcrypt.hashSync(new_password, 10), req.account.id);
  audit('password_changed', { userId: req.account.id, ip: req.ip });
  res.json({ ok: true });
}));

router.post('/api/auth/me/avatar', requireUser, (req, res) => {
  avatarUpload(req, res, (err) => {
    if (err) {
      const tooBig = err.code === 'LIMIT_FILE_SIZE';
      return res.status(tooBig ? 413 : 400).json({
        error: tooBig ? 'Image trop volumineuse (5 Mo max)' : 'Image invalide (JPEG, PNG ou WebP, max 5 Mo)',
      });
    }
    h((req2, res2) => {
      if (!req2.file) throw httpError(400, 'Image invalide (JPEG, PNG ou WebP, max 5 Mo)');
      const old = req2.account.avatar_url;
      db.prepare('UPDATE users SET avatar_url = ? WHERE id = ?').run(`/uploads/avatars/${req2.file.filename}`, req2.account.id);
      removeAvatarFile(old);
      res2.json(publicUser(getUser(req2.account.id)));
    })(req, res);
  });
});

router.delete('/api/auth/me/avatar', requireUser, h((req, res) => {
  removeAvatarFile(req.account.avatar_url);
  db.prepare('UPDATE users SET avatar_url = NULL WHERE id = ?').run(req.account.id);
  res.json(publicUser(getUser(req.account.id)));
}));

// orders_count : commandes non annulées ; total_spent : commandes livrées et réglées
// (espèces encaissées à la livraison, ou mobile money payé ; les remboursées sont exclues).
router.get('/api/auth/me/stats', requireUser, h((req, res) => {
  const row = db
    .prepare(
      `SELECT COUNT(CASE WHEN status != 'cancelled' THEN 1 END) AS orders_count,
              COALESCE(SUM(CASE WHEN status = 'delivered' AND payment_status IN ('paid', 'unpaid') THEN total END), 0) AS total_spent
       FROM orders WHERE user_id = ?`,
    )
    .get(req.account.id);
  res.json({ orders_count: Number(row.orders_count), total_spent: Number(row.total_spent) });
}));

router.get('/api/auth/me/addresses', requireUser, h((req, res) => {
  res.json(db.prepare('SELECT * FROM user_addresses WHERE user_id = ? ORDER BY id').all(req.account.id).map(mapAddress));
}));

router.post('/api/auth/me/addresses', requireUser, h((req, res) => {
  const f = addressFields(req.body || {});
  const n = db.prepare('SELECT COUNT(*) AS n FROM user_addresses WHERE user_id = ?').get(req.account.id).n;
  if (n >= MAX_ADDRESSES) throw httpError(400, `${MAX_ADDRESSES} adresses maximum : supprimez-en une d'abord`);
  const info = db
    .prepare('INSERT INTO user_addresses (user_id, label, address, lat, lng) VALUES (?, ?, ?, ?, ?)')
    .run(req.account.id, f.label, f.address, f.lat, f.lng);
  res.status(201).json(mapAddress(db.prepare('SELECT * FROM user_addresses WHERE id = ?').get(info.lastInsertRowid)));
}));

router.put('/api/auth/me/addresses/:id', requireUser, h((req, res) => {
  const current = db
    .prepare('SELECT * FROM user_addresses WHERE id = ? AND user_id = ?')
    .get(Number(req.params.id), req.account.id);
  if (!current) throw httpError(404, 'Adresse introuvable');
  const f = addressFields(req.body || {}, current);
  db.prepare('UPDATE user_addresses SET label = ?, address = ?, lat = ?, lng = ? WHERE id = ?')
    .run(f.label, f.address, f.lat, f.lng, current.id);
  res.json(mapAddress(db.prepare('SELECT * FROM user_addresses WHERE id = ?').get(current.id)));
}));

router.delete('/api/auth/me/addresses/:id', requireUser, h((req, res) => {
  const info = db
    .prepare('DELETE FROM user_addresses WHERE id = ? AND user_id = ?')
    .run(Number(req.params.id), req.account.id);
  if (info.changes === 0) throw httpError(404, 'Adresse introuvable');
  res.status(204).end();
}));

// Suppression du compte : anonymisation ; les commandes restent pour la comptabilité.
router.delete('/api/auth/me', requireUser, passwordLimiter, h((req, res) => {
  const user = req.account;
  const { password } = req.body || {};
  if (!password) throw httpError(400, 'Mot de passe requis');
  if (user.role === 'admin') throw httpError(403, 'Un compte administrateur ne peut pas être supprimé depuis l\'application');
  if (!bcrypt.compareSync(String(password), user.password_hash)) throw httpError(401, 'Mot de passe incorrect');
  transaction(() => {
    db.prepare('DELETE FROM user_addresses WHERE user_id = ?').run(user.id);
    db.prepare(
      `UPDATE users SET name = 'Compte supprimé', phone = ?, email = NULL, address = NULL, momo_phone = NULL,
         avatar_url = NULL, password_hash = ?, deleted_at = datetime('now') WHERE id = ?`,
    ).run(
      `supprime-${user.id}-${crypto.randomBytes(6).toString('hex')}`,
      bcrypt.hashSync(crypto.randomBytes(32).toString('hex'), 10),
      user.id,
    );
  });
  removeAvatarFile(user.avatar_url);
  audit('account_deleted', { userId: user.id, ip: req.ip });
  res.status(204).end();
}));

module.exports = { router, publicUser };
