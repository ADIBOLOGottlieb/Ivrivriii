const jwt = require('jsonwebtoken');
const { db } = require('./db');

const DEFAULT_SECRET = 'change-moi-en-production';
const JWT_SECRET = process.env.JWT_SECRET || DEFAULT_SECRET;

if (JWT_SECRET === DEFAULT_SECRET) {
  if (process.env.NODE_ENV === 'production') {
    throw new Error('JWT_SECRET doit être défini en production');
  }
  console.warn('⚠️  JWT_SECRET non défini : clé de développement utilisée (ne pas utiliser en production).');
}

function signToken(user) {
  return jwt.sign({ id: user.id, role: user.role }, JWT_SECRET, { expiresIn: '30d' });
}

function requireAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'Non authentifié' });
  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET, { algorithms: ['HS256'] });
  } catch {
    return res.status(401).json({ error: 'Session expirée, reconnectez-vous' });
  }
  // Un jeton reste valable 30 jours : on refuse celui d'un compte supprimé ou anonymisé.
  // (SELECT * : la colonne deleted_at n'existe que si account.js a fait sa migration.)
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(payload.id);
  if (!user || user.deleted_at) return res.status(401).json({ error: 'Session expirée, reconnectez-vous' });
  // Le rôle vient de la base : un admin rétrogradé perd l'accès sans attendre l'expiration du jeton.
  req.user = { ...payload, role: user.role };
  next();
}

function requireAdmin(req, res, next) {
  requireAuth(req, res, () => {
    if (req.user.role !== 'admin') return res.status(403).json({ error: 'Accès réservé à l\'administrateur' });
    next();
  });
}

module.exports = { signToken, requireAuth, requireAdmin };
