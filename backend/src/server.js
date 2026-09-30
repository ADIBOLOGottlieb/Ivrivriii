const path = require('path');
const fs = require('fs');
const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const { db, transaction, getSettings } = require('./db');
const { signToken, requireAuth, requireAdmin } = require('./auth');
const { seedIfEmpty } = require('./seed');

seedIfEmpty();

const app = express();
app.use(cors());
app.use(express.json());

const UPLOAD_DIR = path.join(__dirname, '..', 'uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
app.use('/uploads', express.static(UPLOAD_DIR));

const upload = multer({
  storage: multer.diskStorage({
    destination: UPLOAD_DIR,
    filename: (_req, file, cb) => {
      const ext = path.extname(file.originalname).toLowerCase() || '.jpg';
      cb(null, `${Date.now()}-${Math.round(Math.random() * 1e6)}${ext}`);
    },
  }),
  limits: { fileSize: 5 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => cb(null, /^image\//.test(file.mimetype)),
});

const ORDER_STATUSES = ['pending', 'confirmed', 'preparing', 'ready', 'delivering', 'delivered', 'cancelled'];
const PAYMENT_METHODS = ['cash', 'tmoney', 'flooz'];

// Wraps handlers so thrown errors become JSON responses.
const h = (fn) => (req, res) => {
  try {
    fn(req, res);
  } catch (err) {
    console.error(err);
    res.status(err.status || 500).json({ error: err.status ? err.message : 'Erreur serveur' });
  }
};

function httpError(status, message) {
  const err = new Error(message);
  err.status = status;
  return err;
}

function publicUser(u) {
  return { id: u.id, name: u.name, phone: u.phone, email: u.email, role: u.role, address: u.address, created_at: u.created_at };
}

function mapProduct(p) {
  return { ...p, available: !!p.available, popular: !!p.popular };
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

// ---------- Auth ----------

app.post('/api/auth/register', h((req, res) => {
  const { name, phone, password, email, address } = req.body || {};
  if (!name?.trim() || !phone?.trim() || !password) throw httpError(400, 'Nom, téléphone et mot de passe requis');
  if (password.length < 6) throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
  if (db.prepare('SELECT id FROM users WHERE phone = ?').get(phone.trim())) {
    throw httpError(409, 'Ce numéro est déjà utilisé');
  }
  const info = db
    .prepare('INSERT INTO users (name, phone, email, password_hash, address) VALUES (?, ?, ?, ?, ?)')
    .run(name.trim(), phone.trim(), email?.trim() || null, bcrypt.hashSync(password, 10), address?.trim() || null);
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid);
  res.status(201).json({ token: signToken(user), user: publicUser(user) });
}));

app.post('/api/auth/login', h((req, res) => {
  const { phone, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE phone = ?').get((phone || '').trim());
  if (!user || !bcrypt.compareSync(password || '', user.password_hash)) {
    throw httpError(401, 'Téléphone ou mot de passe incorrect');
  }
  res.json({ token: signToken(user), user: publicUser(user) });
}));

app.get('/api/auth/me', requireAuth, h((req, res) => {
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
  if (!user) throw httpError(404, 'Utilisateur introuvable');
  res.json(publicUser(user));
}));

app.put('/api/auth/me', requireAuth, h((req, res) => {
  const { name, email, address, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
  if (!user) throw httpError(404, 'Utilisateur introuvable');
  if (password && password.length < 6) throw httpError(400, 'Le mot de passe doit contenir au moins 6 caractères');
  db.prepare('UPDATE users SET name = ?, email = ?, address = ?, password_hash = ? WHERE id = ?').run(
    name?.trim() || user.name,
    email !== undefined ? email?.trim() || null : user.email,
    address !== undefined ? address?.trim() || null : user.address,
    password ? bcrypt.hashSync(password, 10) : user.password_hash,
    user.id,
  );
  res.json(publicUser(db.prepare('SELECT * FROM users WHERE id = ?').get(user.id)));
}));

// ---------- Catalogue public ----------

app.get('/api/settings', h((_req, res) => res.json(getSettings())));

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

app.post('/api/orders', requireAuth, h((req, res) => {
  const settings = getSettings();
  if (!settings.is_open) throw httpError(400, 'Le restaurant est actuellement fermé');

  const { items, mode, address, phone, note, payment_method } = req.body || {};
  if (!Array.isArray(items) || items.length === 0) throw httpError(400, 'Votre panier est vide');
  if (!['delivery', 'pickup'].includes(mode)) throw httpError(400, 'Mode de retrait invalide');
  if (mode === 'delivery' && !address?.trim()) throw httpError(400, 'Adresse de livraison requise');
  if (!phone?.trim()) throw httpError(400, 'Numéro de téléphone requis');
  if (!PAYMENT_METHODS.includes(payment_method)) throw httpError(400, 'Moyen de paiement invalide');

  // Prices are always recomputed server-side from the catalogue.
  const getProduct = db.prepare('SELECT * FROM products WHERE id = ?');
  const lines = items.map((it) => {
    const qty = Math.floor(Number(it.quantity));
    const p = getProduct.get(Number(it.product_id));
    if (!p || !p.available) throw httpError(400, `Un article n'est plus disponible`);
    if (!(qty >= 1 && qty <= 50)) throw httpError(400, 'Quantité invalide');
    return { product: p, qty };
  });

  const subtotal = lines.reduce((s, l) => s + l.product.price * l.qty, 0);
  if (subtotal < settings.min_order) throw httpError(400, `Commande minimum : ${settings.min_order} FCFA`);
  const deliveryFee = mode === 'delivery' ? settings.delivery_fee : 0;

  const orderId = transaction(() => {
    const info = db
      .prepare(
        `INSERT INTO orders (user_id, mode, address, phone, note, payment_method, subtotal, delivery_fee, total)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        req.user.id, mode, mode === 'delivery' ? address.trim() : null, phone.trim(),
        note?.trim() || null, payment_method, subtotal, deliveryFee, subtotal + deliveryFee,
      );
    const insertItem = db.prepare(
      'INSERT INTO order_items (order_id, product_id, name, unit_price, quantity) VALUES (?, ?, ?, ?, ?)',
    );
    for (const l of lines) insertItem.run(info.lastInsertRowid, l.product.id, l.product.name, l.product.price, l.qty);
    return info.lastInsertRowid;
  });

  res.status(201).json(loadOrder(orderId));
}));

app.get('/api/orders', requireAuth, h((req, res) => {
  res.json(loadOrders('WHERE o.user_id = ?', [req.user.id]));
}));

app.get('/api/orders/:id', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  if (!order || (order.user_id !== req.user.id && req.user.role !== 'admin')) throw httpError(404, 'Commande introuvable');
  res.json(order);
}));

app.post('/api/orders/:id/cancel', requireAuth, h((req, res) => {
  const order = loadOrder(Number(req.params.id));
  if (!order || order.user_id !== req.user.id) throw httpError(404, 'Commande introuvable');
  if (order.status !== 'pending') throw httpError(400, 'Cette commande ne peut plus être annulée');
  db.prepare(`UPDATE orders SET status = 'cancelled', updated_at = datetime('now') WHERE id = ?`).run(order.id);
  res.json(loadOrder(order.id));
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
  res.json({ today, total, active, pending, customers, topProducts, last7Days });
}));

app.get('/api/admin/orders', requireAdmin, h((req, res) => {
  const { status } = req.query;
  if (status === 'active') {
    return res.json(loadOrders(`WHERE o.status NOT IN ('delivered', 'cancelled')`, []));
  }
  if (status && ORDER_STATUSES.includes(status)) return res.json(loadOrders('WHERE o.status = ?', [status]));
  res.json(loadOrders('', []));
}));

app.patch('/api/admin/orders/:id/status', requireAdmin, h((req, res) => {
  const { status } = req.body || {};
  if (!ORDER_STATUSES.includes(status)) throw httpError(400, 'Statut invalide');
  const info = db
    .prepare(`UPDATE orders SET status = ?, updated_at = datetime('now') WHERE id = ?`)
    .run(status, Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Commande introuvable');
  res.json(loadOrder(Number(req.params.id)));
}));

app.post('/api/admin/categories', requireAdmin, h((req, res) => {
  const { name, icon, position } = req.body || {};
  if (!name?.trim()) throw httpError(400, 'Nom requis');
  const info = db
    .prepare('INSERT INTO categories (name, icon, position) VALUES (?, ?, ?)')
    .run(name.trim(), icon || null, Number(position) || 0);
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
  res.status(204).end();
}));

function productFields(body) {
  const { name, description, price, image_url, category_id, available, popular } = body || {};
  if (!name?.trim()) throw httpError(400, 'Nom requis');
  const p = Math.round(Number(price));
  if (!(p > 0)) throw httpError(400, 'Prix invalide');
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
  res.status(201).json(mapProduct(db.prepare('SELECT * FROM products WHERE id = ?').get(info.lastInsertRowid)));
}));

app.put('/api/admin/products/:id', requireAdmin, h((req, res) => {
  const info = db
    .prepare(
      `UPDATE products SET category_id = ?, name = ?, description = ?, price = ?, image_url = ?,
       available = ?, popular = ? WHERE id = ?`,
    )
    .run(...productFields(req.body), Number(req.params.id));
  if (info.changes === 0) throw httpError(404, 'Produit introuvable');
  res.json(mapProduct(db.prepare('SELECT * FROM products WHERE id = ?').get(Number(req.params.id))));
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
  res.status(204).end();
}));

app.post('/api/admin/upload', requireAdmin, upload.single('image'), h((req, res) => {
  if (!req.file) throw httpError(400, 'Image invalide (max 5 Mo)');
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
  const allowed = ['delivery_fee', 'min_order', 'is_open', 'restaurant_phone', 'restaurant_address'];
  const upsert = db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value');
  transaction(() => {
    for (const key of allowed) {
      if (req.body?.[key] === undefined) continue;
      const v = req.body[key];
      upsert.run(key, typeof v === 'boolean' ? (v ? '1' : '0') : String(v));
    }
  });
  res.json(getSettings());
}));

app.get('/', (_req, res) => res.json({ name: 'Ivrivrii Chicken API', status: 'ok' }));

const PORT = Number(process.env.PORT) || 4000;
app.listen(PORT, '0.0.0.0', () => console.log(`🐔 API Ivrivrii Chicken sur http://localhost:${PORT}`));
