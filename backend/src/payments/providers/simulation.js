/**
 * Prestataire de SIMULATION (par défaut quand aucune clé n'est configurée).
 * Aucun argent réel : la route POST /api/orders/:id/payments/current/simulate
 * joue le rôle du client qui saisit (ou non) son code PIN sur son téléphone.
 * Sans action, la tentative expire (délai géré par le cœur : ~2 min).
 */
const { parseJson } = require('../util');

module.exports = {
  name: 'simulation',
  simulated: true,
  expirySeconds: Number(process.env.PAYMENT_EXPIRY_SECONDS) || 120,
  isConfigured: () => true,

  async initiate({ payment }) {
    return { providerReference: `SIM-${payment.id}`, status: 'pending' };
  },

  async checkStatus(payment) {
    const st = parseJson(payment.provider_state);
    if (st.result === 'paid') {
      return {
        status: 'paid',
        amount: Number.isFinite(st.amount) ? st.amount : payment.amount,
        operatorReference: st.operatorReference || `SIMOP-${payment.id}`,
        raw: st,
      };
    }
    if (st.result === 'failed') {
      return { status: 'failed', message: 'Paiement refusé (code PIN non saisi ou solde insuffisant).', raw: st };
    }
    return { status: 'pending', raw: st };
  },

  verifyWebhook() {
    return null;
  },
};
