const fs = require('fs');
const path = require('path');

// Journaux au format JSON (une ligne par évènement), un fichier par jour dans backend/logs/.
const LOG_DIR = process.env.LOG_DIR || path.join(__dirname, '..', 'logs');
fs.mkdirSync(LOG_DIR, { recursive: true });

// Champs jamais écrits dans les journaux.
const SECRET_KEYS = /pass|token|secret|authorization|signature/i;

function scrub(value, depth = 0) {
  if (!value || typeof value !== 'object' || depth > 4) return value;
  if (Array.isArray(value)) return value.map((v) => scrub(v, depth + 1));
  const out = {};
  for (const [k, v] of Object.entries(value)) out[k] = SECRET_KEYS.test(k) ? '[masqué]' : scrub(v, depth + 1);
  return out;
}

function write(level, message, data) {
  const entry = { time: new Date().toISOString(), level, message, ...scrub(data || {}) };
  const line = JSON.stringify(entry);
  const file = path.join(LOG_DIR, `app-${entry.time.slice(0, 10)}.log`);
  fs.appendFile(file, line + '\n', () => {});
  if (level === 'error') console.error(line);
  else if (level === 'warn') console.warn(line);
  else if (process.env.LOG_CONSOLE !== '0') console.log(line);
}

const log = {
  info: (msg, data) => write('info', msg, data),
  warn: (msg, data) => write('warn', msg, data),
  error: (msg, data) => write('error', msg, data),
};

// Compteurs minute par minute sur la dernière heure (requêtes, erreurs 5xx, 4xx).
const buckets = new Map();
function bucketKey(d = new Date()) {
  return Math.floor(d.getTime() / 60000);
}
function countRequest(status) {
  const key = bucketKey();
  const b = buckets.get(key) || { requests: 0, errors: 0, clientErrors: 0 };
  b.requests++;
  if (status >= 500) b.errors++;
  else if (status >= 400) b.clientErrors++;
  buckets.set(key, b);
  for (const k of buckets.keys()) if (k < key - 60) buckets.delete(k);
}
function lastHourMetrics() {
  const now = bucketKey();
  const sum = { requests: 0, errors: 0, clientErrors: 0 };
  const perMinute = [];
  for (let k = now - 59; k <= now; k++) {
    const b = buckets.get(k) || { requests: 0, errors: 0, clientErrors: 0 };
    sum.requests += b.requests;
    sum.errors += b.errors;
    sum.clientErrors += b.clientErrors;
    perMinute.push(b.requests);
  }
  return { ...sum, perMinute };
}

function requestLogger(req, res, next) {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    countRequest(res.statusCode);
    // Les images et la santé du serveur ne sont pas journalisées pour limiter le bruit.
    if (req.path.startsWith('/uploads') || req.path === '/api/health') return;
    const level = res.statusCode >= 500 ? 'error' : res.statusCode >= 400 ? 'warn' : 'info';
    write(level, 'http', {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      ms: Math.round(ms),
      ip: req.ip,
      user: req.user?.id,
    });
  });
  next();
}

module.exports = { log, requestLogger, lastHourMetrics, LOG_DIR };
