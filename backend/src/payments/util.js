/** Petits utilitaires partagés par le module paiements. */

function httpError(status, message) {
  const err = new Error(message);
  err.status = status;
  return err;
}

// Transforme les erreurs levées (sync ou async) en réponses JSON.
function h(fn) {
  return async (req, res) => {
    try {
      await fn(req, res);
    } catch (err) {
      if (!err.status) require('../logger').log.error('erreur serveur', { path: req.path, error: err.message, stack: err.stack });
      res.status(err.status || 500).json({ error: err.status ? err.message : 'Erreur serveur' });
    }
  };
}

/** 21150 → « 21 150 F » (espaces normales, lisible partout). */
function fcfa(n) {
  return `${String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} F`;
}

const OPERATOR_LABELS = { flooz: 'Flooz', mixx: 'Mixx by Yas' };
const operatorLabel = (op) => OPERATOR_LABELS[op] || op;

/** « 96123412 » → « 96 •• •• 12 » ; jamais le numéro en clair. */
function maskPhone(num) {
  const digits = String(num || '').replace(/\D/g, '');
  if (!digits) return null;
  const last8 = digits.slice(-8);
  if (last8.length < 4) return '•• ••';
  return `${last8.slice(0, 2)} •• •• ${last8.slice(-2)}`;
}

/** Numéro mobile money togolais : 8 chiffres (indicatif +228 accepté et retiré). */
function normalizeMomoPhone(phone) {
  let d = String(phone || '').replace(/\D/g, '');
  if (d.startsWith('00228')) d = d.slice(5);
  else if (d.startsWith('228') && d.length === 11) d = d.slice(3);
  return /^\d{8}$/.test(d) ? d : null;
}

/** Date SQLite « YYYY-MM-DD HH:MM:SS » (UTC) → millisecondes. */
function sqlTime(v) {
  if (!v) return NaN;
  return Date.parse(`${String(v).replace(' ', 'T')}Z`);
}

/** Cellule CSV (séparateur « ; »), protégée contre l'injection de formules dans Excel. */
function csvCell(v) {
  if (v === null || v === undefined) return '';
  let s = String(v);
  if (typeof v !== 'number' && /^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[;"\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function parseJson(s, fallback = {}) {
  try {
    return s ? JSON.parse(s) : fallback;
  } catch {
    return fallback;
  }
}

module.exports = { httpError, h, fcfa, operatorLabel, maskPhone, normalizeMomoPhone, sqlTime, csvCell, parseJson };
