/**
 * Frais de paiement mobile money : SOURCE UNIQUE du taux et des calculs.
 *
 * Taux p (en %) par opérateur :
 *  1. PROVIDER_FEE_PERCENT_FLOOZ / PROVIDER_FEE_PERCENT_MIXX (commission du contrat de l'agrégateur) ;
 *  2. sinon PROVIDER_FEE_PERCENT (même commission pour les deux opérateurs) ;
 *  3. sinon (ou si l'opérateur est en simulation : pas d'agrégateur) le réglage admin payment_fee_percent.
 * Le même taux sert au total client, au montant envoyé au prestataire et au net du restaurant.
 *
 * Formule (B = sous-total + livraison, en FCFA entiers) :
 *  - l'agrégateur prélève p % du montant BRUT G payé par le client ;
 *  - pour que le restaurant reçoive B : G = B / (1 − p/100), arrondi à l'unité supérieure ;
 *  - frais client = G − B ;
 *  - frais agrégateur = ceil(G × p / 100) : on suppose l'arrondi le moins favorable au restaurant
 *    (à l'unité supérieure). Avec cet arrondi, net = G − frais = B exactement ; si l'agrégateur
 *    arrondit au plus proche ou à l'inférieur, le net réel est B ou B + 1 (jamais moins que B).
 * Calculs en entiers (taux en centièmes de %, ex. 3,5 % → 350) : aucun écart d'arrondi flottant.
 * La même formule est reprise dans l'app (mobile/lib/utils/format.dart, paymentFeeFor).
 */
const OPERATORS = ['flooz', 'mixx'];
const MAX_ENV_PERCENT = 20;

/** Taux en centièmes de % (2,5 % → 250), borné à [0, 99,99 %]. */
function basisPoints(percent) {
  const n = Number(percent);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(Math.round(n * 100), 9999);
}

/** Montant brut à demander au client pour que le restaurant reçoive `base` après commission. */
function grossUp(base, percent) {
  const b = Math.round(Number(base) || 0);
  const bp = basisPoints(percent);
  if (b <= 0 || bp === 0) return Math.max(b, 0);
  const d = 10000 - bp;
  return Math.floor((b * 10000 + d - 1) / d); // ceil(b × 10000 / d) en entiers
}

/** Frais de paiement facturés au client (à ajouter à sous-total + livraison). */
function customerFee(base, percent) {
  return grossUp(base, percent) - Math.max(Math.round(Number(base) || 0), 0);
}

/** Commission de l'agrégateur sur un montant brut reçu (arrondi à l'unité supérieure). */
function providerFeeOn(gross, percent) {
  const g = Math.round(Number(gross) || 0);
  const bp = basisPoints(percent);
  if (g <= 0 || bp === 0) return 0;
  return Math.floor((g * bp + 9999) / 10000); // ceil(g × bp / 10000)
}

/** Lit un taux dans l'environnement : null si absent ou invalide. */
function envPercent(name) {
  const raw = process.env[name];
  if (raw === undefined || String(raw).trim() === '') return null;
  const n = Number(String(raw).trim().replace(',', '.'));
  if (!Number.isFinite(n) || n < 0 || n > MAX_ENV_PERCENT) return null;
  return Math.round(n * 100) / 100;
}

/** Vrai si l'opérateur passe par un vrai prestataire (pas la simulation). */
function hasAggregator(operator) {
  const providers = require('./providers');
  return providers.byOperator()[operator] !== 'simulation';
}

/** Taux du réglage admin (repli). */
function settingsPercent() {
  return Number(require('../db').getSettings().payment_fee_percent) || 0;
}

/**
 * Taux appliqué à un opérateur et sa provenance.
 * @returns {{ percent: number, source: 'aggregator'|'settings' }}
 */
function feeRateFor(operator) {
  if (OPERATORS.includes(operator) && hasAggregator(operator)) {
    const env = envPercent(`PROVIDER_FEE_PERCENT_${operator.toUpperCase()}`) ?? envPercent('PROVIDER_FEE_PERCENT');
    if (env !== null) return { percent: env, source: 'aggregator' };
  }
  return { percent: settingsPercent(), source: 'settings' };
}

/** Taux (en %) appliqué à un opérateur. */
const feePercentFor = (operator) => feeRateFor(operator).percent;

/**
 * Taux de chaque opérateur + provenance globale :
 * 'aggregator' si TOUS les opérateurs ont leur commission en variable d'environnement,
 * sinon 'settings' (le réglage admin s'applique alors aux opérateurs non configurés).
 */
function feeInfo() {
  const byOperator = {};
  let allAggregator = true;
  for (const op of OPERATORS) {
    const r = feeRateFor(op);
    byOperator[op] = r.percent;
    if (r.source !== 'aggregator') allAggregator = false;
  }
  return { by_operator: byOperator, source: allAggregator ? 'aggregator' : 'settings' };
}

module.exports = {
  OPERATORS,
  basisPoints,
  grossUp,
  customerFee,
  providerFeeOn,
  envPercent,
  feeRateFor,
  feePercentFor,
  feeInfo,
};
