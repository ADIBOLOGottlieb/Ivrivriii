/**
 * KADEV PAY (agrégateur, checkout dans le navigateur via les pages /pay/:id).
 * Documentation : https://pay.kadev.ci/developer-documentation/
 * - initiate : rien à pousser, le client finalise sur la page /pay/:id (pay_url de la commande).
 * - checkStatus : vérifie la référence KADEV via l'API (jamais sur la foi du navigateur).
 * - verifyWebhook : signature HMAC-SHA512 du corps brut avec KADEV_WEBHOOK_SECRET.
 */
const crypto = require('crypto');

const BASE = process.env.KADEV_BASE_URL || 'https://pay.kadev.ci';
const PUBLIC_KEY = process.env.KADEV_PUBLIC_KEY || '';
const SECRET_KEY = process.env.KADEV_SECRET_KEY || '';
const WEBHOOK_SECRET = process.env.KADEV_WEBHOOK_SECRET || '';

module.exports = {
  name: 'kadev',
  simulated: false,
  browserCheckout: true,
  // Le parcours navigateur prend plus de temps qu'un push USSD.
  expirySeconds: 15 * 60,
  publicKey: PUBLIC_KEY,
  mode: () => (SECRET_KEY.includes('_test_') ? 'sandbox' : 'live'),
  isConfigured: () => !!(PUBLIC_KEY && SECRET_KEY),

  async initiate() {
    return { providerReference: null, status: 'pending', message: 'Finalisez le paiement sur la page sécurisée KADEV PAY.' };
  },

  async checkStatus(payment) {
    if (!payment.provider_reference) return { status: 'pending' };
    const res = await fetch(`${BASE}/api/v1/transactions/verify/${encodeURIComponent(payment.provider_reference)}`, {
      headers: { Authorization: `Bearer ${SECRET_KEY}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(15000),
    });
    const body = await res.json().catch(() => ({}));
    // Format non détaillé dans la doc publique : `status` à la racine ou dans `data`.
    const data = body.data ?? body;
    const status = String(data.status || '').toLowerCase();
    if (res.ok && status === 'paid') {
      const amount = Number(data.amount);
      // metadata.order_id (envoyé par la page /pay/:id) : vérifié par le cœur contre la commande de la tentative.
      const orderId = data.metadata?.order_id ?? null;
      return {
        status: 'paid', amount: Number.isFinite(amount) ? amount : undefined, operatorReference: data.operator_reference,
        orderId: orderId === null || orderId === undefined ? undefined : String(orderId), raw: body,
      };
    }
    if (['failed', 'cancelled', 'canceled'].includes(status)) return { status: 'failed', message: 'Paiement refusé par KADEV PAY.', raw: body };
    return { status: 'pending', raw: body };
  },

  /** Renvoie { providerReference, orderId, payload } si la signature est valide, sinon null. */
  verifyWebhook(req) {
    if (!WEBHOOK_SECRET || !Buffer.isBuffer(req.body)) return null;
    const signature = String(req.get('x_kadevpay_signature') || req.get('x-kadevpay-signature') || '');
    const expected = crypto.createHmac('sha512', WEBHOOK_SECRET).update(req.body).digest('hex');
    if (signature.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) return null;
    let payload;
    try {
      payload = JSON.parse(req.body.toString('utf8'));
    } catch {
      return null;
    }
    const data = payload.data || {};
    if (payload.event !== 'payment.success' || !data.reference) return { ignored: true };
    return { providerReference: String(data.reference), orderId: data.metadata?.order_id ?? null };
  },
};
