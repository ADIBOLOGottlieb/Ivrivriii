/**
 * Paiement mobile money (Flooz, Mixx by Yas) via l'agrégateur KADEV PAY.
 *
 * - Sans clés KADEV configurées, le module fonctionne en MODE TEST : une page de
 *   simulation permet de valider tout le parcours sans argent réel.
 * - Avec KADEV_PUBLIC_KEY / KADEV_SECRET_KEY / KADEV_WEBHOOK_SECRET, la page de paiement
 *   ouvre le checkout KADEV PAY (SDK JavaScript officiel), puis le serveur vérifie
 *   chaque paiement auprès de l'API KADEV avant de le valider.
 *
 * Documentation KADEV PAY : https://pay.kadev.ci/developer-documentation/
 */
const crypto = require('crypto');
const express = require('express');
const { db, transaction, getSettings } = require('./db');
const { log } = require('./logger');
const { audit, raiseAlert } = require('./monitor');

const KADEV_BASE = process.env.KADEV_BASE_URL || 'https://pay.kadev.ci';
const KADEV_PUBLIC_KEY = process.env.KADEV_PUBLIC_KEY || '';
const KADEV_SECRET_KEY = process.env.KADEV_SECRET_KEY || '';
const KADEV_WEBHOOK_SECRET = process.env.KADEV_WEBHOOK_SECRET || '';

const PROVIDER = KADEV_PUBLIC_KEY && KADEV_SECRET_KEY ? 'kadev' : 'simulation';
const MOBILE_METHODS = ['flooz', 'mixx'];

const isMobileMoney = (method) => MOBILE_METHODS.includes(method);

/** Frais de paiement reportés sur le client (arrondis à l'unité supérieure). */
function paymentFee(amount, method) {
  if (!isMobileMoney(method)) return 0;
  return Math.ceil((amount * getSettings().payment_fee_percent) / 100);
}

const newToken = () => crypto.randomBytes(24).toString('hex');

function paymentInfo() {
  return { provider: PROVIDER, mode: PROVIDER === 'simulation' ? 'test' : KADEV_SECRET_KEY.includes('_test_') ? 'sandbox' : 'live' };
}

function findOrderForPayment(id, token) {
  const order = db
    .prepare(`SELECT o.*, u.name AS customer_name, u.email AS customer_email FROM orders o
              JOIN users u ON u.id = o.user_id WHERE o.id = ?`)
    .get(Number(id));
  if (!order || !token || !order.payment_token) return null;
  const a = Buffer.from(String(token));
  const b = Buffer.from(order.payment_token);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  return order;
}

/** Valide le paiement d'une commande (idempotent). */
function markPaid(order, { reference, amount, provider, raw }) {
  if (order.payment_status === 'paid') return false;
  if (Number(amount) !== order.total) {
    raiseAlert(
      'payment_amount_mismatch',
      'critical',
      `Montant payé (${amount} FCFA) différent du total de la commande n°${order.id} (${order.total} FCFA)`,
      { key: `order-${order.id}`, orderId: order.id, amount, reference },
      0,
    );
    return false;
  }
  transaction(() => {
    db.prepare(
      `UPDATE orders SET payment_status = 'paid', payment_reference = ?, paid_at = datetime('now'),
       updated_at = datetime('now') WHERE id = ?`,
    ).run(reference, order.id);
    const existing = db.prepare('SELECT id FROM payments WHERE order_id = ? AND reference = ?').get(order.id, reference);
    if (existing) {
      db.prepare(`UPDATE payments SET status = 'paid', raw = ?, updated_at = datetime('now') WHERE id = ?`).run(
        JSON.stringify(raw ?? null),
        existing.id,
      );
    } else {
      db.prepare(`INSERT INTO payments (order_id, provider, reference, amount, status, raw) VALUES (?, ?, ?, ?, 'paid', ?)`)
        .run(order.id, provider, reference, amount, JSON.stringify(raw ?? null));
    }
  });
  audit('payment_paid', { userId: order.user_id, details: { orderId: order.id, reference, amount, provider } });
  log.info('paiement validé', { orderId: order.id, reference, amount, provider });
  return true;
}

function markFailed(order, { reference, provider, reason }) {
  if (order.payment_status === 'paid') return;
  transaction(() => {
    db.prepare(`UPDATE orders SET payment_status = 'failed', updated_at = datetime('now') WHERE id = ?`).run(order.id);
    db.prepare(`INSERT INTO payments (order_id, provider, reference, amount, status, raw) VALUES (?, ?, ?, ?, 'failed', ?)`)
      .run(order.id, provider, reference ?? null, order.total, JSON.stringify({ reason }));
  });
  audit('payment_failed', { userId: order.user_id, details: { orderId: order.id, reference, reason } });
}

/** Interroge KADEV PAY pour savoir si une référence est réellement payée. */
async function kadevVerify(reference) {
  const res = await fetch(`${KADEV_BASE}/api/v1/transactions/verify/${encodeURIComponent(reference)}`, {
    headers: { Authorization: `Bearer ${KADEV_SECRET_KEY}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(15000),
  });
  const body = await res.json().catch(() => ({}));
  // Le format exact de la réponse n'est pas détaillé dans la documentation publique :
  // on accepte `status` à la racine ou dans `data`.
  const data = body.data ?? body;
  return {
    ok: res.ok,
    paid: res.ok && String(data.status).toLowerCase() === 'paid',
    amount: Number(data.amount),
    raw: body,
  };
}

async function confirmKadev(order, reference) {
  const v = await kadevVerify(reference);
  if (v.paid) return markPaid(order, { reference, amount: v.amount, provider: 'kadev', raw: v.raw });
  log.warn('paiement non confirmé par KADEV', { orderId: order.id, reference, status: v.raw?.status });
  return false;
}

// ---------------------------------------------------------------------------
// Pages HTML de paiement (ouvertes par l'app dans le navigateur du téléphone)
// ---------------------------------------------------------------------------

const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const fcfa = (n) => `${Number(n).toLocaleString('fr-FR').replace(/ | /g, ' ')} FCFA`;

function page(res, { title, body, script = '', nonce = '' }) {
  res.set(
    'Content-Security-Policy',
    [
      "default-src 'self'",
      `script-src 'self' 'nonce-${nonce}' https://pay.kadev.ci`,
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "connect-src 'self' https:",
      'frame-src https:',
    ].join('; '),
  );
  res.type('html').send(`<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} – Ivrivrii Chicken</title>
<style>
  *{box-sizing:border-box} body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#FFF8EC;color:#2B1B17}
  header{background:linear-gradient(135deg,#D7182A,#A50E1E);color:#fff;padding:28px 20px 60px;text-align:center}
  header img{width:84px;height:84px;border-radius:50%;background:#fff;box-shadow:0 8px 24px rgba(0,0,0,.2)}
  header h1{font-size:20px;margin:12px 0 0}
  main{max-width:460px;margin:-40px auto 24px;padding:0 16px}
  .card{background:#fff;border-radius:20px;padding:20px;box-shadow:0 8px 30px rgba(165,14,30,.12)}
  .row{display:flex;justify-content:space-between;padding:6px 0;color:#7A6A64} .row b{color:#2B1B17}
  .total{border-top:1px dashed #e5d8cf;margin-top:8px;padding-top:12px;font-size:18px} .total b{color:#D7182A}
  button,.btn{display:block;width:100%;border:0;border-radius:14px;padding:16px;font-size:16px;font-weight:700;margin-top:14px;cursor:pointer;text-align:center;text-decoration:none}
  .primary{background:#D7182A;color:#fff} .ghost{background:#f1e9e2;color:#2B1B17} .ok{background:#2E9E5B;color:#fff}
  .badge{display:inline-block;background:#FFB800;color:#2B1B17;border-radius:20px;padding:4px 10px;font-size:12px;font-weight:700}
  .muted{color:#7A6A64;font-size:13px;text-align:center;margin-top:14px} .center{text-align:center}
  .big{font-size:54px;text-align:center;margin:4px 0}
</style></head>
<body><header><img src="/public/logo.jpg" alt="Ivrivrii Chicken"><h1>${esc(title)}</h1></header>
<main>${body}</main>${script ? `<script nonce="${nonce}">${script}</script>` : ''}</body></html>`);
}

function summary(order) {
  return `<div class="row"><span>Commande</span><b>n°${order.id}</b></div>
    <div class="row"><span>Sous-total</span><b>${fcfa(order.subtotal)}</b></div>
    ${order.delivery_fee ? `<div class="row"><span>Livraison</span><b>${fcfa(order.delivery_fee)}</b></div>` : ''}
    <div class="row"><span>Frais de paiement (${getSettings().payment_fee_percent} %)</span><b>${fcfa(order.payment_fee)}</b></div>
    <div class="row total"><span>Total à payer</span><b>${fcfa(order.total)}</b></div>`;
}

function resultPage(res, order) {
  const paid = order.payment_status === 'paid';
  page(res, {
    title: paid ? 'Paiement réussi' : 'Paiement non abouti',
    body: `<div class="card center">
      <div class="big">${paid ? '✅' : '⚠️'}</div>
      <p><b>${paid ? `Merci ! La commande n°${order.id} est payée.` : `Le paiement de la commande n°${order.id} n'a pas été confirmé.`}</b></p>
      <p class="muted">${paid ? 'Vous pouvez revenir dans l\'application pour suivre votre commande.' : 'Revenez dans l\'application pour réessayer ou choisir un autre moyen de paiement.'}</p>
    </div>`,
  });
}

const router = express.Router();

router.get('/pay/:id', (req, res) => {
  const order = findOrderForPayment(req.params.id, req.query.t);
  if (!order) return res.status(404).type('text').send('Lien de paiement invalide ou expiré.');
  if (order.payment_status === 'paid' || order.status === 'cancelled') return resultPage(res, order);

  const nonce = crypto.randomBytes(16).toString('base64');
  const methodLabel = order.payment_method === 'flooz' ? 'Flooz (Moov Africa)' : 'Mixx by Yas';

  if (PROVIDER === 'simulation') {
    return page(res, {
      title: 'Paiement',
      nonce,
      body: `<div class="card"><span class="badge">MODE TEST — aucun argent réel</span>
        <p>Paiement par <b>${esc(methodLabel)}</b></p>${summary(order)}
        <form method="post" action="/pay/${order.id}/simulate?t=${esc(req.query.t)}">
          <button class="primary" name="result" value="paid">Simuler un paiement réussi</button>
          <button class="ghost" name="result" value="failed">Simuler un échec</button>
        </form>
        <p class="muted">Configurez les clés KADEV PAY sur le serveur pour activer les vrais paiements.</p></div>`,
    });
  }

  const base = `${req.protocol}://${req.get('host')}`;
  const returnUrl = `${base}/pay/${order.id}/return?t=${encodeURIComponent(req.query.t)}`;
  const opts = {
    public_key: KADEV_PUBLIC_KEY,
    amount: order.total,
    // L'e-mail est obligatoire chez KADEV : on génère une adresse technique si le client n'en a pas.
    email: order.customer_email || `client${order.user_id}@clients.ivrivrii.tg`,
    method: 'momo',
    name: order.customer_name,
    phone: order.phone,
    callback_url: returnUrl,
    metadata: { order_id: order.id, operator: order.payment_method },
  };
  page(res, {
    title: 'Paiement',
    nonce,
    body: `<div class="card"><p>Paiement par <b>${esc(methodLabel)}</b></p>${summary(order)}
      <button class="primary" id="pay">Payer ${fcfa(order.total)}</button>
      <p class="muted" id="msg">Paiement sécurisé par KADEV PAY</p></div>
      <script src="https://pay.kadev.ci/js/v1/kadev-pay.js"></script>`,
    script: `
      var opts = ${JSON.stringify(opts).replace(/</g, '\\u003c')};
      var msg = document.getElementById('msg');
      function launch(){
        if (!window.KadevPay) { msg.textContent = 'Chargement du paiement…'; return setTimeout(launch, 500); }
        KadevPay.checkout(Object.assign({}, opts, {
          onSuccess: function(r){
            msg.textContent = 'Vérification du paiement…';
            fetch('/pay/${order.id}/confirm?t=${encodeURIComponent(req.query.t)}', {
              method: 'POST', headers: {'Content-Type':'application/json'},
              body: JSON.stringify({ reference: r && r.reference })
            }).then(function(){ location.href = ${JSON.stringify(returnUrl)} + '&reference=' + encodeURIComponent(r && r.reference || ''); });
          },
          onClose: function(){ msg.textContent = 'Paiement interrompu. Appuyez sur « Payer » pour réessayer.'; }
        }));
      }
      document.getElementById('pay').addEventListener('click', launch);
      launch();`,
  });
});

router.post('/pay/:id/simulate', express.urlencoded({ extended: false }), (req, res) => {
  if (PROVIDER !== 'simulation') return res.status(404).end();
  const order = findOrderForPayment(req.params.id, req.query.t);
  if (!order) return res.status(404).type('text').send('Lien de paiement invalide.');
  const reference = `TEST-${Date.now()}`;
  if (req.body.result === 'paid') markPaid(order, { reference, amount: order.total, provider: 'simulation' });
  else markFailed(order, { reference, provider: 'simulation', reason: 'échec simulé' });
  resultPage(res, db.prepare('SELECT * FROM orders WHERE id = ?').get(order.id));
});

router.post('/pay/:id/confirm', express.json(), async (req, res) => {
  const order = findOrderForPayment(req.params.id, req.query.t);
  if (!order || PROVIDER !== 'kadev') return res.status(404).json({ error: 'Introuvable' });
  const reference = String(req.body?.reference || '');
  if (!reference) return res.status(400).json({ error: 'Référence manquante' });
  try {
    db.prepare(`INSERT INTO payments (order_id, provider, reference, amount, status) VALUES (?, 'kadev', ?, ?, 'pending')`)
      .run(order.id, reference, order.total);
    const paid = await confirmKadev(order, reference);
    res.json({ paid });
  } catch (err) {
    log.error('vérification KADEV', { orderId: order.id, error: err.message });
    res.status(502).json({ error: 'Vérification impossible, réessayez' });
  }
});

router.get('/pay/:id/return', async (req, res) => {
  let order = findOrderForPayment(req.params.id, req.query.t);
  if (!order) return res.status(404).type('text').send('Lien de paiement invalide.');
  if (PROVIDER === 'kadev' && order.payment_status !== 'paid' && req.query.reference) {
    try {
      await confirmKadev(order, String(req.query.reference));
    } catch (err) {
      log.error('vérification KADEV (retour)', { orderId: order.id, error: err.message });
    }
    order = db.prepare('SELECT * FROM orders WHERE id = ?').get(order.id);
  }
  resultPage(res, order);
});

/**
 * Webhook KADEV PAY. La signature HMAC-SHA512 du corps brut est vérifiée avec
 * KADEV_WEBHOOK_SECRET ; le paiement est ensuite re-vérifié auprès de l'API.
 * ⚠️ En-tête avec « _ » : si un proxy nginx est placé devant, activer `underscores_in_headers on;`.
 */
router.post('/api/payments/kadev/webhook', express.raw({ type: '*/*', limit: '100kb' }), async (req, res) => {
  const signature = String(req.get('x_kadevpay_signature') || req.get('x-kadevpay-signature') || '');
  const expected = crypto.createHmac('sha512', KADEV_WEBHOOK_SECRET).update(req.body).digest('hex');
  const valid =
    KADEV_WEBHOOK_SECRET &&
    signature.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
  if (!valid) {
    audit('webhook_invalid_signature', { ip: req.ip });
    raiseAlert('webhook_invalid', 'critical', `Webhook de paiement avec signature invalide (IP ${req.ip})`, { key: req.ip });
    return res.status(401).end();
  }

  let payload;
  try {
    payload = JSON.parse(req.body.toString('utf8'));
  } catch {
    return res.status(400).end();
  }
  res.status(200).json({ received: true }); // Répondre vite ; le traitement continue.

  const data = payload.data || {};
  if (payload.event !== 'payment.success' || data.status !== 'paid' || !data.reference) return;
  const reference = String(data.reference);
  const orderId =
    data.metadata?.order_id ??
    db.prepare('SELECT order_id FROM payments WHERE reference = ? ORDER BY id DESC').get(reference)?.order_id;
  const order = orderId && db.prepare('SELECT * FROM orders WHERE id = ?').get(Number(orderId));
  if (!order) {
    log.warn('webhook KADEV sans commande associée', { reference });
    return;
  }
  try {
    await confirmKadev(order, reference);
  } catch (err) {
    log.error('webhook KADEV', { reference, error: err.message });
  }
});

module.exports = { router, paymentFee, isMobileMoney, newToken, paymentInfo, MOBILE_METHODS };
