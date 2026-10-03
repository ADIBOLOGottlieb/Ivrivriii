/**
 * Cœur des paiements mobile money : tentatives, validation, écarts de montant,
 * validation/refus manuels, remboursements, encaissements et reversements.
 *
 * Règles d'argent :
 *  - le montant demandé = order.total (recalculé par le serveur à la création de la commande) ;
 *  - un paiement n'est « paid » qu'après checkStatus auprès du prestataire (ou validation admin),
 *    jamais sur la foi d'un webhook ou du navigateur ;
 *  - un montant reçu inférieur au total ne valide pas la commande (tentative « failed » + alerte critique) ;
 *  - idempotence : un paiement déjà payé n'est jamais re-crédité.
 */
const crypto = require('crypto');
const { db, transaction } = require('../db');
const { log } = require('../logger');
const { audit, raiseAlert } = require('../monitor');
const providers = require('./providers');
const { httpError, fcfa, operatorLabel, normalizeMomoPhone, sqlTime, parseJson } = require('./util');
const fees = require('./fees');
const notify = require('../notify');

const MOBILE_METHODS = ['flooz', 'mixx'];
const isMobileMoney = (method) => MOBILE_METHODS.includes(method);
// Délai au-delà duquel une tentative en attente part dans la file « à vérifier ».
const REVIEW_AFTER_MINUTES = 2;

/**
 * Frais de paiement reportés sur le client pour `amount` = sous-total + livraison.
 * Taux = commission de l'agrégateur de l'opérateur (voir fees.js) : le restaurant reçoit `amount`.
 * @returns {{ fee: number, percent: number|null }}
 */
function paymentFeeDetails(amount, method) {
  if (!isMobileMoney(method)) return { fee: 0, percent: null };
  const percent = fees.feePercentFor(method);
  return { fee: fees.customerFee(amount, percent), percent };
}
const paymentFee = (amount, method) => paymentFeeDetails(amount, method).fee;

/** Taux figé sur la commande à sa création (anciennes commandes : taux actuel de l'opérateur). */
function orderFeePercent(order) {
  const stored = order?.payment_fee_percent;
  return stored === null || stored === undefined ? fees.feePercentFor(order?.payment_method) : Number(stored);
}

const getPayment = (id) => db.prepare('SELECT * FROM payments WHERE id = ?').get(Number(id));
const currentPayment = (orderId) =>
  db.prepare('SELECT * FROM payments WHERE order_id = ? ORDER BY id DESC LIMIT 1').get(Number(orderId));
const getOrderRow = (id) =>
  db.prepare(`SELECT o.*, u.name AS customer_name FROM orders o JOIN users u ON u.id = o.user_id WHERE o.id = ?`).get(Number(id));

/** JSON PaymentAttempt (contrat). */
function presentPayment(p) {
  if (!p) return null;
  return {
    id: p.id,
    status: p.status,
    provider: p.provider,
    operator: p.operator,
    amount: p.amount,
    phone: p.phone,
    message: p.message,
    simulated: !!p.simulated,
    expires_at: p.expires_at,
    created_at: p.created_at,
    paid_at: p.paid_at,
    operator_reference: p.operator_reference,
  };
}

const isExpired = (p) => p.expires_at && sqlTime(p.expires_at) <= Date.now();

/** Répercute l'état de la DERNIÈRE tentative sur orders.payment_status (sauf commande payée/remboursée). */
function syncOrder(p) {
  const order = db.prepare('SELECT id, payment_status FROM orders WHERE id = ?').get(p.order_id);
  if (!order || ['paid', 'refunded'].includes(order.payment_status)) return;
  if (currentPayment(order.id)?.id !== p.id) return;
  const map = { pending: 'pending', failed: 'failed', rejected: 'failed', expired: 'expired' };
  if (map[p.status] && map[p.status] !== order.payment_status) {
    db.prepare(`UPDATE orders SET payment_status = ?, updated_at = datetime('now') WHERE id = ?`).run(map[p.status], order.id);
  }
}

function setAttemptStatus(id, status, message, extra = {}) {
  const sets = ['status = ?', 'message = ?', "updated_at = datetime('now')"];
  const params = [status, message ?? null];
  for (const [k, v] of Object.entries(extra)) {
    sets.push(`${k} = ?`);
    params.push(v);
  }
  db.prepare(`UPDATE payments SET ${sets.join(', ')} WHERE id = ?`).run(...params, id);
  const p = getPayment(id);
  syncOrder(p);
  return p;
}

/**
 * Enregistre un paiement confirmé (prestataire ou agent). Idempotent.
 * @returns la tentative à jour
 */
function handlePaid(p, { amount, operatorReference, providerReference, raw, validatedBy = null }) {
  const order = getOrderRow(p.order_id);
  const received = Math.round(Number(amount));
  const opRef = operatorReference ? String(operatorReference).slice(0, 100) : null;

  // Montant inférieur au total : la commande n'est PAS validée.
  if (!(received >= order.total)) {
    const message = `Montant reçu (${fcfa(received)}) inférieur au total (${fcfa(order.total)}) : paiement non validé.`;
    const updated = setAttemptStatus(p.id, 'failed', message, {
      gross_amount: Number.isFinite(received) ? received : null,
      operator_reference: opRef ?? p.operator_reference,
      needs_review: 1,
      raw: JSON.stringify(raw ?? null),
    });
    raiseAlert(
      'payment_amount_mismatch',
      'critical',
      `Commande n°${order.id} : ${message}`,
      { key: `payment-${p.id}`, orderId: order.id, paymentId: p.id, received, total: order.total, reference: opRef },
      0,
    );
    audit('payment_amount_mismatch', {
      userId: validatedBy,
      details: { orderId: order.id, paymentId: p.id, received, total: order.total, reference: opRef, provider: p.provider },
    });
    log.warn('paiement refusé : montant insuffisant', { orderId: order.id, paymentId: p.id, received, total: order.total });
    return updated;
  }

  let outcome = 'already';
  transaction(() => {
    const fresh = getPayment(p.id);
    if (fresh.status === 'paid') return;
    // Commission de l'agrégateur sur le brut reçu, au taux figé sur la commande (fees.js).
    const fee = fees.providerFeeOn(received, orderFeePercent(order));
    db.prepare(
      `UPDATE payments SET status = 'paid', message = NULL, needs_review = 0, gross_amount = ?, provider_fee = ?,
         net_amount = ?, operator_reference = COALESCE(?, operator_reference), provider_reference = COALESCE(?, provider_reference),
         reference = COALESCE(?, reference), paid_at = datetime('now'), settlement_status = 'en_attente',
         validated_by = ?, raw = ?, updated_at = datetime('now')
       WHERE id = ?`,
    ).run(received, fee, received - fee, opRef, providerReference ?? null, opRef ?? providerReference ?? null,
      validatedBy, JSON.stringify(raw ?? null), p.id);
    const o = db.prepare('SELECT payment_status FROM orders WHERE id = ?').get(p.order_id);
    if (['paid', 'refunded'].includes(o.payment_status)) {
      outcome = 'double';
      return;
    }
    db.prepare(
      `UPDATE orders SET payment_status = 'paid', payment_reference = ?, paid_at = datetime('now'),
         updated_at = datetime('now') WHERE id = ?`,
    ).run(opRef || fresh.identifier || providerReference || null, p.order_id);
    outcome = 'paid';
  });

  const details = {
    orderId: order.id, paymentId: p.id, amount: received, operator: p.operator, provider: p.provider,
    operatorReference: opRef, manual: !!validatedBy,
  };
  if (outcome === 'paid') {
    audit('payment_paid', { userId: validatedBy, details });
    raiseAlert(
      'payment_received',
      'info',
      `Paiement reçu – commande n°${order.id} – ${fcfa(received)} – ${operatorLabel(p.operator)}`,
      { key: `payment-${p.id}`, orderId: order.id, paymentId: p.id, amount: received, operator: p.operator },
      0,
    );
    log.info('paiement validé', details);
    if (order.status === 'cancelled') {
      raiseAlert('refund_needed', 'critical',
        `Argent reçu sur la commande annulée n°${order.id} (${fcfa(received)}, ${operatorLabel(p.operator)}) → rembourser le client`,
        { key: `order-${order.id}`, orderId: order.id, paymentId: p.id }, 0);
    } else {
      notify.paymentReceived(order, received);
    }
  } else if (outcome === 'double') {
    audit('payment_double', { userId: validatedBy, details });
    raiseAlert('double_payment', 'critical',
      `Commande n°${order.id} payée deux fois (${fcfa(received)} de plus, ${operatorLabel(p.operator)}) : remboursement à prévoir`,
      { key: `payment-${p.id}`, ...details }, 0);
  }
  return getPayment(p.id);
}

/**
 * Un paiement confirmé par le prestataire appartient-il bien à cette commande ?
 * - la commande indiquée par le prestataire (metadata.order_id, KADEV) doit être celle de la tentative ;
 * - une même référence prestataire ne peut payer qu'une seule commande.
 * @returns message d'erreur, ou null si tout est cohérent
 */
function paidElsewhere(p, r) {
  if (r.orderId !== undefined && r.orderId !== null && String(r.orderId) !== String(p.order_id)) {
    return `le prestataire rattache ce paiement à la commande n°${r.orderId} : non validé`;
  }
  const ref = r.providerReference ?? p.provider_reference;
  if (ref) {
    const other = db
      .prepare(`SELECT id, order_id FROM payments WHERE provider = ? AND provider_reference = ? AND order_id != ? AND status = 'paid' LIMIT 1`)
      .get(p.provider, String(ref), p.order_id);
    if (other) return `référence ${ref} déjà utilisée pour la commande n°${other.order_id} : non validé`;
  }
  return null;
}

/** Applique le résultat d'un checkStatus à une tentative. */
function applyCheck(id, r) {
  const p = getPayment(id);
  if (!p || p.status === 'paid') return p;
  db.prepare(`UPDATE payments SET last_checked_at = datetime('now') WHERE id = ?`).run(id);
  if (r.providerReference && !p.provider_reference) {
    db.prepare('UPDATE payments SET provider_reference = ? WHERE id = ?').run(String(r.providerReference), id);
  }
  const reviewable = ['pending', 'expired'].includes(p.status);
  if (r.status === 'paid') {
    // Un paiement confirmé après un refus manuel reste visible pour l'agent.
    if (p.status === 'rejected') {
      raiseAlert('payment_after_reject', 'critical', `Paiement n°${p.id} (commande n°${p.order_id}) confirmé par le prestataire après refus manuel`,
        { key: `payment-${p.id}`, paymentId: p.id }, 0);
      db.prepare('UPDATE payments SET needs_review = 1 WHERE id = ?').run(id);
      return getPayment(id);
    }
    if (p.needs_review && p.status === 'failed') return p; // écart déjà signalé
    const mismatch = paidElsewhere(p, r);
    if (mismatch) {
      const updated = setAttemptStatus(id, 'failed', mismatch, { needs_review: 1, raw: JSON.stringify(r.raw ?? null), failure_kind: null });
      raiseAlert('payment_reference_mismatch', 'critical', `Paiement n°${p.id} (commande n°${p.order_id}) : ${mismatch}`,
        { key: `payment-${p.id}`, paymentId: p.id, orderId: p.order_id, providerReference: r.providerReference ?? p.provider_reference }, 0);
      audit('payment_reference_mismatch', { details: { orderId: p.order_id, paymentId: p.id, message: mismatch, provider: p.provider } });
      return updated;
    }
    return handlePaid(p, {
      amount: r.amount ?? p.amount,
      operatorReference: r.operatorReference,
      providerReference: r.providerReference,
      raw: r.raw,
    });
  }
  if ((r.status === 'failed' || r.status === 'expired') && reviewable) {
    const message = r.message || (r.status === 'expired' ? 'Délai dépassé : aucun paiement reçu.' : 'Paiement non abouti.');
    const updated = setAttemptStatus(id, r.status, message, { raw: JSON.stringify(r.raw ?? null) });
    audit(r.status === 'expired' ? 'payment_expired' : 'payment_failed', {
      details: { orderId: p.order_id, paymentId: p.id, provider: p.provider, message },
    });
    return updated;
  }
  if (r.status === 'pending' && p.status === 'pending' && isExpired(p)) {
    const updated = setAttemptStatus(id, 'expired', 'Délai dépassé : le paiement n\'a pas été confirmé sur le téléphone.');
    audit('payment_expired', { details: { orderId: p.order_id, paymentId: p.id, provider: p.provider } });
    return updated;
  }
  return getPayment(id);
}

/** Revérifie une tentative auprès de son prestataire. `force` : même si elle n'est plus « pending ». */
async function refreshAttempt(p, { force = false } = {}) {
  if (!p || p.status === 'paid' || (!force && p.status !== 'pending')) return p;
  const provider = providers.get(p.provider);
  if (!provider) return p;
  let r;
  try {
    r = await provider.checkStatus(p);
  } catch (err) {
    log.warn('vérification du paiement impossible', { paymentId: p.id, provider: p.provider, error: err.message });
    db.prepare(`UPDATE payments SET last_checked_at = datetime('now') WHERE id = ?`).run(p.id);
    // Prestataire injoignable : on n'expire pas (le client a peut-être payé), on laisse « pending ».
    return getPayment(p.id);
  }
  return applyCheck(p.id, r || { status: 'pending' });
}

function assertOwner(order, user) {
  if (!order || (order.user_id !== user.id && user.role !== 'admin')) throw httpError(404, 'Commande introuvable');
}

/** Crée une tentative « pending » (montant = order.total) avec un identifiant unique. */
function openAttempt(order, provider, phone) {
  return transaction(() => {
    const info = db
      .prepare(
        `INSERT INTO payments (order_id, provider, amount, status, operator, phone, simulated, expires_at)
         VALUES (?, ?, ?, 'pending', ?, ?, ?, datetime('now', ?))`,
      )
      .run(order.id, provider.name, order.total, order.payment_method, phone, provider.simulated ? 1 : 0, `+${provider.expirySeconds} seconds`);
    const pid = Number(info.lastInsertRowid);
    db.prepare('UPDATE payments SET identifier = ? WHERE id = ?').run(`IVR-${order.id}-${pid}-${crypto.randomBytes(3).toString('hex')}`, pid);
    db.prepare(`UPDATE orders SET payment_status = 'pending', updated_at = datetime('now') WHERE id = ?`).run(order.id);
    return pid;
  });
}

/** Lance un push USSD (le client valide avec son code PIN sur son téléphone). */
async function createAttempt(orderId, { phone, user, ip }) {
  let order = getOrderRow(orderId);
  if (!order || order.user_id !== user.id) throw httpError(404, 'Commande introuvable');
  if (!isMobileMoney(order.payment_method)) throw httpError(400, 'Cette commande se paie en espèces');
  if (order.status === 'cancelled') throw httpError(400, 'Cette commande est annulée');
  if (['paid', 'refunded'].includes(order.payment_status)) throw httpError(400, 'Cette commande est déjà payée');
  if (order.status !== 'pending') throw httpError(400, 'Cette commande ne peut plus être payée en ligne');
  const momo = normalizeMomoPhone(phone ?? order.phone);
  if (!momo) throw httpError(400, 'Numéro mobile money invalide (8 chiffres, ex. 90 12 34 56)');

  // Une tentative précédente encore en attente : on la revérifie avant d'en lancer une autre.
  const previous = currentPayment(order.id);
  if (previous?.status === 'pending') {
    const checked = await refreshAttempt(previous);
    if (checked.status === 'paid') return { order: getOrderRow(order.id), payment: checked };
    if (checked.status === 'pending') {
      setAttemptStatus(checked.id, 'failed', 'Remplacée par une nouvelle demande de paiement.', { failure_kind: 'replaced' });
    }
  }
  order = getOrderRow(order.id);
  if (['paid', 'refunded'].includes(order.payment_status)) throw httpError(400, 'Cette commande est déjà payée');

  const provider = providers.forOperator(order.payment_method);
  const amount = order.total; // jamais le montant envoyé par l'app
  const id = openAttempt(order, provider, momo);
  audit('payment_initiated', {
    userId: user.id,
    details: { orderId: order.id, paymentId: id, amount, operator: order.payment_method, provider: provider.name },
    ip,
  });

  let payment = getPayment(id);
  try {
    const r = await provider.initiate({ payment, order, phone: momo, operator: order.payment_method, amount });
    if (r.status === 'failed') {
      payment = setAttemptStatus(id, 'failed', r.message || 'Le paiement n\'a pas pu être lancé.', { raw: JSON.stringify(r.raw ?? null) });
      audit('payment_failed', { userId: user.id, details: { orderId: order.id, paymentId: id, message: payment.message } });
    } else {
      db.prepare('UPDATE payments SET provider_reference = ?, reference = ?, message = ?, raw = ? WHERE id = ?')
        .run(r.providerReference ?? null, r.providerReference ?? null, r.message ?? null, JSON.stringify(r.raw ?? null), id);
      payment = getPayment(id);
    }
  } catch (err) {
    log.error('lancement du paiement', { orderId: order.id, paymentId: id, provider: provider.name, error: err.message });
    payment = setAttemptStatus(id, 'failed', err.userMessage || 'Le service de paiement est momentanément indisponible. Réessayez dans un instant.',
      { failure_kind: 'error' });
    audit('payment_failed', { userId: user.id, details: { orderId: order.id, paymentId: id, error: err.message } });
  }
  return { order: getOrderRow(order.id), payment };
}

/** Tentative courante, revérifiée auprès du prestataire si elle est en attente. */
async function getCurrent(orderId, user) {
  const order = getOrderRow(orderId);
  assertOwner(order, user);
  let payment = currentPayment(order.id);
  if (payment?.status === 'pending') payment = await refreshAttempt(payment);
  return { order: getOrderRow(order.id), payment: payment || null };
}

/** « Paiement non abouti » : le client abandonne la tentative en cours. */
async function abandonCurrent(orderId, { user, ip }) {
  const order = getOrderRow(orderId);
  if (!order || order.user_id !== user.id) throw httpError(404, 'Commande introuvable');
  let payment = currentPayment(order.id);
  if (!payment) throw httpError(404, 'Aucun paiement en cours');
  if (payment.status === 'pending') payment = await refreshAttempt(payment); // payé entre-temps ?
  if (payment.status === 'paid') throw httpError(400, 'Ce paiement a déjà été reçu');
  if (['pending', 'expired'].includes(payment.status)) {
    payment = setAttemptStatus(payment.id, 'failed', 'Paiement non abouti', { failure_kind: 'abandoned' });
  }
  if (!['paid', 'refunded'].includes(order.payment_status)) {
    db.prepare(`UPDATE orders SET payment_status = 'failed', updated_at = datetime('now') WHERE id = ?`).run(order.id);
  }
  audit('payment_abandoned', { userId: user.id, details: { orderId: order.id, paymentId: payment.id }, ip });
  return { order: getOrderRow(order.id), payment: getPayment(payment.id) };
}

/** Mode simulation : joue la saisie (ou non) du code PIN. `amount` optionnel pour tester un écart. */
async function simulateCurrent(orderId, { user, result, amount, ip }) {
  if (providers.mainName() !== 'simulation') throw httpError(403, 'Simulation indisponible : paiements réels activés');
  if (!providers.simulationAllowed()) throw httpError(403, 'Mode test désactivé');
  const order = getOrderRow(orderId);
  if (!order || order.user_id !== user.id) throw httpError(404, 'Commande introuvable');
  if (!['paid', 'failed'].includes(result)) throw httpError(400, 'Résultat attendu : paid ou failed');
  const payment = currentPayment(order.id);
  if (!payment || payment.provider !== 'simulation') throw httpError(404, 'Aucun paiement simulé en cours');
  if (payment.status !== 'pending') throw httpError(400, 'Aucun paiement en attente');
  const state = { ...parseJson(payment.provider_state), result };
  if (amount !== undefined && amount !== null) {
    const a = Math.round(Number(amount));
    if (!Number.isFinite(a) || a < 0) throw httpError(400, 'Montant simulé invalide');
    state.amount = a;
  }
  db.prepare('UPDATE payments SET provider_state = ? WHERE id = ?').run(JSON.stringify(state), payment.id);
  audit('payment_simulated', { userId: user.id, details: { orderId: order.id, paymentId: payment.id, result, amount: state.amount }, ip });
  const updated = await refreshAttempt(getPayment(payment.id));
  return { order: getOrderRow(order.id), payment: updated };
}

/** Annule les tentatives en attente d'une commande (commande annulée). */
function cancelPendingAttempts(orderId, message = 'Commande annulée') {
  for (const p of db.prepare(`SELECT * FROM payments WHERE order_id = ? AND status = 'pending'`).all(Number(orderId))) {
    setAttemptStatus(p.id, 'failed', message, { failure_kind: 'cancelled' });
  }
}

// ---------------------------------------------------------------------------
// Admin : file « à vérifier », validation / refus manuels, remboursement
// ---------------------------------------------------------------------------

function reviewQueue() {
  return db
    .prepare(
      `SELECT p.*, o.total AS order_total, u.name AS customer_name,
              CAST((julianday('now') - julianday(p.created_at)) * 1440 AS INTEGER) AS waiting_minutes
       FROM payments p JOIN orders o ON o.id = p.order_id JOIN users u ON u.id = o.user_id
       WHERE p.needs_review = 1
          OR (p.status = 'pending' AND p.created_at <= datetime('now', ?)
              AND o.payment_status NOT IN ('paid', 'refunded') AND o.status != 'cancelled')
       ORDER BY p.created_at ASC LIMIT 200`,
    )
    .all(`-${REVIEW_AFTER_MINUTES} minutes`)
    .map((p) => ({
      ...presentPayment(p),
      order_id: p.order_id,
      customer_name: p.customer_name,
      order_total: p.order_total,
      waiting_minutes: p.waiting_minutes,
      received_amount: p.gross_amount,
    }));
}

function validateManual(paymentId, { reference, amount, agentId, ip }) {
  const p = getPayment(paymentId);
  if (!p) throw httpError(404, 'Paiement introuvable');
  const ref = String(reference ?? '').trim();
  if (!ref) throw httpError(400, 'Référence de la transaction obligatoire (SMS de l\'opérateur)');
  const received = Math.round(Number(amount));
  if (amount === undefined || amount === null || amount === '' || !Number.isFinite(received)) {
    throw httpError(400, 'Montant reçu obligatoire');
  }
  const order = getOrderRow(p.order_id);
  if (received < order.total) {
    throw httpError(400, `Montant reçu (${fcfa(received)}) inférieur au total de la commande (${fcfa(order.total)}) : validation impossible.`);
  }
  if (p.status === 'paid') throw httpError(400, 'Ce paiement est déjà validé');
  if (['paid', 'refunded'].includes(order.payment_status)) throw httpError(400, 'Cette commande est déjà payée');
  const used = db.prepare(`SELECT id FROM payments WHERE operator_reference = ? AND status = 'paid'`).get(ref.slice(0, 100));
  if (used) throw httpError(409, `Référence déjà utilisée pour le paiement n°${used.id}`);
  const updated = handlePaid(p, { amount: received, operatorReference: ref, raw: { manual: true }, validatedBy: agentId });
  audit('payment_validated_manual', {
    userId: agentId,
    details: { orderId: order.id, paymentId: p.id, reference: ref, amount: received, total: order.total },
    ip,
  });
  return { order: getOrderRow(order.id), payment: updated };
}

function rejectPayment(paymentId, { reason, agentId, ip }) {
  const p = getPayment(paymentId);
  if (!p) throw httpError(404, 'Paiement introuvable');
  if (p.status === 'paid') throw httpError(400, 'Paiement déjà validé : utilisez le remboursement');
  const message = String(reason ?? '').trim().slice(0, 300) || 'Paiement refusé après vérification par le restaurant.';
  const updated = setAttemptStatus(p.id, 'rejected', message, { needs_review: 0 });
  audit('payment_rejected', { userId: agentId, details: { orderId: p.order_id, paymentId: p.id, reason: message }, ip });
  return { order: getOrderRow(p.order_id), payment: updated };
}

async function refundOrder(orderId, { reference, agentId, ip }) {
  const order = getOrderRow(orderId);
  if (!order) throw httpError(404, 'Commande introuvable');
  if (order.payment_status === 'refunded') throw httpError(400, 'Cette commande est déjà remboursée');
  if (order.payment_status !== 'paid') throw httpError(400, 'Cette commande n\'a pas été payée en ligne');
  const p = db.prepare(`SELECT * FROM payments WHERE order_id = ? AND status = 'paid' ORDER BY id DESC LIMIT 1`).get(order.id);
  let ref = String(reference ?? '').trim().slice(0, 100);
  let via = 'manual';
  const provider = p && providers.get(p.provider);
  if (!ref) {
    if (!p || typeof provider?.refund !== 'function') {
      throw httpError(400, 'Référence du remboursement obligatoire (le prestataire ne rembourse pas automatiquement)');
    }
    try {
      const r = await provider.refund(p, p.gross_amount ?? p.amount);
      ref = String(r?.reference || '').slice(0, 100);
      via = p.provider;
    } catch (err) {
      log.error('remboursement prestataire', { orderId: order.id, error: err.message });
      throw httpError(502, 'Le remboursement automatique a échoué : remboursez manuellement et saisissez la référence');
    }
    if (!ref) throw httpError(502, 'Le prestataire n\'a pas confirmé le remboursement');
  }
  transaction(() => {
    if (p) {
      db.prepare(
        `UPDATE payments SET refund_status = 'refunded', refund_reference = ?, refunded_at = datetime('now'),
           refunded_by = ?, updated_at = datetime('now') WHERE id = ?`,
      ).run(ref, agentId, p.id);
    }
    db.prepare(`UPDATE orders SET payment_status = 'refunded', updated_at = datetime('now') WHERE id = ?`).run(order.id);
  });
  audit('payment_refunded', {
    userId: agentId,
    details: { orderId: order.id, paymentId: p?.id ?? null, amount: p?.gross_amount ?? order.total, reference: ref, via },
    ip,
  });
  return getOrderRow(order.id);
}

// ---------------------------------------------------------------------------
// Encaissements et reversements
// ---------------------------------------------------------------------------

function collectionFilters(q = {}) {
  const where = [`p.status = 'paid'`];
  const params = [];
  const day = /^\d{4}-\d{2}-\d{2}$/;
  if (q.from) {
    if (!day.test(q.from)) throw httpError(400, 'Date de début invalide (AAAA-MM-JJ)');
    where.push('date(p.paid_at) >= ?');
    params.push(q.from);
  }
  if (q.to) {
    if (!day.test(q.to)) throw httpError(400, 'Date de fin invalide (AAAA-MM-JJ)');
    where.push('date(p.paid_at) <= ?');
    params.push(q.to);
  }
  if (q.operator) {
    if (!isMobileMoney(q.operator)) throw httpError(400, 'Opérateur invalide');
    where.push('p.operator = ?');
    params.push(q.operator);
  }
  if (q.settlement) {
    if (!['en_attente', 'reverse'].includes(q.settlement)) throw httpError(400, 'Filtre de reversement invalide');
    where.push('p.settlement_status = ?');
    params.push(q.settlement);
  }
  return { sql: `WHERE ${where.join(' AND ')}`, params };
}

function collections(q) {
  const f = collectionFilters(q);
  const sums = `COALESCE(SUM(p.gross_amount), 0) AS gross, COALESCE(SUM(p.provider_fee), 0) AS fees,
    COALESCE(SUM(p.net_amount), 0) AS net,
    COALESCE(SUM(CASE WHEN p.settlement_status = 'reverse' THEN p.net_amount END), 0) AS settled,
    COALESCE(SUM(CASE WHEN p.refund_status = 'refunded' THEN p.gross_amount END), 0) AS refunded,
    COUNT(*) AS count`;
  const summary = db
    .prepare(`SELECT date(p.paid_at) AS day, p.operator, ${sums} FROM payments p ${f.sql}
              GROUP BY day, p.operator ORDER BY day DESC, p.operator`)
    .all(...f.params);
  const totals = db.prepare(`SELECT ${sums} FROM payments p ${f.sql}`).get(...f.params);
  const payments = db
    .prepare(
      `SELECT p.id, p.order_id, p.operator, p.provider, p.gross_amount AS gross, p.provider_fee, p.net_amount AS net,
              p.operator_reference, p.settlement_status, p.settlement_reference, p.settled_at, p.paid_at,
              p.refund_status, p.refund_reference, p.validated_by, u.name AS customer_name
       FROM payments p JOIN orders o ON o.id = p.order_id JOIN users u ON u.id = o.user_id
       ${f.sql} ORDER BY p.paid_at DESC, p.id DESC LIMIT 2000`,
    )
    .all(...f.params);
  return { summary, totals, payments };
}

function recordSettlement({ paymentIds, reference, agentId, ip }) {
  if (!Array.isArray(paymentIds) || paymentIds.length === 0 || paymentIds.length > 1000) {
    throw httpError(400, 'Sélectionnez au moins un paiement');
  }
  const ids = [...new Set(paymentIds.map(Number))];
  if (!ids.every((n) => Number.isInteger(n) && n > 0)) throw httpError(400, 'Identifiants de paiement invalides');
  const ref = String(reference ?? '').trim().slice(0, 100);
  if (!ref) throw httpError(400, 'Référence du virement obligatoire');
  const placeholders = ids.map(() => '?').join(',');
  const { updated, net } = transaction(() => {
    const rows = db
      .prepare(`SELECT id, net_amount FROM payments WHERE id IN (${placeholders}) AND status = 'paid' AND settlement_status = 'en_attente'`)
      .all(...ids);
    const target = rows.map((r) => r.id);
    if (target.length) {
      db.prepare(
        `UPDATE payments SET settlement_status = 'reverse', settled_at = datetime('now'), settlement_reference = ?,
           updated_at = datetime('now') WHERE id IN (${target.map(() => '?').join(',')})`,
      ).run(ref, ...target);
    }
    return { updated: target.length, net: rows.reduce((s, r) => s + (r.net_amount || 0), 0), target };
  });
  audit('settlement_recorded', { userId: agentId, details: { reference: ref, paymentIds: ids, updated, net }, ip });
  return { updated };
}

function recentPaid(sinceId) {
  const since = Number(sinceId);
  if (Number.isInteger(since) && since >= 0 && sinceId !== undefined) {
    return db
      .prepare(`SELECT id, order_id, gross_amount AS amount, operator, paid_at FROM payments
                WHERE status = 'paid' AND id > ? ORDER BY id ASC LIMIT 50`)
      .all(since);
  }
  return db
    .prepare(`SELECT id, order_id, gross_amount AS amount, operator, paid_at FROM payments
              WHERE status = 'paid' ORDER BY id DESC LIMIT 20`)
    .all()
    .reverse();
}

module.exports = {
  MOBILE_METHODS,
  isMobileMoney,
  paymentFee,
  paymentFeeDetails,
  orderFeePercent,
  getPayment,
  currentPayment,
  getOrderRow,
  presentPayment,
  refreshAttempt,
  applyCheck,
  handlePaid,
  setAttemptStatus,
  openAttempt,
  createAttempt,
  getCurrent,
  abandonCurrent,
  simulateCurrent,
  cancelPendingAttempts,
  reviewQueue,
  validateManual,
  rejectPayment,
  refundOrder,
  collections,
  collectionFilters,
  recordSettlement,
  recentPaid,
};
