const { db, getSettings } = require('./db');
const { log } = require('./logger');

/** Enregistre une action sensible dans le journal d'audit. */
function audit(action, { userId = null, details = null, ip = null } = {}) {
  db.prepare('INSERT INTO audit_logs (user_id, action, details, ip) VALUES (?, ?, ?, ?)').run(
    userId,
    action,
    details ? JSON.stringify(details) : null,
    ip,
  );
}

/**
 * Crée une alerte, sauf si une alerte du même type (et même clé) existe déjà
 * sur la période [dedupeMinutes] : évite de noyer l'administrateur.
 */
function raiseAlert(type, severity, message, details = null, dedupeMinutes = 30) {
  const key = details?.key ?? null;
  const recent = db
    .prepare(
      `SELECT id, details FROM alerts WHERE type = ? AND created_at >= datetime('now', ?)`,
    )
    .all(type, `-${dedupeMinutes} minutes`)
    .some((a) => (key === null ? true : JSON.parse(a.details || '{}').key === key));
  if (recent) return null;
  const info = db
    .prepare('INSERT INTO alerts (type, severity, message, details) VALUES (?, ?, ?, ?)')
    .run(type, severity, message, details ? JSON.stringify(details) : null);
  log.warn('alerte', { type, severity, alert: message, details });
  return info.lastInsertRowid;
}

const count = (sql, ...params) => db.prepare(sql).get(...params).n;

/** Nombre de commandes des 10 dernières minutes et moyenne par tranche de 10 min sur les 24 h précédentes. */
function orderRate() {
  const last10 = count(`SELECT COUNT(*) AS n FROM orders WHERE created_at >= datetime('now', '-10 minutes')`);
  const prev24h = count(
    `SELECT COUNT(*) AS n FROM orders
     WHERE created_at >= datetime('now', '-1450 minutes') AND created_at < datetime('now', '-10 minutes')`,
  );
  return { last10, baselinePer10: prev24h / 144 };
}

/** Contrôles exécutés chaque minute. */
function runChecks() {
  try {
    const s = getSettings();

    // 1. Pic global de commandes (ex : attaque, bug, ou très forte affluence).
    const { last10, baselinePer10 } = orderRate();
    if (last10 >= s.spike_min_orders && last10 >= s.spike_factor * Math.max(baselinePer10, 1)) {
      raiseAlert(
        'order_spike',
        last10 >= 2 * s.spike_min_orders ? 'critical' : 'warning',
        `Pic de commandes : ${last10} en 10 min (moyenne habituelle ${baselinePer10.toFixed(1)})`,
        { last10, baselinePer10 },
      );
    }

    // 2. Un même client qui enchaîne les commandes.
    const heavyUsers = db
      .prepare(
        `SELECT o.user_id, u.name, u.phone, COUNT(*) AS n FROM orders o JOIN users u ON u.id = o.user_id
         WHERE o.created_at >= datetime('now', '-10 minutes') GROUP BY o.user_id HAVING n >= 5`,
      )
      .all();
    for (const u of heavyUsers) {
      raiseAlert(
        'user_order_spike',
        'warning',
        `${u.name} (${u.phone}) a passé ${u.n} commandes en 10 min`,
        { key: `user-${u.user_id}`, userId: u.user_id, count: u.n },
        60,
      );
    }

    // 3. Paiements en échec en série.
    const failed = count(
      `SELECT COUNT(*) AS n FROM payments WHERE status = 'failed' AND updated_at >= datetime('now', '-15 minutes')`,
    );
    if (failed >= 5) {
      raiseAlert('payment_failures', 'warning', `${failed} paiements en échec en 15 min`, { failed });
    }

    // 4. Tentatives de connexion échouées (force brute).
    const loginFails = count(
      `SELECT COUNT(*) AS n FROM audit_logs WHERE action = 'login_failed' AND created_at >= datetime('now', '-15 minutes')`,
    );
    if (loginFails >= 20) {
      raiseAlert('bruteforce', 'critical', `${loginFails} connexions échouées en 15 min`, { loginFails });
    }

    // Nettoyage : on garde 90 jours d'audit.
    db.prepare(`DELETE FROM audit_logs WHERE created_at < datetime('now', '-90 days')`).run();
    // Alertes résolues de plus de 90 jours (les non résolues restent visibles).
    db.prepare(`DELETE FROM alerts WHERE resolved = 1 AND created_at < datetime('now', '-90 days')`).run();
  } catch (err) {
    log.error('monitoring', { error: err.message });
  }
}

/** Contrôle immédiat à la création d'une commande (montant anormal). */
function checkOrder(order, user) {
  const s = getSettings();
  if (order.total >= s.high_amount_alert) {
    raiseAlert(
      'high_amount',
      'warning',
      `Commande n°${order.id} d'un montant élevé : ${order.total} FCFA (${user?.name ?? 'client'})`,
      { key: `order-${order.id}`, orderId: order.id, total: order.total },
      0,
    );
  }
}

function startMonitoring() {
  runChecks();
  return setInterval(runChecks, 60 * 1000).unref();
}

module.exports = { audit, raiseAlert, runChecks, checkOrder, startMonitoring, orderRate };
