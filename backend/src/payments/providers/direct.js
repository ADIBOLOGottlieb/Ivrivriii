/**
 * Connecteurs SQUELETTES pour un futur accès API marchand direct chez l'opérateur
 * (sans agrégateur) : Flooz (Moov Africa Togo) et Mixx by Yas (ex-T-Money).
 * Ils respectent la même interface que les autres prestataires : il suffira de
 * compléter les TODO et de mettre PAYMENT_PROVIDER=direct (ou PAYMENT_PROVIDER_FLOOZ=flooz_direct,
 * PAYMENT_PROVIDER_MIXX=mixx_direct) sans toucher au reste de l'application.
 *
 * TODO (à faire quand l'opérateur aura fourni la documentation et les accès marchands) :
 *  1. Variables : <PREFIX>_API_URL, <PREFIX>_API_KEY / certificats, <PREFIX>_MERCHANT_CODE.
 *  2. initiate : appel « request to pay » / « push USSD » avec le numéro, le montant (= order.total)
 *     et payment.identifier comme référence marchande ; renvoyer { providerReference, status: 'pending' }.
 *  3. checkStatus : interroger le statut par référence ; renvoyer status paid|pending|failed|expired,
 *     le montant réellement débité (amount) et la référence opérateur (operatorReference).
 *  4. verifyWebhook : vérifier la signature / le certificat fournis par l'opérateur et renvoyer
 *     { identifier } ; le paiement reste de toute façon revérifié par checkStatus.
 *  5. refund / listTransactions si l'API marchand les propose (remboursement, rapprochement).
 */

function makeDirect(name, label, prefix) {
  // TODO : renvoyer true quand l'appel réel sera implémenté et les variables <PREFIX>_* renseignées.
  const configured = () => false;
  const notConfigured = () => {
    const err = new Error(`Connecteur ${label} direct non configuré : utilisez PayGate (PAYMENT_PROVIDER=paygate) en attendant l'accès API marchand ${label}.`);
    err.code = 'PROVIDER_NOT_CONFIGURED';
    err.userMessage = `Le paiement ${label} n'est pas encore disponible. Réessayez plus tard ou payez en espèces.`;
    return err;
  };
  return {
    name,
    simulated: false,
    expirySeconds: Number(process.env.PAYMENT_EXPIRY_SECONDS) || 120,
    isConfigured: configured,
    async initiate() {
      throw notConfigured();
    },
    async checkStatus() {
      throw notConfigured();
    },
    verifyWebhook() {
      return null;
    },
  };
}

module.exports = {
  flooz_direct: makeDirect('flooz_direct', 'Flooz (Moov Africa)', 'FLOOZ_DIRECT'),
  mixx_direct: makeDirect('mixx_direct', 'Mixx by Yas', 'MIXX_DIRECT'),
};
