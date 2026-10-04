/**
 * Personnel du restaurant (comptes role 'admin') : gérants ('manager', accès complet) et cuisine
 * ('kitchen' : commandes, disponibilité des plats, livreurs ; ni argent ni réglages).
 * Réservé au gérant ; toujours au moins un gérant actif. Actions auditées (staff_created, staff_updated).
 */
const express = require('express');
const bcrypt = require('bcryptjs');
const { db, transaction } = require('./db');
const { requireManager, normalizePhone, isValidPhone, bumpTokenVersion, adminLevelOf } = require('./auth');
const { audit } = require('./monitor');
const { h, httpError } = require('./payments/util');

const LEVELS = ['manager', 'kitchen'];
const LAST_MANAGER = 'Il faut au moins un gérant actif';

function staffJson(u) {
  return {
    id: u.id,
    name: u.name,
    phone: u.phone,
    admin_level: adminLevelOf(u),
    active: Number(u.active ?? 1) === 1,
    created_at: u.created_at,
  };
}

const getStaff = (id) => {
  const u = db.prepare(`SELECT * FROM users WHERE id = ? AND role = 'admin' AND deleted_at IS NULL`).get(Number(id));
  return u || null;
};

/** Gérants actifs (NULL = gérant), éventuellement sans un compte donné. */
const activeManagers = (exceptId = 0) => db
  .prepare(
    `SELECT COUNT(*) AS n FROM users WHERE role = 'admin' AND deleted_at IS NULL AND COALESCE(active, 1) = 1
       AND COALESCE(admin_level, 'manager') != 'kitchen' AND id != ?`,
  )
  .get(Number(exceptId)).n;

function checkPassword(password) {
  if (typeof password !== 'string' || password.length < 6) throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
  if (password.length > 200) throw httpError(400, 'Mot de passe trop long');
}

function checkName(name) {
  const n = typeof name === 'string' ? name.trim() : '';
  if (!n) throw httpError(400, 'Nom requis');
  return n.slice(0, 80);
}

function checkLevel(level) {
  if (!LEVELS.includes(level)) throw httpError(400, 'Niveau invalide (manager ou kitchen)');
  return level;
}

const router = express.Router();

router.get('/api/admin/staff', requireManager, h((_req, res) => {
  const rows = db
    .prepare(`SELECT * FROM users WHERE role = 'admin' AND deleted_at IS NULL ORDER BY name COLLATE NOCASE, id`)
    .all();
  res.json(rows.map(staffJson));
}));

router.post('/api/admin/staff', requireManager, h((req, res) => {
  const body = req.body || {};
  const name = checkName(body.name);
  const phone = typeof body.phone === 'string' || typeof body.phone === 'number' ? normalizePhone(body.phone) : '';
  if (!isValidPhone(phone)) throw httpError(400, 'Numéro de téléphone invalide');
  checkPassword(body.password);
  const level = checkLevel(body.admin_level);
  if (db.prepare('SELECT id FROM users WHERE phone = ?').get(phone)) throw httpError(409, 'Ce numéro est déjà utilisé');
  const info = db
    .prepare(`INSERT INTO users (name, phone, password_hash, role, admin_level, active) VALUES (?, ?, ?, 'admin', ?, 1)`)
    .run(name, phone, bcrypt.hashSync(body.password, 10), level);
  const id = Number(info.lastInsertRowid);
  audit('staff_created', { userId: req.user.id, details: { staffId: id, name, admin_level: level }, ip: req.ip });
  res.status(201).json(staffJson(getStaff(id)));
}));

router.patch('/api/admin/staff/:id', requireManager, h((req, res) => {
  const member = getStaff(req.params.id);
  if (!member) throw httpError(404, 'Membre du personnel introuvable');
  const { name, password, admin_level: level, active } = req.body || {};
  const sets = [];
  const params = [];
  const changed = {};
  if (name !== undefined) {
    sets.push('name = ?');
    params.push(checkName(name));
    changed.name = params[params.length - 1];
  }
  if (password !== undefined) {
    checkPassword(password);
    sets.push('password_hash = ?');
    params.push(bcrypt.hashSync(password, 10));
    changed.password = true;
  }
  const currentLevel = adminLevelOf(member);
  if (level !== undefined && checkLevel(level) !== currentLevel) {
    sets.push('admin_level = ?');
    params.push(level);
    changed.admin_level = [currentLevel, level];
  }
  if (active !== undefined) {
    if (![true, false, 0, 1].includes(active)) throw httpError(400, 'Valeur invalide pour active');
    if (Number(member.active ?? 1) !== (active ? 1 : 0)) {
      sets.push('active = ?');
      params.push(active ? 1 : 0);
      changed.active = !!active;
    }
  }
  if (sets.length) {
    transaction(() => {
      // Le dernier gérant actif ne peut être ni rétrogradé ni désactivé.
      const losesManager = currentLevel === 'manager' && Number(member.active ?? 1) === 1
        && ((changed.admin_level && level === 'kitchen') || changed.active === false);
      if (losesManager && activeManagers(member.id) === 0) throw httpError(400, LAST_MANAGER);
      db.prepare(`UPDATE users SET ${sets.join(', ')} WHERE id = ?`).run(...params, member.id);
    });
    // Nouveau mot de passe ou niveau changé : les sessions ouvertes sont fermées (nouvelle connexion).
    if (changed.password || changed.admin_level) bumpTokenVersion(member.id);
    audit('staff_updated', { userId: req.user.id, details: { staffId: member.id, ...changed }, ip: req.ip });
  }
  res.json(staffJson(getStaff(member.id)));
}));

module.exports = { router, staffJson };
