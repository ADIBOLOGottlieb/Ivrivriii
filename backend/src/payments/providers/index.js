/**
 * Choix du prestataire de paiement.
 *
 * Interface commune (PaymentProvider) :
 *   name, simulated, expirySeconds, isConfigured()
 *   initiate({ payment, order, phone, operator, amount }) → { providerReference, status, message?, raw? }
 *   checkStatus(payment) → { status: 'pending'|'paid'|'failed'|'expired', amount?, operatorReference?, message?, raw }
 *   verifyWebhook(req) → { identifier } | null
 *   refund?(payment, amount) → { reference }
 *   listTransactions?(from, to) → [{ identifier, status, amount, operatorReference }]
 *
 * PAYMENT_PROVIDER = simulation | paygate | kadev | direct (flooz_direct / mixx_direct acceptés comme « direct »).
 * Surcharges par opérateur possibles : PAYMENT_PROVIDER_FLOOZ, PAYMENT_PROVIDER_MIXX.
 * Sans configuration valide : simulation (aucun argent réel).
 */
const { log } = require('../../logger');
const simulation = require('./simulation');
const paygate = require('./paygate');
const kadev = require('./kadev');
const { flooz_direct, mixx_direct } = require('./direct');

const registry = { simulation, paygate, kadev, flooz_direct, mixx_direct };

function resolve(wanted, operator) {
  const w = String(wanted || '').trim().toLowerCase();
  if (['direct', 'flooz_direct', 'mixx_direct'].includes(w)) return `${operator}_direct`;
  if (w === 'paygate') {
    if (paygate.isConfigured()) return 'paygate';
    log.error('PAYMENT_PROVIDER=paygate mais PAYGATE_AUTH_TOKEN absent : mode simulation');
    return 'simulation';
  }
  if (w === 'kadev') {
    if (kadev.isConfigured()) return 'kadev';
    log.error('PAYMENT_PROVIDER=kadev mais clés KADEV absentes : mode simulation');
    return 'simulation';
  }
  if (w === 'simulation') return 'simulation';
  // Compatibilité : clés KADEV présentes sans PAYMENT_PROVIDER.
  if (!w && kadev.isConfigured()) return 'kadev';
  return 'simulation';
}

const BY_OPERATOR = {
  flooz: resolve(process.env.PAYMENT_PROVIDER_FLOOZ || process.env.PAYMENT_PROVIDER, 'flooz'),
  mixx: resolve(process.env.PAYMENT_PROVIDER_MIXX || process.env.PAYMENT_PROVIDER, 'mixx'),
};
const MAIN = process.env.PAYMENT_PROVIDER_FLOOZ ? resolve(process.env.PAYMENT_PROVIDER, 'flooz') : BY_OPERATOR.flooz;
const MAIN_NAME = MAIN.endsWith('_direct') ? 'direct' : MAIN;

if (process.env.NODE_ENV === 'production' && Object.values(BY_OPERATOR).includes('simulation')) {
  log.warn('paiements en MODE SIMULATION en production : aucun argent réel encaissé', { providers: BY_OPERATOR });
}

module.exports = {
  /** Nom du prestataire principal (affiché dans /api/settings). */
  mainName: () => MAIN_NAME,
  /** Prestataire utilisé pour un opérateur (flooz / mixx). */
  forOperator: (operator) => registry[BY_OPERATOR[operator]] || simulation,
  /** Prestataire d'une tentative existante (même si la configuration a changé depuis). */
  get: (name) => registry[name] || null,
  byOperator: () => ({ ...BY_OPERATOR }),
  isSimulation: () => Object.values(BY_OPERATOR).every((n) => n === 'simulation'),
  registry,
};
