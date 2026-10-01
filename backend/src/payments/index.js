/**
 * Paiement mobile money (Flooz, Mixx by Yas) — point d'entrée.
 *
 *  providers/   prestataires derrière une interface commune (simulation, paygate, kadev, flooz_direct, mixx_direct)
 *  core.js      tentatives, validation, écarts de montant, remboursements, encaissements, reversements
 *  pages.js     pages navigateur /pay/:id (KADEV) + webhooks (monté avant express.json)
 *  routes.js    API JSON client et admin (montée après express.json)
 *  tasks.js     revérifications, annulation auto des commandes non payées, rapprochement quotidien
 */
const providers = require('./providers');
const core = require('./core');
const pages = require('./pages');
const { createApiRouter } = require('./routes');
const { startPaymentTasks } = require('./tasks');

function paymentInfo() {
  const name = providers.mainName();
  let mode = 'live';
  if (name === 'simulation') mode = 'test';
  else if (name === 'kadev') mode = providers.registry.kadev.mode();
  return { provider: name, mode, providers: providers.byOperator() };
}

/** Vrai si la commande se paie dans le navigateur (KADEV) : l'app reçoit alors un pay_url. */
const usesBrowserCheckout = (method) => core.isMobileMoney(method) && !!providers.forOperator(method).browserCheckout;

module.exports = {
  router: pages.router,
  createApiRouter,
  startPaymentTasks,
  paymentFee: core.paymentFee,
  isMobileMoney: core.isMobileMoney,
  cancelPendingAttempts: core.cancelPendingAttempts,
  newToken: pages.newToken,
  paymentInfo,
  usesBrowserCheckout,
  MOBILE_METHODS: core.MOBILE_METHODS,
};
