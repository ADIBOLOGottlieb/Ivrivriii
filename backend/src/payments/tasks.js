/**
 * Tâches planifiées des paiements :
 *  - chaque minute : revérification des tentatives en attente (et des expirées récentes chez un
 *    vrai prestataire, pour rattraper un paiement tardif), alerte si un paiement attend > 10 min,
 *    annulation automatique des commandes mobile money non payées ;
 *  - chaque jour (et peu après le démarrage) : rapprochement avec le prestataire.
 */
const { db, getSettings } = require('../db');
const { log } = require('../logger');
const { audit, raiseAlert } = require('../monitor');
const providers = require('./providers');
const core = require('./core');
const { fcfa } = require('./util');

const WAITING_ALERT_MINUTES = 10;
const SETTLEMENT_LATE_HOURS = 48;

async function refreshPending() {
  const pending = db.prepare(`SELECT * FROM payments WHERE status = 'pending' ORDER BY id LIMIT 50`).all();
  for (const p of pending) await core.refreshAttempt(p);
  // Paiement validé sur le téléphone juste après l'expiration locale : on le rattrape.
  const late = db
    .prepare(
      `SELECT p.* FROM payments p JOIN orders o ON o.id = p.order_id
       WHERE p.status = 'expired' AND p.simulated = 0 AND p.updated_at >= datetime('now', '-30 minutes')
         AND (p.last_checked_at IS NULL OR p.last_checked_at <= datetime('now', '-2 minutes'))
         AND o.payment_status NOT IN ('paid', 'refunded')
       ORDER BY p.id LIMIT 20`,
    )
    .all();
  for (const p of late) await core.refreshAttempt(p, { force: true });
}

function alertWaiting() {
  const rows = db
    .prepare(
      `SELECT id, order_id, amount, operator, CAST((julianday('now') - julianday(created_at)) * 1440 AS INTEGER) AS minutes
       FROM payments WHERE status = 'pending' AND created_at <= datetime('now', ?)`,
    )
    .all(`-${WAITING_ALERT_MINUTES} minutes`);
  for (const p of rows) {
    raiseAlert('payment_waiting', 'warning',
      `Paiement de la commande n°${p.order_id} (${fcfa(p.amount)}) en attente depuis ${p.minutes} min : à vérifier`,
      { key: `payment-${p.id}`, paymentId: p.id, orderId: p.order_id }, 24 * 60);
  }
}

function autoCancelUnpaid() {
  const minutes = getSettings().momo_unpaid_cancel_minutes;
  const orders = db
    .prepare(
      `SELECT o.id, o.user_id, o.payment_status, o.total FROM orders o
       WHERE o.status = 'pending' AND o.payment_method IN (${core.MOBILE_METHODS.map(() => '?').join(',')})
         AND o.payment_status IN ('pending', 'failed', 'expired')
         AND o.created_at <= datetime('now', ?)
         AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id AND p.status = 'pending')`,
    )
    .all(...core.MOBILE_METHODS, `-${minutes} minutes`);
  for (const o of orders) {
    const info = db
      .prepare(`UPDATE orders SET status = 'cancelled', updated_at = datetime('now') WHERE id = ? AND status = 'pending'
                AND payment_status NOT IN ('paid', 'refunded')`)
      .run(o.id);
    if (!info.changes) continue;
    audit('order_auto_cancelled', {
      details: { orderId: o.id, userId: o.user_id, payment_status: o.payment_status, total: o.total, after_minutes: minutes },
    });
    log.info('commande non payée annulée automatiquement', { orderId: o.id, minutes });
  }
  return orders.length;
}

let cycleRunning = false;
async function paymentCycle() {
  if (cycleRunning) return;
  cycleRunning = true;
  try {
    await refreshPending();
    alertWaiting();
    autoCancelUnpaid();
  } catch (err) {
    log.error('tâche paiements', { error: err.message });
  } finally {
    cycleRunning = false;
  }
}

/**
 * Rapprochement : compare nos paiements « paid » des dernières 48 h avec le prestataire.
 * - listTransactions disponible : comparaison des deux listes ;
 * - sinon : revérification de chaque paiement via checkStatus.
 */
async function reconcile({ agentId = null, ip = null } = {}) {
  const report = { checked: 0, ok: 0, missing: 0, amount_mismatch: 0, unknown_at_provider: 0, errors: 0, late_settlements: 0 };
  const paid = db
    .prepare(`SELECT * FROM payments WHERE status = 'paid' AND paid_at >= datetime('now', '-48 hours') ORDER BY id`)
    .all();
  const byProvider = new Map();
  for (const p of paid) {
    if (!byProvider.has(p.provider)) byProvider.set(p.provider, []);
    byProvider.get(p.provider).push(p);
  }

  const missing = (p, why) => {
    report.missing++;
    raiseAlert('reconciliation_missing', p.validated_by ? 'warning' : 'critical',
      `Rapprochement : paiement n°${p.id} (commande n°${p.order_id}, ${fcfa(p.gross_amount)}) ${why}`,
      { key: `payment-${p.id}`, paymentId: p.id, orderId: p.order_id }, 24 * 60);
  };
  const mismatch = (p, amount) => {
    report.amount_mismatch++;
    raiseAlert('reconciliation_amount', 'critical',
      `Rapprochement : paiement n°${p.id} (commande n°${p.order_id}) : ${fcfa(p.gross_amount)} chez nous, ${fcfa(amount)} chez le prestataire`,
      { key: `payment-${p.id}`, paymentId: p.id, orderId: p.order_id, amount }, 24 * 60);
  };

  for (const [name, list] of byProvider) {
    const provider = providers.get(name);
    if (!provider) continue;
    if (typeof provider.listTransactions === 'function') {
      let remote;
      try {
        remote = await provider.listTransactions(new Date(Date.now() - 48 * 3600 * 1000), new Date());
      } catch (err) {
        report.errors++;
        log.warn('rapprochement : liste du prestataire indisponible', { provider: name, error: err.message });
        continue;
      }
      const remoteById = new Map(remote.map((t) => [t.identifier, t]));
      for (const p of list) {
        report.checked++;
        const t = remoteById.get(p.identifier);
        if (!t || t.status !== 'paid') missing(p, 'absent chez le prestataire');
        else if (Number.isFinite(Number(t.amount)) && Number(t.amount) !== p.gross_amount) mismatch(p, Number(t.amount));
        else report.ok++;
      }
      const local = new Set(paid.map((p) => p.identifier));
      for (const t of remote) {
        if (t.status !== 'paid' || local.has(t.identifier)) continue;
        const ours = db.prepare('SELECT id, status FROM payments WHERE identifier = ?').get(t.identifier);
        report.unknown_at_provider++;
        raiseAlert('reconciliation_unknown', 'critical',
          `Rapprochement : transaction ${t.identifier} (${fcfa(t.amount)}) payée chez ${name} mais ${ours ? `« ${ours.status} » chez nous` : 'absente de nos données'}`,
          { key: `tx-${t.identifier}`, identifier: t.identifier }, 24 * 60);
      }
      continue;
    }
    for (const p of list) {
      report.checked++;
      try {
        const r = await provider.checkStatus(p);
        if (r.status !== 'paid') missing(p, `n'est pas confirmé par le prestataire (statut « ${r.status} »)`);
        else if (r.amount !== undefined && Number(r.amount) !== p.gross_amount) mismatch(p, Number(r.amount));
        else report.ok++;
      } catch (err) {
        report.errors++;
        log.warn('rapprochement : vérification impossible', { paymentId: p.id, error: err.message });
      }
    }
  }

  const late = db
    .prepare(
      `SELECT COUNT(*) AS n, COALESCE(SUM(net_amount), 0) AS net FROM payments
       WHERE status = 'paid' AND settlement_status = 'en_attente' AND refund_status IS NULL AND paid_at <= datetime('now', ?)`,
    )
    .get(`-${SETTLEMENT_LATE_HOURS} hours`);
  report.late_settlements = late.n;
  if (late.n > 0) {
    raiseAlert('settlement_late', 'warning',
      `${late.n} paiement(s) (${fcfa(late.net)} net) non reversé(s) sur le compte marchand depuis plus de ${SETTLEMENT_LATE_HOURS} h`,
      { key: 'settlement-late', count: late.n, net: late.net }, 20 * 60);
  }
  audit('reconciliation_run', { userId: agentId, details: report, ip });
  log.info('rapprochement des paiements', report);
  return report;
}

function startPaymentTasks() {
  const every = Number(process.env.PAYMENT_TASK_INTERVAL_MS) || 60 * 1000;
  setTimeout(paymentCycle, 5000).unref();
  setInterval(paymentCycle, every).unref();
  const reconcileDelay = Number(process.env.RECONCILE_DELAY_MS) || 10 * 60 * 1000;
  const safeReconcile = () => reconcile().catch((err) => log.error('rapprochement', { error: err.message }));
  setTimeout(safeReconcile, reconcileDelay).unref();
  setInterval(safeReconcile, 24 * 3600 * 1000).unref();
}

module.exports = { startPaymentTasks, paymentCycle, reconcile, autoCancelUnpaid };
