/**
 * Livraison : espace livreur, « Reçu » du client, gestion des livreurs et attribution (admin),
 * passage automatique à « livrée » sans « Reçu ».
 *
 * Circuit (commande en mode 'delivery') :
 *   ready (sans livreur) → take/assign → delivering (driver_id, picked_up_at)
 *   → « Livraison faite » (driver_delivered_at, reste delivering)
 *   → « Reçu » client ou délai delivery_auto_confirm_hours → delivered (received_at si client).
 * Toutes les actions sont auditées (agent, commande, livreur).
 */
const express = require('express');
const bcrypt = require('bcryptjs');
const { db, getSettings } = require('./db');
const { requireAuth, requireAdmin, requireDriver } = require('./auth');
const { log } = require('./logger');
const { audit } = require('./monitor');
const { h, httpError } = require('./payments/util');
const { isMobileMoney } = require('./payments/core');

const PHONE_RE = /^\+?[\d\s]{8,16}$/;
const SCOPES = ['available', 'mine', 'history'];

/** Une commande mobile money doit être payée avant de partir en livraison. */
function assertPaid(order) {
  if (isMobileMoney(order.payment_method) && order.payment_status !== 'paid') {
    throw httpError(400, 'Paiement pas encore reçu');
  }
}

function driverJson(id) {
  const u = db
    .prepare(
      `SELECT u.*,
         (SELECT COUNT(*) FROM orders o WHERE o.driver_id = u.id AND o.status = 'delivering') AS active_deliveries,
         (SELECT COUNT(*) FROM orders o WHERE o.driver_id = u.id AND o.status = 'delivered') AS delivered_count
       FROM users u WHERE u.id = ?`,
    )
    .get(id);
  if (!u) return null;
  return {
    id: u.id,
    name: u.name,
    phone: u.phone,
    active: Number(u.active ?? 1) === 1,
    active_deliveries: Number(u.active_deliveries),
    delivered_count: Number(u.delivered_count),
    created_at: u.created_at,
  };
}

function getDriverRow(id) {
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(Number(id));
  if (!u || u.deleted_at || u.role !== 'driver') return null;
  return u;
}

/**
 * Passe à « livrée » les livraisons indiquées faites par le livreur depuis plus de
 * delivery_auto_confirm_hours sans « Reçu » du client. @returns le nombre de commandes passées.
 */
function autoConfirmDeliveries() {
  const hours = getSettings().delivery_auto_confirm_hours;
  const rows = db
    .prepare(
      `SELECT id, user_id, driver_id, driver_delivered_at FROM orders
       WHERE status = 'delivering' AND driver_delivered_at IS NOT NULL AND driver_delivered_at <= datetime('now', ?)`,
    )
    .all(`-${hours} hours`);
  let done = 0;
  for (const o of rows) {
    const info = db
      .prepare(`UPDATE orders SET status = 'delivered', updated_at = datetime('now')
                WHERE id = ? AND status = 'delivering' AND driver_delivered_at IS NOT NULL`)
      .run(o.id);
    if (!info.changes) continue;
    done++;
    audit('delivery_auto_confirmed', {
      details: { orderId: o.id, userId: o.user_id, driverId: o.driver_id, driver_delivered_at: o.driver_delivered_at, after_hours: hours },
    });
    log.info('livraison confirmée automatiquement', { orderId: o.id, hours });
  }
  return done;
}

function startDeliveryTasks() {
  const every = Number(process.env.DELIVERY_TASK_INTERVAL_MS) || 5 * 60 * 1000;
  const run = () => {
    try {
      autoConfirmDeliveries();
    } catch (err) {
      log.error('tâche livraisons', { error: err.message });
    }
  };
  setTimeout(run, Math.min(every, 5000)).unref();
  setInterval(run, every).unref();
}

/**
 * @param {{ loadOrder: Function, loadOrders: Function, presentOrder: Function }} deps fonctions de server.js
 */
function createDeliveryRouter({ loadOrder, loadOrders, presentOrder }) {
  const router = express.Router();
  const orderJson = (id, viewer) => presentOrder(loadOrder(Number(id)), viewer);
  const findOrder = (id) => {
    const order = loadOrder(Number(id));
    if (!order) throw httpError(404, 'Commande introuvable');
    return order;
  };

  // ---------- Livreur ----------

  router.get('/api/driver/orders', requireDriver, h((req, res) => {
    const scope = req.query.scope || 'available';
    if (!SCOPES.includes(scope)) throw httpError(400, 'Liste invalide (available, mine ou history)');
    let rows;
    if (scope === 'available') {
      rows = loadOrders(`WHERE o.status = 'ready' AND o.mode = 'delivery' AND o.driver_id IS NULL`, [],
        { orderBy: 'o.updated_at ASC, o.id ASC' });
    } else if (scope === 'mine') {
      rows = loadOrders(`WHERE o.status = 'delivering' AND o.driver_id = ?`, [req.user.id],
        { orderBy: 'o.driver_delivered_at IS NOT NULL, o.picked_up_at ASC, o.id ASC' });
    } else {
      rows = loadOrders(`WHERE o.status = 'delivered' AND o.driver_id = ?`, [req.user.id],
        { orderBy: 'COALESCE(o.received_at, o.driver_delivered_at, o.updated_at) DESC, o.id DESC', limit: 50 });
    }
    res.json(rows.map((o) => presentOrder(o, req.user)));
  }));

  router.post('/api/driver/orders/:id/take', requireDriver, h((req, res) => {
    const order = findOrder(req.params.id);
    if (order.driver_id) {
      if (order.driver_id === req.user.id && order.status === 'delivering') return res.json(orderJson(order.id, req.user));
      throw httpError(409, 'Cette livraison a déjà été prise par un autre livreur');
    }
    if (order.mode !== 'delivery') throw httpError(400, 'Commande à emporter : pas de livraison');
    if (order.status !== 'ready') throw httpError(400, 'Cette commande n\'est pas prête à être livrée');
    assertPaid(order);
    const info = db
      .prepare(`UPDATE orders SET driver_id = ?, picked_up_at = datetime('now'), driver_delivered_at = NULL,
                  status = 'delivering', updated_at = datetime('now')
                WHERE id = ? AND driver_id IS NULL AND status = 'ready' AND mode = 'delivery'`)
      .run(req.user.id, order.id);
    if (!info.changes) throw httpError(409, 'Cette livraison a déjà été prise par un autre livreur');
    audit('driver_take', { userId: req.user.id, details: { orderId: order.id, driverId: req.user.id }, ip: req.ip });
    res.json(orderJson(order.id, req.user));
  }));

  router.post('/api/driver/orders/:id/delivered', requireDriver, h((req, res) => {
    const order = findOrder(req.params.id);
    if (order.driver_id !== req.user.id) throw httpError(403, 'Cette livraison n\'est pas attribuée à votre compte');
    if (order.status !== 'delivering') throw httpError(400, 'Cette livraison n\'est pas en cours');
    if (!order.driver_delivered_at) {
      db.prepare(`UPDATE orders SET driver_delivered_at = datetime('now'), updated_at = datetime('now')
                  WHERE id = ? AND status = 'delivering' AND driver_id = ? AND driver_delivered_at IS NULL`)
        .run(order.id, req.user.id);
      audit('driver_delivered', {
        userId: req.user.id,
        details: { orderId: order.id, driverId: req.user.id, payment_method: order.payment_method, total: order.total },
        ip: req.ip,
      });
    }
    res.json(orderJson(order.id, req.user));
  }));

  router.post('/api/driver/orders/:id/release', requireDriver, h((req, res) => {
    const order = findOrder(req.params.id);
    if (order.driver_id !== req.user.id) throw httpError(403, 'Cette livraison n\'est pas attribuée à votre compte');
    if (order.status !== 'delivering') throw httpError(400, 'Cette livraison n\'est pas en cours');
    if (order.driver_delivered_at) throw httpError(400, 'Livraison déjà indiquée faite : elle ne peut plus être rendue');
    db.prepare(`UPDATE orders SET driver_id = NULL, picked_up_at = NULL, status = 'ready', updated_at = datetime('now')
                WHERE id = ? AND driver_id = ? AND status = 'delivering'`)
      .run(order.id, req.user.id);
    audit('driver_release', { userId: req.user.id, details: { orderId: order.id, driverId: req.user.id }, ip: req.ip });
    res.json(orderJson(order.id, req.user));
  }));

  router.get('/api/driver/stats', requireDriver, h((req, res) => {
    const row = db
      .prepare(
        `SELECT
           COUNT(CASE WHEN driver_delivered_at IS NOT NULL AND date(driver_delivered_at) = date('now')
                       AND status IN ('delivering', 'delivered') THEN 1 END) AS today_count,
           COALESCE(SUM(CASE WHEN driver_delivered_at IS NOT NULL AND date(driver_delivered_at) = date('now')
                       AND status IN ('delivering', 'delivered') AND payment_method = 'cash' THEN total END), 0) AS today_cash,
           COUNT(CASE WHEN status = 'delivering' THEN 1 END) AS active_count
         FROM orders WHERE driver_id = ?`,
      )
      .get(req.user.id);
    res.json({ today_count: Number(row.today_count), today_cash: Number(row.today_cash), active_count: Number(row.active_count) });
  }));

  // ---------- Client ----------

  router.post('/api/orders/:id/received', requireAuth, h((req, res) => {
    const order = loadOrder(Number(req.params.id));
    if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
    if (order.status === 'delivered') return res.json(orderJson(order.id, req.user));
    if (order.status !== 'delivering' || !order.driver_delivered_at) {
      throw httpError(400, 'Le livreur n\'a pas encore indiqué « Livraison faite »');
    }
    const info = db
      .prepare(`UPDATE orders SET status = 'delivered', received_at = datetime('now'), updated_at = datetime('now')
                WHERE id = ? AND status = 'delivering' AND driver_delivered_at IS NOT NULL`)
      .run(order.id);
    if (info.changes) {
      audit('delivery_received', { userId: req.user.id, details: { orderId: order.id, driverId: order.driver_id }, ip: req.ip });
    }
    res.json(orderJson(order.id, req.user));
  }));

  // ---------- Admin : livreurs ----------

  router.get('/api/admin/drivers', requireAdmin, h((_req, res) => {
    const ids = db
      .prepare(`SELECT * FROM users WHERE role = 'driver' ORDER BY name COLLATE NOCASE, id`)
      .all()
      .filter((u) => !u.deleted_at)
      .map((u) => u.id);
    const list = ids.map(driverJson);
    list.sort((a, b) => Number(b.active) - Number(a.active));
    res.json(list);
  }));

  router.post('/api/admin/drivers', requireAdmin, h((req, res) => {
    const body = req.body || {};
    // Variante : un client existant devient livreur.
    if (body.user_id !== undefined && body.user_id !== null) {
      const user = db.prepare('SELECT * FROM users WHERE id = ?').get(Number(body.user_id));
      if (!user || user.deleted_at) throw httpError(404, 'Compte introuvable');
      if (user.role === 'driver') throw httpError(409, 'Ce compte est déjà livreur');
      if (user.role !== 'customer') throw httpError(400, 'Un administrateur ne peut pas devenir livreur');
      db.prepare(`UPDATE users SET role = 'driver', active = 1 WHERE id = ?`).run(user.id);
      audit('driver_created', { userId: req.user.id, details: { driverId: user.id, from: 'customer' }, ip: req.ip });
      return res.status(201).json(driverJson(user.id));
    }
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    const phone = typeof body.phone === 'string' ? body.phone.trim() : '';
    const password = typeof body.password === 'string' ? body.password : '';
    if (!name || !phone || !password) throw httpError(400, 'Nom, téléphone et mot de passe requis');
    if (password.length < 6) throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
    if (!PHONE_RE.test(phone)) throw httpError(400, 'Numéro de téléphone invalide');
    if (db.prepare('SELECT id FROM users WHERE phone = ?').get(phone)) throw httpError(409, 'Ce numéro est déjà utilisé');
    const info = db
      .prepare(`INSERT INTO users (name, phone, password_hash, role, active) VALUES (?, ?, ?, 'driver', 1)`)
      .run(name.slice(0, 80), phone, bcrypt.hashSync(password, 10));
    const id = Number(info.lastInsertRowid);
    audit('driver_created', { userId: req.user.id, details: { driverId: id, name: name.slice(0, 80) }, ip: req.ip });
    res.status(201).json(driverJson(id));
  }));

  router.patch('/api/admin/drivers/:id', requireAdmin, h((req, res) => {
    const driver = getDriverRow(req.params.id);
    if (!driver) throw httpError(404, 'Livreur introuvable');
    const { active, name, password } = req.body || {};
    const sets = [];
    const params = [];
    const changed = {};
    if (active !== undefined) {
      if (![true, false, 0, 1].includes(active)) throw httpError(400, 'Valeur invalide pour active');
      sets.push('active = ?');
      params.push(active ? 1 : 0);
      changed.active = !!active;
    }
    if (name !== undefined) {
      const n = typeof name === 'string' ? name.trim() : '';
      if (!n) throw httpError(400, 'Nom requis');
      sets.push('name = ?');
      params.push(n.slice(0, 80));
      changed.name = n.slice(0, 80);
    }
    if (password !== undefined) {
      if (typeof password !== 'string' || password.length < 6) {
        throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
      }
      sets.push('password_hash = ?');
      params.push(bcrypt.hashSync(password, 10));
      changed.password = true;
    }
    if (sets.length) {
      db.prepare(`UPDATE users SET ${sets.join(', ')} WHERE id = ?`).run(...params, driver.id);
      audit('driver_updated', { userId: req.user.id, details: { driverId: driver.id, ...changed }, ip: req.ip });
    }
    res.json(driverJson(driver.id));
  }));

  // Attribuer (driver_id) ou retirer (null) le livreur d'une commande en livraison.
  router.patch('/api/admin/orders/:id/assign', requireAdmin, h((req, res) => {
    const order = findOrder(req.params.id);
    const body = req.body || {};
    if (!('driver_id' in body)) throw httpError(400, 'driver_id requis (ou null pour retirer le livreur)');
    if (order.mode !== 'delivery') throw httpError(400, 'Commande à emporter : pas de livreur');
    if (['delivered', 'cancelled'].includes(order.status)) throw httpError(400, 'Cette commande est terminée');
    if (order.driver_delivered_at) throw httpError(400, 'Livraison déjà indiquée faite par le livreur');

    if (body.driver_id === null) {
      if (order.driver_id) {
        db.prepare(`UPDATE orders SET driver_id = NULL, picked_up_at = NULL,
                      status = CASE WHEN status = 'delivering' THEN 'ready' ELSE status END, updated_at = datetime('now')
                    WHERE id = ?`).run(order.id);
        audit('order_unassigned', { userId: req.user.id, details: { orderId: order.id, driverId: order.driver_id }, ip: req.ip });
      }
      return res.json(orderJson(order.id, req.user));
    }

    const driver = getDriverRow(body.driver_id);
    if (!driver) throw httpError(404, 'Livreur introuvable');
    if (Number(driver.active ?? 1) !== 1) throw httpError(400, 'Ce livreur est désactivé');
    if (!['ready', 'delivering'].includes(order.status)) throw httpError(400, 'La commande doit être prête avant d\'attribuer un livreur');
    assertPaid(order);
    if (order.driver_id !== driver.id) {
      db.prepare(`UPDATE orders SET driver_id = ?, picked_up_at = datetime('now'), status = 'delivering',
                    updated_at = datetime('now') WHERE id = ?`).run(driver.id, order.id);
      audit('order_assigned', {
        userId: req.user.id,
        details: { orderId: order.id, driverId: driver.id, previousDriverId: order.driver_id ?? null, from: order.status },
        ip: req.ip,
      });
    }
    res.json(orderJson(order.id, req.user));
  }));

  return router;
}

module.exports = { createDeliveryRouter, startDeliveryTasks, autoConfirmDeliveries };
