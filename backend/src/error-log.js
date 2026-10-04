/**
 * Journal des erreurs persistant (table error_logs) : plantages de l'app (POST /api/client-errors)
 * et erreurs du serveur (log.error, voir logger.js). Consultable par le gérant (GET /api/admin/errors).
 *
 * Textes tronqués (message 500, pile 4 000, contexte 300 caractères) ; on garde au plus 2 000 lignes
 * et 30 jours. Ce module ne journalise jamais lui-même ses échecs (pas de boucle avec logger.js).
 */
const express = require('express');
const { rateLimit, ipKeyGenerator } = require('express-rate-limit');
const { db } = require('./db');

const MAX_ROWS = 2000;
const MAX_DAYS = 30;
const LIMITS = { message: 500, stack: 4000, context: 300, app_version: 40, platform: 40 };
// Plus de 20 plantages de l'app en 10 min → alerte « app_crashes ».
const CRASH_ALERT_THRESHOLD = 20;

const cut = (v, max) => (v === undefined || v === null || v === '' ? null : String(v).slice(0, max));

/** Enregistre une erreur ; renvoie l'id de la ligne. Lève si la base refuse (l'appelant décide). */
function recordError({ source, message, stack, context, app_version: appVersion, platform, user_id: userId }) {
  const info = db
    .prepare(
      `INSERT INTO error_logs (source, message, stack, context, app_version, platform, user_id)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(
      source === 'server' ? 'server' : 'app',
      cut(message, LIMITS.message) || 'Erreur sans message',
      cut(stack, LIMITS.stack),
      cut(context, LIMITS.context),
      cut(appVersion, LIMITS.app_version),
      cut(platform, LIMITS.platform),
      Number.isInteger(userId) ? userId : null,
    );
  prune();
  return Number(info.lastInsertRowid);
}

/** Conserve les 2 000 dernières lignes de moins de 30 jours. */
function prune() {
  db.prepare(`DELETE FROM error_logs WHERE created_at < datetime('now', ?)`).run(`-${MAX_DAYS} days`);
  db.prepare(`DELETE FROM error_logs WHERE id <= (SELECT id FROM error_logs ORDER BY id DESC LIMIT 1 OFFSET ?)`).run(MAX_ROWS);
}

/** Erreur serveur issue de log.error(message, data). */
function recordServerError(message, data = {}) {
  const detail = data && typeof data === 'object' ? data : {};
  const text = detail.error ? `${message} : ${detail.error}` : String(message);
  // Contexte : chemin d'API s'il existe, sinon les autres champs (sans la pile ni l'erreur).
  const { stack, error, path, ...rest } = detail;
  let context = path ? String(path) : null;
  if (!context && Object.keys(rest).length) {
    try {
      context = JSON.stringify(rest);
    } catch {
      context = null;
    }
  }
  return recordError({ source: 'server', message: text, stack: typeof stack === 'string' ? stack : null, context });
}

function presentError(r) {
  return {
    id: r.id,
    created_at: r.created_at,
    source: r.source,
    message: r.message,
    stack: r.stack,
    context: r.context,
    app_version: r.app_version,
    platform: r.platform,
    user_id: r.user_id,
    user_name: r.user_name ?? null,
  };
}

/** Routes : POST /api/client-errors (auth facultative) et GET /api/admin/errors (gérant). */
function createErrorRouter() {
  // Chargés ici (et non en tête) : logger.js requiert ce module paresseusement, sans tirer auth.js.
  const { optionalAuth, requireManager } = require('./auth');
  const { raiseAlert } = require('./monitor');
  const router = express.Router();

  const clientErrorLimiter = rateLimit({
    windowMs: 10 * 60 * 1000,
    limit: 30,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    keyGenerator: (req) => ipKeyGenerator(req.ip),
    message: { error: 'Trop de rapports d\'erreur. Patientez quelques minutes.' },
  });

  const text = (v) => v === undefined || v === null || typeof v === 'string';

  router.post('/api/client-errors', clientErrorLimiter, optionalAuth, (req, res) => {
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    if (typeof b.message !== 'string' || !b.message.trim()) return res.status(400).json({ error: 'Message requis' });
    if (![b.stack, b.context, b.app_version, b.platform].every(text)) return res.status(400).json({ error: 'Rapport invalide' });
    try {
      recordError({
        source: 'app',
        message: b.message.trim(),
        stack: b.stack,
        context: b.context,
        app_version: b.app_version,
        platform: b.platform,
        user_id: req.user?.id ?? null,
      });
      const n = db
        .prepare(`SELECT COUNT(*) AS n FROM error_logs WHERE source = 'app' AND created_at >= datetime('now', '-10 minutes')`)
        .get().n;
      if (n > CRASH_ALERT_THRESHOLD) {
        raiseAlert('app_crashes', 'warning', `${n} erreurs de l'application en 10 min`, { count: n }, 30);
      }
    } catch (err) {
      return res.status(500).json({ error: 'Erreur serveur' });
    }
    res.status(204).end();
  });

  // ?source=app|server ; ?limit= (défaut 100, max 500), du plus récent au plus ancien.
  router.get('/api/admin/errors', requireManager, (req, res) => {
    const source = typeof req.query.source === 'string' && req.query.source ? req.query.source : null;
    if (source && !['app', 'server'].includes(source)) return res.status(400).json({ error: 'Source invalide (app ou server)' });
    const limit = Math.min(Math.max(Number.parseInt(req.query.limit, 10) || 100, 1), 500);
    const rows = db
      .prepare(
        `SELECT e.*, u.name AS user_name FROM error_logs e LEFT JOIN users u ON u.id = e.user_id
         ${source ? 'WHERE e.source = ?' : ''} ORDER BY e.id DESC LIMIT ?`,
      )
      .all(...(source ? [source, limit] : [limit]));
    res.json(rows.map(presentError));
  });

  return router;
}

module.exports = { recordError, recordServerError, prune, createErrorRouter, MAX_ROWS };
