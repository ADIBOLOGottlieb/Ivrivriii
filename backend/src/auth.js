const crypto = require('crypto');
const jwt = require('jsonwebtoken');
const { db, transaction } = require('./db');
const { log } = require('./logger');

const DEFAULT_SECRET = 'change-moi-en-production';
const JWT_SECRET = process.env.JWT_SECRET || DEFAULT_SECRET;

if (JWT_SECRET === DEFAULT_SECRET) {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('JWT_SECRET doit être défini en production');
  }
  console.warn('⚠️  JWT_SECRET non défini : clé de développement utilisée (ne pas utiliser en production).');
}

const INACTIVE_MESSAGE = 'Compte désactivé : contactez le restaurant';
const SESSION_EXPIRED = 'Session expirée, reconnectez-vous';

// ---------- Migrations (idempotentes) ----------

function addColumn(table, column, definition) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);
  if (!cols.includes(column)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`);
}
// Version des jetons : +1 au changement de mot de passe → les autres appareils sont déconnectés.
addColumn('users', 'token_version', 'INTEGER NOT NULL DEFAULT 0');
addColumn('users', 'phone_verified', 'INTEGER NOT NULL DEFAULT 0');
addColumn('users', 'terms_accepted_at', 'TEXT');
addColumn('users', 'terms_version', 'TEXT');

/**
 * Identifiant de l'instance de base (UUID créé au 1er démarrage). Mis dans chaque jeton : après un
 * effacement de la base, les ids recommencent à 1 et un ancien jeton ne doit pas ouvrir le compte d'un autre.
 */
function loadInstanceId() {
  db.prepare(`INSERT OR IGNORE INTO settings (key, value) VALUES ('db_instance_id', ?)`).run(crypto.randomUUID());
  return db.prepare(`SELECT value FROM settings WHERE key = 'db_instance_id'`).get().value;
}
const INSTANCE_ID = loadInstanceId();

// ---------- Téléphone ----------

/**
 * Format unique des numéros : '+228XXXXXXXX' pour un numéro togolais (8 chiffres, avec ou sans
 * +228 / 00228 / 228, espaces, tirets, points) ; autres pays : '+' et chiffres ; sinon les chiffres.
 * Renvoie '' si l'entrée n'est pas une chaîne exploitable.
 */
function normalizePhone(p) {
  if (typeof p !== 'string' && typeof p !== 'number') return '';
  const raw = String(p).trim();
  if (!raw || !/^[+\d\s\-.()/]+$/.test(raw)) return '';
  let plus = raw.startsWith('+');
  let d = raw.replace(/\D/g, '');
  if (!plus && d.startsWith('00')) {
    plus = true;
    d = d.slice(2);
  }
  if (!d) return '';
  if (d.length === 8 && !plus) return `+228${d}`;
  if (d.length === 11 && d.startsWith('228')) return `+${d}`;
  return plus ? `+${d}` : d;
}

/** Numéro normalisé plausible (8 à 15 chiffres). */
const isValidPhone = (normalized) => /^\+?\d{8,15}$/.test(normalized || '');

/**
 * Normalise les numéros des comptes existants. Doublons après normalisation : le plus ancien garde
 * le numéro, les autres sont renommés 'doublon-<id>-<tel>' (inscrits au journal d'audit).
 * Les comptes supprimés ('supprime-…') et déjà renommés sont ignorés. @returns { updated, duplicates }
 */
function migratePhones(database = db) {
  const users = database.prepare('SELECT id, phone FROM users ORDER BY id').all();
  const groups = new Map();
  for (const u of users) {
    const n = normalizePhone(u.phone);
    const key = n || u.phone; // numéro inexploitable : laissé tel quel
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ ...u, normalized: n });
  }
  const renames = [];
  const updates = [];
  for (const [, list] of groups) {
    const [keeper, ...others] = list; // trié par id : le premier est le plus ancien
    for (const o of others) renames.push(o);
    if (keeper.normalized && keeper.normalized !== keeper.phone) updates.push(keeper);
  }
  if (!renames.length && !updates.length) return { updated: 0, duplicates: 0 };
  const run = () => {
    const set = database.prepare('UPDATE users SET phone = ? WHERE id = ?');
    // Les doublons d'abord, pour libérer le numéro (contrainte UNIQUE).
    for (const o of renames) {
      const newPhone = `doublon-${o.id}-${o.phone}`.slice(0, 60);
      set.run(newPhone, o.id);
      database.prepare('INSERT INTO audit_logs (user_id, action, details) VALUES (?, ?, ?)').run(
        o.id, 'phone_duplicate_renamed', JSON.stringify({ old: o.phone, new: newPhone, normalized: o.normalized }),
      );
      log.warn('numéro en double renommé', { userId: o.id, old: o.phone, new: newPhone });
    }
    for (const u of updates) set.run(u.normalized, u.id);
  };
  if (database === db) transaction(run);
  else run();
  console.log(`📞 Migration des numéros : ${updates.length} normalisé(s), ${renames.length} doublon(s) renommé(s)`);
  return { updated: updates.length, duplicates: renames.length };
}
migratePhones();

// ---------- Jetons ----------

function signToken(user) {
  let tv = user.token_version;
  if (tv === undefined || tv === null) {
    tv = db.prepare('SELECT token_version FROM users WHERE id = ?').get(user.id)?.token_version ?? 0;
  }
  return jwt.sign({ id: user.id, role: user.role, iid: INSTANCE_ID, tv: Number(tv) }, JWT_SECRET, { expiresIn: '30d' });
}

/** Invalide tous les jetons existants du compte (autres appareils déconnectés). */
function bumpTokenVersion(userId) {
  db.prepare('UPDATE users SET token_version = COALESCE(token_version, 0) + 1 WHERE id = ?').run(Number(userId));
}

/** Vrai si le compte est désactivé (colonne active = 0 ; absente sur une très vieille base = actif). */
const isInactive = (user) => user.active !== undefined && user.active !== null && Number(user.active) === 0;

function requireAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'Non authentifié' });
  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET, { algorithms: ['HS256'] });
  } catch {
    return res.status(401).json({ error: SESSION_EXPIRED });
  }
  // Jeton d'une autre base (base effacée puis recréée : les ids recommencent) → refusé.
  if (payload.iid !== INSTANCE_ID) return res.status(401).json({ error: SESSION_EXPIRED });
  // Un jeton reste valable 30 jours : on refuse celui d'un compte supprimé ou anonymisé.
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(payload.id);
  if (!user || user.deleted_at) return res.status(401).json({ error: SESSION_EXPIRED });
  // Mot de passe changé / réinitialisé depuis l'émission du jeton → session terminée.
  if (Number(payload.tv) !== Number(user.token_version ?? 0)) return res.status(401).json({ error: SESSION_EXPIRED });
  // Compte désactivé (livreur) : la session est refusée immédiatement, sans attendre l'expiration.
  if (isInactive(user)) return res.status(401).json({ error: INACTIVE_MESSAGE, code: 'account_disabled' });
  // Le rôle vient de la base : un admin rétrogradé perd l'accès sans attendre l'expiration du jeton.
  req.user = { ...payload, role: user.role, name: user.name };
  next();
}

function requireAdmin(req, res, next) {
  requireAuth(req, res, () => {
    if (req.user.role !== 'admin') return res.status(403).json({ error: 'Accès réservé à l\'administrateur' });
    next();
  });
}

/** Espace livreur : rôle 'driver' actif (vérifié par requireAuth) ; l'administrateur y a aussi accès. */
function requireDriver(req, res, next) {
  requireAuth(req, res, () => {
    if (req.user.role !== 'driver' && req.user.role !== 'admin') {
      return res.status(403).json({ error: 'Accès réservé aux livreurs' });
    }
    next();
  });
}

module.exports = {
  signToken,
  requireAuth,
  requireAdmin,
  requireDriver,
  isInactive,
  INACTIVE_MESSAGE,
  bumpTokenVersion,
  normalizePhone,
  isValidPhone,
  migratePhones,
  instanceId: () => INSTANCE_ID,
};
