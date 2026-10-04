/**
 * Personnel du restaurant (comptes role 'admin') :
 *  - 'owner'   : propriétaire (un seul). Accès complet ; personne d'autre ne peut le modifier, le désactiver,
 *                le rétrograder ou le supprimer. Il crée, modifie et supprime gérants et comptes cuisine ;
 *  - 'manager' : gérant. Accès complet sauf la gestion des gérants : il ne gère que les comptes cuisine ;
 *  - 'kitchen' : cuisine (commandes, disponibilité des plats, livreurs ; ni argent ni réglages).
 * Le niveau 'owner' ne s'attribue pas par l'API. Actions auditées (staff_created, staff_updated, staff_deleted).
 */
const crypto = require('crypto');
const express = require('express');
const bcrypt = require('bcryptjs');
const { db, transaction } = require('./db');
const { requireManager, normalizePhone, isValidPhone, bumpTokenVersion, adminLevelOf } = require('./auth');
const { audit } = require('./monitor');
const { h, httpError } = require('./payments/util');

const LEVELS = ['manager', 'kitchen'];
const OWNER_PROTECTED = 'Le compte propriétaire ne peut être modifié que par le propriétaire lui-même';
const OWNER_ONLY = 'Seul le propriétaire peut gérer les comptes gérant';

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

/**
 * Garantit un propriétaire actif (bases existantes) : le compte ADMIN_PHONE s'il existe, sinon le plus ancien
 * gérant actif. Sans effet si un propriétaire existe déjà. @returns l'id promu, ou null.
 */
function ensureOwner() {
  const owner = db.prepare(`SELECT id FROM users WHERE role = 'admin' AND admin_level = 'owner' AND deleted_at IS NULL`).get();
  if (owner) return null;
  const managers = `role = 'admin' AND deleted_at IS NULL AND COALESCE(active, 1) = 1 AND COALESCE(admin_level, 'manager') != 'kitchen'`;
  const envPhone = process.env.ADMIN_PHONE ? normalizePhone(process.env.ADMIN_PHONE) : null;
  const pick = (envPhone && db.prepare(`SELECT id FROM users WHERE ${managers} AND phone = ?`).get(envPhone))
    || db.prepare(`SELECT id FROM users WHERE ${managers} ORDER BY created_at, id LIMIT 1`).get();
  if (!pick) return null;
  db.prepare(`UPDATE users SET admin_level = 'owner' WHERE id = ?`).run(pick.id);
  audit('staff_owner_assigned', { details: { staffId: pick.id, reason: 'migration' } });
  return pick.id;
}

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
  if (level === 'owner') throw httpError(400, 'Il ne peut y avoir qu\'un seul propriétaire');
  if (!LEVELS.includes(level)) throw httpError(400, 'Niveau invalide (manager ou kitchen)');
  return level;
}

const isOwner = (user) => user?.admin_level === 'owner';

/**
 * Droit d'agir sur un membre : le propriétaire sur tous les autres ; un gérant sur les comptes cuisine
 * (et sur lui-même pour son nom / mot de passe) ; personne d'autre sur le propriétaire.
 */
function assertCanManage(actor, member) {
  const level = adminLevelOf(member);
  if (member.id === actor.id) return;
  if (level === 'owner') throw httpError(403, OWNER_PROTECTED);
  if (level === 'manager' && !isOwner(actor)) throw httpError(403, OWNER_ONLY);
}

const router = express.Router();

router.get('/api/admin/staff', requireManager, h((_req, res) => {
  const rows = db
    .prepare(`SELECT * FROM users WHERE role = 'admin' AND deleted_at IS NULL
              ORDER BY CASE admin_level WHEN 'owner' THEN 0 ELSE 1 END, name COLLATE NOCASE, id`)
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
  if (level === 'manager' && !isOwner(req.user)) throw httpError(403, OWNER_ONLY);
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
  assertCanManage(req.user, member);
  const { name, password, admin_level: level, active } = req.body || {};
  const currentLevel = adminLevelOf(member);
  const self = member.id === req.user.id;
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
  if (level !== undefined && level !== currentLevel) {
    if (currentLevel === 'owner') throw httpError(400, 'Le propriétaire garde son niveau');
    if (self) throw httpError(400, 'Vous ne pouvez pas changer votre propre niveau');
    checkLevel(level);
    if (level === 'manager' && !isOwner(req.user)) throw httpError(403, OWNER_ONLY);
    sets.push('admin_level = ?');
    params.push(level);
    changed.admin_level = [currentLevel, level];
  }
  if (active !== undefined) {
    if (![true, false, 0, 1].includes(active)) throw httpError(400, 'Valeur invalide pour active');
    if (Number(member.active ?? 1) !== (active ? 1 : 0)) {
      if (currentLevel === 'owner') throw httpError(400, 'Le compte propriétaire ne peut pas être désactivé');
      if (self) throw httpError(400, 'Vous ne pouvez pas désactiver votre propre compte');
      sets.push('active = ?');
      params.push(active ? 1 : 0);
      changed.active = !!active;
    }
  }
  if (sets.length) {
    db.prepare(`UPDATE users SET ${sets.join(', ')} WHERE id = ?`).run(...params, member.id);
    // Nouveau mot de passe, niveau changé ou compte désactivé : les sessions ouvertes sont fermées.
    if (changed.password || changed.admin_level || changed.active === false) bumpTokenVersion(member.id);
    audit('staff_updated', { userId: req.user.id, details: { staffId: member.id, ...changed }, ip: req.ip });
  }
  res.json(staffJson(getStaff(member.id)));
}));

/**
 * Suppression d'un compte du personnel (propriétaire : gérants et cuisine ; gérant : cuisine).
 * Anonymisation comme pour un client : les commandes et le journal d'audit restent.
 */
router.delete('/api/admin/staff/:id', requireManager, h((req, res) => {
  const member = getStaff(req.params.id);
  if (!member) throw httpError(404, 'Membre du personnel introuvable');
  if (member.id === req.user.id) throw httpError(400, 'Vous ne pouvez pas supprimer votre propre compte');
  assertCanManage(req.user, member);
  transaction(() => {
    db.prepare(
      `UPDATE users SET name = 'Compte supprimé', phone = ?, email = NULL, address = NULL, momo_phone = NULL,
         avatar_url = NULL, password_hash = ?, active = 0, token_version = COALESCE(token_version, 0) + 1,
         deleted_at = datetime('now') WHERE id = ?`,
    ).run(
      `supprime-${member.id}-${crypto.randomBytes(6).toString('hex')}`,
      bcrypt.hashSync(crypto.randomBytes(32).toString('hex'), 10),
      member.id,
    );
  });
  audit('staff_deleted', {
    userId: req.user.id,
    details: { staffId: member.id, name: member.name, admin_level: adminLevelOf(member) },
    ip: req.ip,
  });
  res.status(204).end();
}));

module.exports = { router, staffJson, ensureOwner };
