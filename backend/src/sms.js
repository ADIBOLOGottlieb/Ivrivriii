// Envoi de SMS (codes de vérification, mot de passe oublié) via un prestataire configurable.
//   SMS_PROVIDER = 'none' (défaut : aucun envoi) | 'http' (passerelle générique) | 'log' (journal, dev)
//   SMS_HTTP_URL     : URL de la passerelle, avec {phone} et {text} (encodés pour l'URL)
//   SMS_HTTP_METHOD  : GET | POST (défaut POST si SMS_HTTP_BODY est défini, sinon GET)
//   SMS_HTTP_HEADERS : en-têtes JSON, ex. {"Authorization":"Bearer xxx","Content-Type":"application/json"}
//   SMS_HTTP_BODY    : corps facultatif avec {phone} et {text} (échappés JSON si le corps commence par '{',
//                      sinon encodés comme un formulaire)
const { log } = require('./logger');

const provider = () => String(process.env.SMS_PROVIDER || 'none').trim().toLowerCase();

/** Vrai si un prestataire réel est configuré (les codes partent vraiment par SMS). */
function otpRequired() {
  return provider() === 'http' && !!String(process.env.SMS_HTTP_URL || '').trim();
}

/** Canal des codes : 'sms' (prestataire réel) ou 'admin' (le restaurant communique le code). */
const smsChannel = () => (otpRequired() ? 'sms' : 'admin');

function parseHeaders() {
  const raw = process.env.SMS_HTTP_HEADERS;
  if (!raw) return {};
  try {
    const h = JSON.parse(raw);
    return h && typeof h === 'object' ? h : {};
  } catch {
    log.error('SMS_HTTP_HEADERS invalide (JSON attendu)');
    return {};
  }
}

const fill = (template, phone, text, enc) =>
  template.replace(/\{phone\}/g, enc(phone)).replace(/\{text\}/g, enc(text));

/**
 * Envoie un SMS. Ne lève jamais : renvoie { ok, provider, error? }.
 * Le texte n'est jamais journalisé en mode 'http' (il contient un code).
 */
async function sendSms(phone, text) {
  const p = provider();
  try {
    if (p === 'log') {
      log.info('SMS (mode journal)', { phone, text });
      return { ok: true, provider: 'log' };
    }
    if (p !== 'http') return { ok: false, provider: 'none', error: 'Aucun prestataire SMS configuré' };
    const url = String(process.env.SMS_HTTP_URL || '').trim();
    if (!url) return { ok: false, provider: 'http', error: 'SMS_HTTP_URL manquant' };
    const bodyTpl = process.env.SMS_HTTP_BODY;
    const method = String(process.env.SMS_HTTP_METHOD || (bodyTpl ? 'POST' : 'GET')).toUpperCase();
    const init = { method, headers: parseHeaders(), signal: AbortSignal.timeout(10_000) };
    if (bodyTpl && method !== 'GET') {
      const json = bodyTpl.trim().startsWith('{');
      init.body = fill(bodyTpl, phone, text, json ? (s) => JSON.stringify(s).slice(1, -1) : encodeURIComponent);
      const hasType = Object.keys(init.headers).some((k) => k.toLowerCase() === 'content-type');
      if (!hasType) init.headers['Content-Type'] = json ? 'application/json' : 'application/x-www-form-urlencoded';
    }
    const res = await fetch(fill(url, phone, text, encodeURIComponent), init);
    if (!res.ok) {
      log.error('envoi SMS refusé', { phone, status: res.status });
      return { ok: false, provider: 'http', error: `HTTP ${res.status}` };
    }
    log.info('SMS envoyé', { phone });
    return { ok: true, provider: 'http' };
  } catch (err) {
    log.error('envoi SMS impossible', { phone, error: err.message });
    return { ok: false, provider: p, error: err.message };
  }
}

module.exports = { sendSms, otpRequired, smsChannel };
