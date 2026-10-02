const path = require('path');
const fs = require('fs');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const { rateLimit, ipKeyGenerator } = require('express-rate-limit');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const { db, transaction, getSettings } = require('./db');
const { signToken, requireAuth, requireAdmin } = require('./auth');
const { seedIfEmpty } = require('./seed');
const { log, requestLogger, lastHourMetrics } = require('./logger');
const { audit, raiseAlert, checkOrder, startMonitoring, orderRate } = require('./monitor');
const payments = require('./payments');

seedIfEmpty();

const app = express();
// TRUST_PROXY=1 (nombre de proxys devant le serveur, ex : Render) ou une liste d'IP / 'loopback'.
// Un nombre doit être passé en Number : en texte, Express le lirait comme une adresse IP.
const trustProxy = process.env.TRUST_PROXY ?? 'loopback';
app.set('trust proxy', /^\d+$/.test(trustProxy) ? Number(trustProxy) : trustProxy);
app.disable('x-powered-by');
// La CSP des pages de paiement est définie dans payments.js ; l'API ne sert que du JSON.
app.use(helmet({ contentSecurityPolicy: false, crossOriginResourcePolicy: { policy: 'cross-origin' } }));
app.use(cors());
app.use(requestLogger);

// Limite globale anti-abus : 300 requêtes / minute / IP.
app.use(
  rateLimit({
    windowMs: 60 * 1000,
    limit: 300,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: { error: 'Trop de requêtes, patientez un instant.' },
    handler: (req, res, _next, options) => {
      raiseAlert('rate_limit', 'warning', `Trafic anormal depuis l'IP ${req.ip}`, { key: req.ip }, 15);
      res.status(options.statusCode).json(options.message);
    },
  }),
);

// Le webhook de paiement lit le corps brut : il est monté avant express.json().
app.use(payments.router);
app.use(express.json({ limit: '100kb' }));

// Compte client (profil, mot de passe, avatar, adresses...) : backend/src/account.js.
let account = null;
try {
  account = require('./account');
  app.use(account.router);
} catch (e) {
  if (e.code !== 'MODULE_NOT_FOUND') throw e;
}

const UPLOAD_DIR = path.join(__dirname, '..', 'uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
app.use('/uploads', express.static(UPLOAD_DIR));
app.use('/public', express.static(path.join(__dirname, '..', 'public')));

const upload = multer({
  storage: multer.diskStorage({
    destination: UPLOAD_DIR,
    filename: (_req, file, cb) => {
      const ext = (path.extname(file.originalname).toLowerCase().match(/^\.(jpe?g|png|webp)$/) || ['.jpg'])[0];
      cb(null, `${Date.now()}-${Math.round(Math.random() * 1e6)}${ext}`);
    },
  }),
  limits: { fileSize: 5 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => cb(null, /^image\/(jpeg|png|webp)$/.test(file.mimetype)),
});

// Quantité maximale d'un même article dans une commande (une seule constante, exposée dans /api/settings).
const MAX_QUANTITY_PER_ITEM = 999;

const ORDER_STATUSES = ['pending', 'confirmed', 'preparing', 'ready', 'delivering', 'delivered', 'cancelled'];
const PAYMENT_METHODS = ['cash', ...payments.MOBILE_METHODS];

// Transforme les erreurs levées (sync ou async) en réponses JSON.
const h = (fn) => async (req, res) => {
  try {
    await fn(req, res);
  } catch (err) {
    if (!err.status) log.error('erreur serveur', { path: req.path, error: err.message, stack: err.stack });
    res.status(err.status || 500).json({ error: err.status ? err.message : 'Erreur serveur' });
  }
};

function httpError(status, message) {
  const err = new Error(message);
  err.status = status;
  return err;
}

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 10,
  skipSuccessfulRequests: true,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: 'Trop de tentatives de connexion. Réessayez dans 15 minutes.' },
});
const registerLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: 5,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: { error: 'Trop de comptes créés depuis ce réseau. Réessayez plus tard.' },
});
const orderLimiter = rateLimit({
  windowMs: 10 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  keyGenerator: (req) => (req.user ? `user-${req.user.id}` : ipKeyGenerator(req.ip)),
  message: { error: 'Trop de commandes en peu de temps. Patientez quelques minutes.' },
});

function basicPublicUser(u) {
  return { id: u.id, name: u.name, phone: u.phone, email: u.email, role: u.role, address: u.address, created_at: u.created_at };
}
const publicUser = account?.publicUser ?? basicPublicUser;

function mapProduct(p) {
  return { ...p, available: !!p.available, popular: !!p.popular };
}

/** Retire le jeton de paiement et ajoute l'URL de paiement pour le propriétaire de la commande. */
function presentOrder(o, viewer) {
  if (!o) return o;
  const { payment_token, ...rest } = o;
  // pay_url uniquement pour le parcours navigateur (KADEV) ; sinon paiement par push USSD depuis l'app.
  const canPay =
    viewer && viewer.id === o.user_id && payment_token && payments.usesBrowserCheckout(o.payment_method) &&
    ['pending', 'failed', 'expired'].includes(o.payment_status) && o.status !== 'cancelled';
  return { ...rest, pay_url: canPay ? `/pay/${o.id}?t=${payment_token}` : null };
}

function loadOrder(id) {
  const order = db
    .prepare(`SELECT o.*, u.name AS customer_name FROM orders o JOIN users u ON u.id = o.user_id WHERE o.id = ?`)
    .get(id);
  if (!order) return null;
  order.items = db.prepare('SELECT * FROM order_items WHERE order_id = ?').all(id);
  return order;
}

function loadOrders(where, params) {
  const orders = db
    .prepare(
      `SELECT o.*, u.name AS customer_name FROM orders o JOIN users u ON u.id = o.user_id
       ${where} ORDER BY o.created_at DESC, o.id DESC LIMIT 200`,
    )
    .all(...params);
  if (orders.length === 0) return orders;
  const ids = orders.map((o) => o.id);
  const items = db
    .prepare(`SELECT * FROM order_items WHERE order_id IN (${ids.map(() => '?').join(',')})`)
    .all(...ids);
  for (const o of orders) o.items = items.filter((i) => i.order_id === o.id);
  return orders;
}

// ---------- Santé ----------

app.get('/api/health', (_req, res) => res.json({ status: 'ok', uptime: Math.round(process.uptime()) }));

// ---------- Auth ----------

app.post('/api/auth/register', registerLimiter, h((req, res) => {
  const { name, phone, password, email, address } = req.body || {};
  if (!name?.trim() || !phone?.trim() || !password) throw httpError(400, 'Nom, téléphone et mot de passe requis');
  if (password.length < 6) throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
  if (!/^\+?[\d\s]{8,16}$/.test(phone.trim())) throw httpError(400, 'Numéro de téléphone invalide');
  if (db.prepare('SELECT id FROM users WHERE phone = ?').get(phone.trim())) {
    throw httpError(409, 'Ce numéro est déjà utilisé');
  }
  const info = db
    .prepare('INSERT INTO users (name, phone, email, password_hash, address) VALUES (?, ?, ?, ?, ?)')
    .run(name.trim().slice(0, 80), phone.trim(), email?.trim() || null, bcrypt.hashSync(password, 10), address?.trim() || null);
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid);
  audit('register', { userId: user.id, ip: req.ip });
  res.status(201).json({ token: signToken(user), user: publicUser(user) });
}));

app.post('/api/auth/login', loginLimiter, h((req, res) => {
  const { phone, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE phone = ?').get(String(phone || '').trim());
  if (!user || !bcrypt.compareSync(String(password || ''), user.password_hash)) {
    audit('login_failed', { userId: user?.id ?? null, details: { phone: String(phone || '').slice(0, 20) }, ip: req.ip });
    throw httpError(401, 'Téléphone ou mot de passe incorrect');
  }
  audit(user.role === 'admin' ? 'admin_login' : 'login', { userId: user.id, ip: req.ip });
  res.json({ token: signToken(user), user: publicUser(user) });
}));

// ---------- Catalogue public ----------

/**
 * Frais de paiement exposés à l'app : taux par opérateur (commission de l'agrégateur ou réglage
 * admin) + provenance. payment_fee_percent = taux Flooz (compatibilité anciennes versions).
 */
function feeSettings() {
  const fee = payments.feeInfo();
  return {
    payment_fee_percent: fee.by_operator.flooz,
    payment_fee_percent_by_operator: fee.by_operator,
    payment_fee_source: fee.source,
    // Réglage admin (repli quand l'agrégateur n'a pas de commission configurée).
    payment_fee_percent_settings: getSettings().payment_fee_percent,
  };
}

app.get('/api/settings', h((_req, res) => {
  const s = getSettings();
  res.json({
    delivery_fee: s.delivery_fee,
    min_order: s.min_order,
    is_open: s.is_open,
    restaurant_phone: s.restaurant_phone,
    restaurant_address: s.restaurant_address,
    ...feeSettings(),
    payment_mode: payments.paymentInfo().mode,
    payment_provider: payments.paymentInfo().provider,
    max_quantity_per_item: MAX_QUANTITY_PER_ITEM,
    momo_unpaid_cancel_minutes: s.momo_unpaid_cancel_minutes,
    restaurant_lat: s.restaurant_lat,
    restaurant_lng: s.restaurant_lng,
  });
}));

app.get('/api/categories', h((_req, res) => {
  res.json(db.prepare('SELECT * FROM categories ORDER BY position, id').all());
}));

app.get('/api/products', h((req, res) => {
  const all = req.query.all === '1';
  const rows = db
    .prepare(`SELECT * FROM products ${all ? '' : 'WHERE available = 1'} ORDER BY popular DESC, name`)
    .all();
  res.json(rows.map(mapProduct));
}));

// ---------- Commandes client ----------

function parseLocation(location) {
  if (location == null) return null;
  const lat = Number(location.lat);
  const lng = Number(location.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
    throw httpError(400, 'Position de livraison invalide');
  }
  const accuracy = Number(location.accuracy);
  return { lat, lng, accuracy: Number.isFinite(accuracy) ? accuracy : null };
}

app.post('/api/orders', requireAuth, orderLimiter, h((req, res) => {
  const settings = getSettings();
  if (!settings.is_open) throw httpError(400, 'Le restaurant est actuellement fermé');

  const { items, mode, address, phone, note, payment_method, location } = req.body || {};
  if (!Array.isArray(items) || items.length === 0 || items.length > 50) throw httpError(400, 'Votre panier est vide');
  if (!['delivery', 'pickup'].includes(mode)) throw httpError(400, 'Mode de retrait invalide');
  if (mode === 'delivery' && !address?.trim()) throw httpError(400, 'Adresse de livraison requise');
  if (!phone?.trim()) throw httpError(400, 'Numéro de téléphone requis');
  if (!PAYMENT_METHODS.includes(payment_method)) throw httpError(400, 'Moyen de paiement invalide');
  const loc = mode === 'delivery' ? parseLocation(location) : null;

  // Les prix sont toujours recalculés côté serveur à partir du catalogue.
  const getProduct = db.prepare('SELECT * FROM products WHERE id = ?');
  const perProduct = new Map();
  const lines = items.map((it) => {
    const qty = Number(it?.quantity);
    const p = getProduct.get(Number(it?.product_id));
    if (!p || !p.available) throw httpError(400, `Un article n'est plus disponible`);
    if (!Number.isInteger(qty) || qty < 1) throw httpError(400, 'Quantité invalide');
    const totalQty = (perProduct.get(p.id) || 0) + qty;
    if (totalQty > MAX_QUANTITY_PER_ITEM) {
      throw httpError(400, `Quantité maximale : ${MAX_QUANTITY_PER_ITEM} par article (${p.name})`);
    }
    perProduct.set(p.id, totalQty);
    return { product: p, qty };
  });

  const subtotal = lines.reduce((s, l) => s + l.product.price * l.qty, 0);
  if (subtotal < settings.min_order) throw httpError(400, `Commande minimum : ${settings.min_order} FCFA`);
  const deliveryFee = mode === 'delivery' ? settings.delivery_fee : 0;
  // Commission de l'agrégateur reportée sur le client : le restaurant reçoit sous-total + livraison.
  // Le taux est figé sur la commande (net calculé au même taux au moment du paiement).
  const { fee: paymentFee, percent: paymentFeePercent } = payments.paymentFeeDetails(subtotal + deliveryFee, payment_method);
  const mobile = payments.isMobileMoney(payment_method);

  const orderId = transaction(() => {
    const info = db
      .prepare(
        `INSERT INTO orders (user_id, mode, address, phone, note, payment_method, subtotal, delivery_fee, total,
           payment_fee, payment_fee_percent, payment_status, payment_token, delivery_lat, delivery_lng, delivery_accuracy)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        req.user.id, mode, mode === 'delivery' ? address.trim().slice(0, 300) : null, phone.trim().slice(0, 20),
        note?.trim()?.slice(0, 300) || null, payment_method, subtotal, deliveryFee, subtotal + deliveryFee + paymentFee,
        paymentFee, paymentFeePercent, mobile ? 'pending' : 'unpaid', mobile ? payments.newToken() : null,
        loc?.lat ?? null, loc?.lng ?? null, loc?.accuracy ?? null,
      );
    const insertItem = db.prepare(
      'INSERT INTO order_items (order_id, product_id, name, unit_price, quantity) VALUES (?, ?, ?, ?, ?)',
    );
    for (const l of lines) insertItem.run(info.lastInsertRowid, l.product.id, l.product.name, l.product.price, l.qty);
    return info.lastInsertRowid;
  });

  const order = loadOrder(orderId);
  audit('order_created', { userId: req.user.id, details: { orderId, total: order.total, payment_method }, ip: req.ip });
  checkOrder(order, { name: order.customer_name });
  res.status(201).json(presentOrder(order, req.user));
}));

app.get('/api/orders', requireAuth, h((req, res) => {
  res.json(loadOrders('WHERE o.user_id = ?', [req.user.id]).map((o) => presentOrder(o, req.user)));
}));

app.get('/api/orders/:id', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  if (!order || (order.user_id !== req.user.id && req.user.role !== 'admin')) throw httpError(404, 'Commande introuvable');
  res.json(presentOrder(order, req.user));
}));

// Nouveau lien de paiement (après un échec ou un abandon).
app.post('/api/orders/:id/pay', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
  if (!payments.isMobileMoney(order.payment_method)) throw httpError(400, 'Cette commande se paie en espèces');
  if (order.payment_status === 'paid') throw httpError(400, 'Cette commande est déjà payée');
  if (order.status === 'cancelled') throw httpError(400, 'Cette commande est annulée');
  db.prepare(`UPDATE orders SET payment_token = ?, payment_status = 'pending', updated_at = datetime('now') WHERE id = ?`)
    .run(payments.newToken(), order.id);
  res.json(presentOrder(loadOrder(order.id), req.user));
}));

app.post('/api/orders/:id/cancel', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
  if (order.status !== 'pending') throw httpError(400, 'Cette commande ne peut plus être annulée');
  if (order.payment_status === 'paid') {
    throw httpError(400, 'Commande déjà payée : appelez le restaurant pour l\'annuler et être remboursé');
  }
  db.prepare(`UPDATE orders SET status = 'cancelled', updated_at = datetime('now') WHERE id = ?`).run(order.id);
  payments.cancelPendingAttempts(order.id, 'Commande annulée par le client');
  audit('order_cancelled', { userId: req.user.id, details: { orderId: order.id, by: 'client' }, ip: req.ip });
  res.json(presentOrder(loadOrder(order.id), req.user));
}));

// ---------- Admin ----------

app.get('/api/admin/stats', requireAdmin, h((_req, res) => {
  const today = db
    .prepare(
      `SELECT COUNT(*) AS orders, COALESCE(SUM(CASE WHEN status != 'cancelled' THEN total END), 0) AS revenue
       FROM orders WHERE date(created_at) = date('now')`,
    )
    .get();
  const total = db
    .prepare(`SELECT COUNT(*) AS orders, COALESCE(SUM(total), 0) AS revenue FROM orders WHERE status = 'delivered'`)
    .get();
  const active = db
    .prepare(`SELECT COUNT(*) AS n FROM orders WHERE status NOT IN ('delivered', 'cancelled')`)
    .get().n;
  const pending = db.prepare(`SELECT COUNT(*) AS n FROM orders WHERE status = 'pending'`).get().n;
  const customers = db.prepare(`SELECT COUNT(*) AS n FROM users WHERE role = 'customer'`).get().n;
  const alerts = db.prepare(`SELECT COUNT(*) AS n FROM alerts WHERE resolved = 0`).get().n;
  const topProducts = db
    .prepare(
      `SELECT oi.name, SUM(oi.quantity) AS quantity, SUM(oi.quantity * oi.unit_price) AS revenue
       FROM order_items oi JOIN orders o ON o.id = oi.order_id
       WHERE o.status != 'cancelled' GROUP BY oi.name ORDER BY quantity DESC LIMIT 5`,
    )
    .all();
  const last7Days = db
    .prepare(
      `SELECT date(created_at) AS day, COUNT(*) AS orders,
              COALESCE(SUM(CASE WHEN status != 'cancelled' THEN total END), 0) AS revenue
       FROM orders WHERE date(created_at) >= date('now', '-6 days')
       GROUP BY day ORDER BY day`,
    )
    .all();
  res.json({ today, total, active, pending, customers, alerts, topProducts, last7Days });
}));

app.get('/api/admin/orders', requireAdmin, h((req, res) => {
  const { status } = req.query;
  let rows;
  if (status === 'active') rows = loadOrders(`WHERE o.status NOT IN ('delivered', 'cancelled')`, []);
  else if (status && ORDER_STATUSES.includes(status)) rows = loadOrders('WHERE o.status = ?', [status]);
  else rows = loadOrders('', []);
  res.json(rows.map((o) => presentOrder(o, req.user)));
}));

app.patch('/api/admin/orders/:id/status', requireAdmin, h((req, res) => {
  const { status } = req.body || {};
  if (!ORDER_STATUSES.includes(status)) throw httpError(400, 'Statut invalide');
  const order = loadOrder(Number(req.params.id));
  if (!order) throw httpError(404, 'Commande introuvable');
  // Une commande mobile money n'est préparée qu'une fois le paiement reçu.
  if (status !== 'cancelled' && payments.isMobileMoney(order.payment_method) && order.payment_status !== 'paid') {
    throw httpError(400, 'Paiement pas encore reçu : impossible de lancer la commande');
  }
  db.prepare(`UPDATE orders SET status = ?, updated_at = datetime('now') WHERE id = ?`).run(status, order.id);
  if (status === 'cancelled') payments.cancelPendingAttempts(order.id, 'Commande annulée par le restaurant');
  audit('order_status', { userId: req.user.id, details: { orderId: order.id, from: order.status, to: status }, ip: req.ip });
  if (status === 'cancelled' && order.payment_status === 'paid') {
    raiseAlert('refund_needed', 'warning', `Commande n°${order.id} annulée alors qu'elle est payée (${order.total} FCFA) : remboursement à prévoir`,
      { key: `order-${order.id}`, orderId: order.id }, 0);
  }
  res.json(presentOrder(loadOrder(order.id), req.user));
}));

app.post('/api/admin/categories', requireAdmin, h((req, res) => {
  const { name, icon, position } = req.body || {};
  if (!name?.trim()) throw httpError(400, 'Nom requis');
  const info = db
    .prepare('INSERT INTO categories (name, icon, position) VALUES (?, ?, ?)')
    .run(name.trim(), icon || null, Number(position) || 0);
  audit('category_created', { userId: req.user.id, details: { name }, ip: req.ip });
  res.status(201).json(db.prepare('SELECT * FROM categories WHERE id = ?').get(info.lastInsertRowid));
}));

app.put('/api/admin/categories/:id', requireAdmin, h((req, res) => {
  const { name, icon, position } = req.body || {};
  if (!name?.trim()) throw httpError(400, 'Nom requis');
  const info = db
    .prepare('UPDATE categories SET name = ?, icon = ?, position = ? WHERE id = ?')
    .run(name.trim(), icon || null, Number(position) || 0, Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Catégorie introuvable');
  res.json(db.prepare('SELECT * FROM categories WHERE id = ?').get(Number(req.params.id)));
}));

app.delete('/api/admin/categories/:id', requireAdmin, h((req, res) => {
  db.prepare('DELETE FROM categories WHERE id = ?').run(Number(req.params.id));
  audit('category_deleted', { userId: req.user.id, details: { id: Number(req.params.id) }, ip: req.ip });
  res.status(204).end();
}));

function productFields(body) {
  const { name, description, price, image_url, category_id, available, popular } = body || {};
  if (!name?.trim()) throw httpError(400, 'Nom requis');
  const p = Math.round(Number(price));
  if (!(p > 0 && p < 10_000_000)) throw httpError(400, 'Prix invalide');
  return [
    category_id ? Number(category_id) : null, name.trim(), description?.trim() || null, p,
    image_url?.trim() || null, available === false ? 0 : 1, popular ? 1 : 0,
  ];
}

app.post('/api/admin/products', requireAdmin, h((req, res) => {
  const info = db
    .prepare(
      `INSERT INTO products (category_id, name, description, price, image_url, available, popular)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .run(...productFields(req.body));
  audit('product_created', { userId: req.user.id, details: { id: info.lastInsertRowid, name: req.body.name }, ip: req.ip });
  res.status(201).json(mapProduct(db.prepare('SELECT * FROM products WHERE id = ?').get(info.lastInsertRowid)));
}));

app.put('/api/admin/products/:id', requireAdmin, h((req, res) => {
  const before = db.prepare('SELECT price FROM products WHERE id = ?').get(Number(req.params.id));
  const info = db
    .prepare(
      `UPDATE products SET category_id = ?, name = ?, description = ?, price = ?, image_url = ?,
       available = ?, popular = ? WHERE id = ?`,
    )
    .run(...productFields(req.body), Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Produit introuvable');
  const after = db.prepare('SELECT * FROM products WHERE id = ?').get(Number(req.params.id));
  audit('product_updated', {
    userId: req.user.id,
    details: { id: after.id, name: after.name, ...(before.price !== after.price ? { price: [before.price, after.price] } : {}) },
    ip: req.ip,
  });
  res.json(mapProduct(after));
}));

app.patch('/api/admin/products/:id/availability', requireAdmin, h((req, res) => {
  const info = db
    .prepare('UPDATE products SET available = ? WHERE id = ?')
    .run(req.body?.available ? 1 : 0, Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Produit introuvable');
  res.json(mapProduct(db.prepare('SELECT * FROM products WHERE id = ?').get(Number(req.params.id))));
}));

app.delete('/api/admin/products/:id', requireAdmin, h((req, res) => {
  db.prepare('DELETE FROM products WHERE id = ?').run(Number(req.params.id));
  audit('product_deleted', { userId: req.user.id, details: { id: Number(req.params.id) }, ip: req.ip });
  res.status(204).end();
}));

app.post('/api/admin/upload', requireAdmin, upload.single('image'), h((req, res) => {
  if (!req.file) throw httpError(400, 'Image invalide (JPEG, PNG ou WebP, max 5 Mo)');
  res.status(201).json({ url: `/uploads/${req.file.filename}` });
}));

app.get('/api/admin/users', requireAdmin, h((_req, res) => {
  res.json(
    db
      .prepare(
        `SELECT u.id, u.name, u.phone, u.email, u.role, u.address, u.created_at,
                COUNT(o.id) AS orders_count, COALESCE(SUM(CASE WHEN o.status = 'delivered' THEN o.total END), 0) AS total_spent
         FROM users u LEFT JOIN orders o ON o.user_id = u.id
         GROUP BY u.id ORDER BY u.created_at DESC`,
      )
      .all(),
  );
}));

app.put('/api/admin/settings', requireAdmin, h((req, res) => {
  const numeric = {
    delivery_fee: [0, 100000],
    min_order: [0, 1000000],
    payment_fee_percent: [0, 10],
    spike_min_orders: [2, 1000],
    spike_factor: [1, 50],
    high_amount_alert: [1000, 100000000],
    momo_unpaid_cancel_minutes: [5, 1440],
  };
  const text = ['restaurant_phone', 'restaurant_address'];
  const upsert = db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value');
  const changed = {};
  // Position du restaurant : les deux coordonnées ensemble (ou aucune), null pour effacer.
  const hasLat = req.body?.restaurant_lat !== undefined;
  const hasLng = req.body?.restaurant_lng !== undefined;
  let position;
  if (hasLat || hasLng) {
    if (hasLat !== hasLng) throw httpError(400, 'Position du restaurant : latitude et longitude doivent être envoyées ensemble');
    const rawLat = req.body.restaurant_lat;
    const rawLng = req.body.restaurant_lng;
    if (rawLat === null && rawLng === null) {
      position = null;
    } else {
      const toNum = (v) => (typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN);
      const lat = toNum(rawLat);
      const lng = toNum(rawLng);
      if (!Number.isFinite(lat) || lat < -90 || lat > 90) throw httpError(400, 'Latitude du restaurant invalide (entre -90 et 90)');
      if (!Number.isFinite(lng) || lng < -180 || lng > 180) throw httpError(400, 'Longitude du restaurant invalide (entre -180 et 180)');
      position = { lat, lng };
    }
  }
  transaction(() => {
    if (position !== undefined) {
      if (position === null) {
        db.prepare("DELETE FROM settings WHERE key IN ('restaurant_lat', 'restaurant_lng')").run();
      } else {
        upsert.run('restaurant_lat', String(position.lat));
        upsert.run('restaurant_lng', String(position.lng));
      }
      changed.restaurant_lat = position ? position.lat : null;
      changed.restaurant_lng = position ? position.lng : null;
    }
    for (const [key, [min, max]] of Object.entries(numeric)) {
      if (req.body?.[key] === undefined) continue;
      const v = Number(req.body[key]);
      if (!Number.isFinite(v) || v < min || v > max) throw httpError(400, `Valeur invalide pour ${key} (entre ${min} et ${max})`);
      if (key === 'momo_unpaid_cancel_minutes' && !Number.isInteger(v)) throw httpError(400, 'Délai en minutes entières');
      upsert.run(key, String(v));
      changed[key] = v;
    }
    for (const key of text) {
      if (req.body?.[key] === undefined) continue;
      upsert.run(key, String(req.body[key]).trim().slice(0, 200));
      changed[key] = req.body[key];
    }
    if (req.body?.is_open !== undefined) {
      upsert.run('is_open', req.body.is_open ? '1' : '0');
      changed.is_open = !!req.body.is_open;
    }
  });
  audit('settings_changed', { userId: req.user.id, details: changed, ip: req.ip });
  // payment_fee_percent est validé et enregistré, mais ignoré pour le calcul tant que la commission
  // de l'agrégateur est définie en variable d'environnement (payment_fee_source = 'aggregator').
  // Réponse au même format que GET /api/settings.
  res.json({
    ...getSettings(),
    ...feeSettings(),
    payment_mode: payments.paymentInfo().mode,
    payment_provider: payments.paymentInfo().provider,
    max_quantity_per_item: MAX_QUANTITY_PER_ITEM,
  });
}));

// ---------- Sécurité & monitoring ----------

app.get('/api/admin/monitoring', requireAdmin, h((_req, res) => {
  const count = (sql) => db.prepare(sql).get().n;
  const { last10, baselinePer10 } = orderRate();
  res.json({
    payment: payments.paymentInfo(),
    http: lastHourMetrics(),
    orders: {
      last10min: last10,
      baselinePer10min: Math.round(baselinePer10 * 10) / 10,
      lastHour: count(`SELECT COUNT(*) AS n FROM orders WHERE created_at >= datetime('now', '-1 hour')`),
    },
    payments: {
      paid24h: count(`SELECT COUNT(*) AS n FROM payments WHERE status = 'paid' AND updated_at >= datetime('now', '-1 day')`),
      failed24h: count(`SELECT COUNT(*) AS n FROM payments WHERE status = 'failed' AND updated_at >= datetime('now', '-1 day')`),
      pending: count(`SELECT COUNT(*) AS n FROM orders WHERE payment_status = 'pending' AND status != 'cancelled'`),
    },
    security: {
      loginFailures1h: count(`SELECT COUNT(*) AS n FROM audit_logs WHERE action = 'login_failed' AND created_at >= datetime('now', '-1 hour')`),
      adminLogins24h: count(`SELECT COUNT(*) AS n FROM audit_logs WHERE action = 'admin_login' AND created_at >= datetime('now', '-1 day')`),
    },
    alerts: db.prepare('SELECT * FROM alerts ORDER BY resolved, created_at DESC LIMIT 50').all(),
  });
}));

app.post('/api/admin/alerts/:id/resolve', requireAdmin, h((req, res) => {
  const info = db.prepare('UPDATE alerts SET resolved = 1 WHERE id = ?').run(Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Alerte introuvable');
  audit('alert_resolved', { userId: req.user.id, details: { id: Number(req.params.id) }, ip: req.ip });
  res.json({ ok: true });
}));

app.get('/api/admin/audit', requireAdmin, h((req, res) => {
  const limit = Math.min(Number(req.query.limit) || 100, 500);
  res.json(
    db
      .prepare(
        `SELECT a.*, u.name AS user_name FROM audit_logs a LEFT JOIN users u ON u.id = a.user_id
         ORDER BY a.id DESC LIMIT ?`,
      )
      .all(limit),
  );
}));

// Paiements mobile money : push USSD, file à vérifier, encaissements, reversements, remboursements.
app.use(payments.createApiRouter({ presentOrder, loadOrder }));

app.get('/', (_req, res) => res.json({ name: 'Ivrivrii Chicken API', status: 'ok' }));

// Erreurs non gérées (JSON invalide, fichier trop gros...).
app.use((err, req, res, _next) => {
  const status = err.status || err.statusCode || (err.code === 'LIMIT_FILE_SIZE' ? 413 : 500);
  if (status >= 500) log.error('erreur non gérée', { path: req.path, error: err.message });
  res.status(status).json({ error: status === 413 ? 'Fichier trop volumineux' : status < 500 ? 'Requête invalide' : 'Erreur serveur' });
});

startMonitoring();
payments.startPaymentTasks();

const PORT = Number(process.env.PORT) || 4000;
app.listen(PORT, '0.0.0.0', () => {
  log.info('démarrage', { port: PORT, payment: payments.paymentInfo(), fees: payments.feeInfo() });
  console.log(`🐔 API Ivrivrii Chicken sur http://localhost:${PORT}`);
});
