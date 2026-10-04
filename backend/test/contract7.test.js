// Frais absorbés par le restaurant, zones de livraison, ventes au comptoir et rapports par période
// (node --test). Serveur de test sur le port 4730 (base temporaire).
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const bcrypt = require('bcryptjs');
const { providerFeeOn, customerFee } = require('../src/payments/fees');

const BACKEND = path.join(__dirname, '..');
const PORT = 4730;
const BASE = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function startServer(dir) {
  const env = {
    ...process.env, PORT: String(PORT), DB_PATH: path.join(dir, 'c7.db'), LOG_DIR: path.join(dir, 'logs'), LOG_CONSOLE: '0',
    JWT_SECRET: 'test-secret-c7', ADMIN_PHONE: '0700000000', ADMIN_PASSWORD: 'admin123', NODE_ENV: 'test',
    PAYMENT_PROVIDER: '', PAYGATE_AUTH_TOKEN: '', KADEV_PUBLIC_KEY: '', KADEV_SECRET_KEY: '', ALLOW_SIMULATION: '',
    PROVIDER_FEE_PERCENT: '', PROVIDER_FEE_PERCENT_FLOOZ: '', PROVIDER_FEE_PERCENT_MIXX: '', SMS_PROVIDER: '',
    FIREBASE_SERVICE_ACCOUNT: '', BACKUP_GITHUB_REPO: '', BACKUP_GITHUB_TOKEN: '',
    NOMINATIM_URL: 'http://127.0.0.1:9', OSRM_URL: 'http://127.0.0.1:9',
    PAYMENT_TASK_INTERVAL_MS: '600000', RECONCILE_DELAY_MS: '3600000', DELIVERY_TASK_INTERVAL_MS: '600000',
  };
  const child = spawn(process.execPath, ['src/server.js'], { cwd: BACKEND, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  child.stderr.on('data', (d) => (out += d));
  return { child, out: () => out };
}
const stop = (srv) => new Promise((r) => {
  if (srv.child.exitCode !== null) return r();
  srv.child.once('exit', r);
  srv.child.kill();
});
async function waitHealth(srv) {
  for (let i = 0; i < 80; i++) {
    try {
      if ((await fetch(`${BASE}/api/health`)).ok) {
        await sleep(300);
        if (srv.child.exitCode !== null) throw new Error(`port ${PORT} occupé\n${srv.out()}`);
        return;
      }
    } catch (err) {
      if (/occupé/.test(err.message)) throw err;
    }
    if (srv.child.exitCode !== null) break;
    await sleep(150);
  }
  throw new Error(`serveur injoignable\n${srv.out()}`);
}

function client(token = null) {
  const call = async (method, p, body) => {
    const res = await fetch(BASE + p, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let data = text;
    try { data = JSON.parse(text); } catch {}
    return { status: res.status, data, text, headers: res.headers };
  };
  return { call, setToken: (t) => (token = t) };
}
async function login(phone, password) {
  const c = client();
  const r = await c.call('POST', '/api/auth/login', { phone, password });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  c.setToken(r.data.token);
  c.user = r.data.user;
  c.token = r.data.token;
  return c;
}

const RESTO = { lat: 6.1319, lng: 1.2228 };
const north = (km) => ({ lat: RESTO.lat + km / 111.195, lng: RESTO.lng });

test('serveur : frais absorbés, zones, comptoir, rapports', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-c7-'));
  const srv = startServer(dir);
  t.after(() => stop(srv));
  await waitHealth(srv);
  const sql = new DatabaseSync(path.join(dir, 'c7.db'));
  sql.exec('PRAGMA busy_timeout = 5000');
  t.after(() => sql.close());

  const admin = await login('0700000000', 'admin123');
  const hash = bcrypt.hashSync('secret123', 4);
  let seq = 0;
  async function customer() {
    const local = String(94000000 + ++seq);
    sql.prepare(`INSERT INTO users (name, phone, password_hash) VALUES (?, ?, ?)`).run(`Client ${seq}`, `+228${local}`, hash);
    return login(local, 'secret123');
  }
  const products = (await admin.call('GET', '/api/products')).data;
  const big = products.find((p) => p.price >= 3000);
  const order = (c, extra = {}) => c.call('POST', '/api/orders', {
    items: [{ product_id: big.id, quantity: 1 }], phone: '90111111', mode: 'delivery', address: 'Tokoin, Lomé',
    payment_method: 'cash', location: { lat: 6.13, lng: 1.22 }, ...extra,
  });
  const status = (id, s) => admin.call('PATCH', `/api/admin/orders/${id}/status`, { status: s });
  const r0 = await admin.call('POST', '/api/admin/staff', { name: 'Cuisine', phone: '91444444', password: 'cuisine1', admin_level: 'kitchen' });
  assert.equal(r0.status, 201);
  const kitchen = await login('91444444', 'cuisine1');

  await t.test('frais à la charge du restaurant (défaut) : total sans frais, vraie commission à l\'encaissement', async () => {
    const s = (await client().call('GET', '/api/settings')).data;
    assert.equal(s.payment_fees_paid_by, 'restaurant', 'défaut');
    const percent = s.payment_fee_percent_by_operator.flooz;
    assert.ok(percent > 0);

    // Paiement simulé (push USSD) : commission au taux figé sur la commande.
    const cust = await customer();
    const o = (await order(cust, { payment_method: 'flooz' })).data;
    assert.equal(o.payment_fee, 0);
    assert.equal(o.total, o.subtotal + o.delivery_fee);
    assert.equal(o.payment_fee_percent, percent);
    const quote = (await client().call('GET', '/api/delivery/quote')).data;
    assert.equal(quote.fee, o.delivery_fee);
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' })).status, 201);
    const sim = await cust.call('POST', `/api/orders/${o.id}/payments/current/simulate`, { result: 'paid' });
    assert.equal(sim.data.order.payment_status, 'paid');
    const pay = sql.prepare(`SELECT * FROM payments WHERE order_id = ? AND status = 'paid'`).get(o.id);
    const fee = providerFeeOn(o.total, percent);
    assert.ok(fee > 0);
    assert.equal(pay.gross_amount, o.total);
    assert.equal(pay.provider_fee, fee);
    assert.equal(pay.net_amount, o.total - fee);

    // Changement d'opérateur puis validation manuelle (référence SMS) : même règle.
    const o2 = (await order(cust, { payment_method: 'flooz', mode: 'pickup', location: undefined })).data;
    const m = await cust.call('POST', `/api/orders/${o2.id}/payment-method`, { payment_method: 'mixx' });
    assert.equal(m.status, 200);
    assert.equal(m.data.payment_fee, 0);
    assert.equal(m.data.total, m.data.subtotal);
    assert.equal(m.data.payment_fee_percent, s.payment_fee_percent_by_operator.mixx);
    const push = await cust.call('POST', `/api/orders/${o2.id}/payments`, { phone: '90111111' });
    const v = await admin.call('POST', `/api/admin/payments/${push.data.payment.id}/validate`, { reference: 'SMS-C7-1', amount: m.data.total });
    assert.equal(v.status, 200, JSON.stringify(v.data));
    const fee2 = providerFeeOn(m.data.total, m.data.payment_fee_percent);
    const col = (await admin.call('GET', '/api/admin/collections')).data;
    const row = col.payments.find((p) => p.id === push.data.payment.id);
    assert.equal(row.gross, m.data.total);
    assert.equal(row.provider_fee, fee2);
    assert.equal(row.net, m.data.total - fee2);
    assert.equal(col.totals.fees, fee + fee2);
    assert.equal(col.totals.net, o.total + m.data.total - fee - fee2);

    // Rapprochement : rien à signaler (montants identiques chez le prestataire simulé).
    const rec = await admin.call('POST', '/api/admin/payments/reconcile');
    assert.equal(rec.status, 200);
    assert.equal(rec.data.amount_mismatch, 0);

    // Espèces : aucun taux.
    const cash = (await order(cust)).data;
    assert.equal(cash.payment_fee, 0);
    assert.equal(cash.payment_fee_percent, null);
  });

  await t.test('frais à la charge du client : gross-up, net = sous-total + livraison', async () => {
    assert.equal((await admin.call('PUT', '/api/admin/settings', { payment_fees_paid_by: 'personne' })).status, 400);
    assert.equal((await kitchen.call('PUT', '/api/admin/settings', { payment_fees_paid_by: 'client' })).status, 403);
    const r = await admin.call('PUT', '/api/admin/settings', { payment_fees_paid_by: 'client' });
    assert.equal(r.status, 200);
    assert.equal(r.data.payment_fees_paid_by, 'client');
    assert.equal((await client().call('GET', '/api/settings')).data.payment_fees_paid_by, 'client');
    const cust = await customer();
    const o = (await order(cust, { payment_method: 'flooz' })).data;
    const base = o.subtotal + o.delivery_fee;
    assert.equal(o.payment_fee, customerFee(base, o.payment_fee_percent));
    assert.ok(o.payment_fee > 0);
    assert.equal(o.total, base + o.payment_fee);
    await cust.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' });
    await cust.call('POST', `/api/orders/${o.id}/payments/current/simulate`, { result: 'paid' });
    const pay = sql.prepare(`SELECT * FROM payments WHERE order_id = ? AND status = 'paid'`).get(o.id);
    assert.equal(pay.net_amount, base);
    assert.ok(sql.prepare(`SELECT 1 FROM audit_logs WHERE action = 'settings_changed' AND details LIKE '%payment_fees_paid_by%'`).get());
    await admin.call('PUT', '/api/admin/settings', { payment_fees_paid_by: 'restaurant' });
  });

  await t.test('zones de livraison : CRUD, devis, commande', async () => {
    await admin.call('PUT', '/api/admin/settings', { restaurant_lat: RESTO.lat, restaurant_lng: RESTO.lng });
    const create = (z) => admin.call('POST', '/api/admin/delivery-zones', z);
    for (const bad of [
      { name: '', fee: 500 }, { name: 'x'.repeat(61), fee: 500 }, { name: 'A', fee: 1.5 }, { name: 'A', fee: 100001 },
      { name: 'A', fee: -1 }, { name: 'A', fee: 500, center_lat: 6.1, center_lng: 1.2 },
      { name: 'A', fee: 500, center_lat: 6.1, center_lng: 1.2, radius_km: 0.05 },
      { name: 'A', fee: 500, center_lat: 6.1, center_lng: 1.2, radius_km: 51 },
      { name: 'A', fee: 500, center_lat: 95, center_lng: 1.2, radius_km: 2 }, { name: 'A', fee: 500, active: 'oui' },
    ]) {
      assert.equal((await create(bad)).status, 400, JSON.stringify(bad));
    }
    assert.equal((await kitchen.call('POST', '/api/admin/delivery-zones', { name: 'K', fee: 1 })).status, 403);
    assert.equal((await kitchen.call('GET', '/api/admin/delivery-zones')).status, 403);

    const big5 = (await create({ name: 'Grand Lomé', fee: 1500, position: 2, center_lat: RESTO.lat, center_lng: RESTO.lng, radius_km: 5 })).data;
    const small = (await create({ name: 'Centre', fee: 700, position: 1, ...{ center_lat: north(0.5).lat, center_lng: RESTO.lng, radius_km: 1 } })).data;
    const r = await create({ name: '  Baguida  ', fee: 2000, position: 1, center_lat: null, center_lng: null, radius_km: null });
    assert.equal(r.status, 201);
    const free = r.data;
    assert.deepEqual(free, { id: free.id, name: 'Baguida', fee: 2000, active: true, position: 1, center_lat: null, center_lng: null, radius_km: null });
    const off = (await create({ name: 'Fermée', fee: 100, active: false })).data;
    assert.equal(off.active, false);

    const pub = (await client().call('GET', '/api/delivery/zones')).data;
    assert.deepEqual(pub.map((z) => z.name), ['Baguida', 'Centre', 'Grand Lomé'], 'actives, triées position puis nom');
    assert.equal((await admin.call('GET', '/api/admin/delivery-zones')).data.length, 4);

    // Mise à jour partielle : le cercle est conservé.
    const up = await admin.call('PUT', `/api/admin/delivery-zones/${big5.id}`, { fee: 1600 });
    assert.equal(up.status, 200);
    assert.equal(up.data.fee, 1600);
    assert.equal(up.data.radius_km, 5);
    assert.equal((await admin.call('PUT', `/api/admin/delivery-zones/${big5.id}`, { radius_km: 3 })).status, 400, 'cercle incomplet');
    assert.equal((await admin.call('PUT', '/api/admin/delivery-zones/99999', { fee: 1 })).status, 404);

    assert.equal((await admin.call('PUT', '/api/admin/settings', { delivery_fee_mode: 'zone' })).status, 200);
    assert.equal((await client().call('GET', '/api/settings')).data.delivery_fee_mode, 'zone');
    const quote = async (qs) => (await client().call('GET', `/api/delivery/quote?${qs}`)).data;
    let q = await quote('');
    assert.equal(q.mode, 'zone');
    assert.equal(q.within_zone, false);
    assert.equal(q.fee, 0);
    assert.equal(q.zone_id, null);
    assert.equal(q.message, 'Choisissez votre zone de livraison');
    q = await quote(`zone_id=${free.id}`);
    assert.deepEqual([q.fee, q.zone_id, q.zone_name, q.within_zone, q.message], [2000, free.id, 'Baguida', true, null]);
    const inSmall = north(0.6);
    q = await quote(`lat=${inSmall.lat}&lng=${inSmall.lng}`);
    assert.equal(q.zone_id, small.id, 'le plus petit cercle gagne');
    assert.equal(q.fee, 700);
    assert.ok(q.distance_km > 0);
    const inBig = north(3);
    q = await quote(`lat=${inBig.lat}&lng=${inBig.lng}`);
    assert.equal(q.zone_id, big5.id);
    assert.equal(q.fee, 1600);
    const far = north(20);
    q = await quote(`lat=${far.lat}&lng=${far.lng}`);
    assert.equal(q.within_zone, false);
    assert.equal(q.message, 'Adresse hors des zones de livraison');
    // Zone choisie prioritaire sur la position ; zone inactive ignorée.
    q = await quote(`lat=${far.lat}&lng=${far.lng}&zone_id=${free.id}`);
    assert.equal(q.zone_id, free.id);
    q = await quote(`zone_id=${off.id}`);
    assert.equal(q.within_zone, false);
    assert.equal(q.message, 'Choisissez votre zone de livraison');
    assert.equal((await client().call('GET', '/api/delivery/quote?zone_id=abc')).status, 400);

    const cust = await customer();
    let o = await order(cust, { location: far });
    assert.equal(o.status, 400);
    assert.equal(o.data.error, 'Adresse hors des zones de livraison');
    o = await order(cust, { location: undefined });
    assert.equal(o.status, 400);
    assert.equal(o.data.error, 'Choisissez votre zone de livraison');
    o = await order(cust, { location: undefined, zone_id: free.id, delivery_fee: 0 });
    assert.equal(o.status, 201, JSON.stringify(o.data));
    assert.equal(o.data.delivery_fee, 2000);
    assert.equal(o.data.delivery_zone_id, free.id);
    assert.equal(o.data.delivery_zone_name, 'Baguida');
    assert.equal(o.data.total, o.data.subtotal + 2000);
    o = await order(cust, { location: inSmall });
    assert.equal(o.data.delivery_zone_id, small.id, 'zone reconnue par la position');
    assert.equal(o.data.delivery_fee, 700);
    const pickup = await order(cust, { mode: 'pickup', location: undefined });
    assert.equal(pickup.status, 201);
    assert.equal(pickup.data.delivery_zone_id, null);

    // Suppression : zone utilisée → désactivée ; zone inutilisée → supprimée.
    let d = await admin.call('DELETE', `/api/admin/delivery-zones/${free.id}`);
    assert.deepEqual([d.status, d.data.deleted, d.data.deactivated, d.data.zone.active], [200, false, true, false]);
    d = await admin.call('DELETE', `/api/admin/delivery-zones/${off.id}`);
    assert.deepEqual([d.status, d.data.deleted], [200, true]);
    assert.equal((await admin.call('DELETE', `/api/admin/delivery-zones/${off.id}`)).status, 404);
    assert.ok(!(await client().call('GET', '/api/delivery/zones')).data.some((z) => z.id === free.id));
    const actions = sql.prepare(`SELECT DISTINCT action FROM audit_logs WHERE action LIKE 'delivery_zone_%'`).all().map((a) => a.action).sort();
    assert.deepEqual(actions, ['delivery_zone_created', 'delivery_zone_deactivated', 'delivery_zone_deleted', 'delivery_zone_updated']);
    await admin.call('PUT', '/api/admin/settings', { delivery_fee_mode: 'fixed' });
  });

  await t.test('vente au comptoir : espèces, mobile money, push par le caissier, filtres', async () => {
    const cheap = products.reduce((a, b) => (a.price <= b.price ? a : b));
    const counter = (c, body) => c.call('POST', '/api/admin/counter-orders', body);
    // Restaurant fermé et minimum de commande élevé : sans effet au comptoir.
    await admin.call('PUT', '/api/admin/settings', { is_open: false, min_order: 1000000 });
    const cust = await customer();
    assert.equal((await counter(cust, { items: [{ product_id: cheap.id, quantity: 1 }], service: 'takeaway', payment_method: 'cash' })).status, 403);
    for (const bad of [
      { items: [], service: 'takeaway', payment_method: 'cash' },
      { items: [{ product_id: cheap.id, quantity: 1 }], service: 'livraison', payment_method: 'cash' },
      { items: [{ product_id: cheap.id, quantity: 1 }], service: 'takeaway', payment_method: 'carte' },
      { items: [{ product_id: cheap.id, quantity: 0 }], service: 'takeaway', payment_method: 'cash' },
      { items: [{ product_id: cheap.id, quantity: 1 }], service: 'takeaway', payment_method: 'cash', phone: 'abc' },
      { items: [{ product_id: cheap.id, quantity: 1 }], service: 'takeaway', payment_method: 'cash', customer_name: 12 },
    ]) {
      assert.equal((await counter(kitchen, bad)).status, 400, JSON.stringify(bad));
    }
    const noPhone = await counter(kitchen, { items: [{ product_id: cheap.id, quantity: 1 }], service: 'takeaway', payment_method: 'flooz' });
    assert.equal(noPhone.status, 400);
    assert.match(noPhone.data.error, /téléphone/i);

    let r = await counter(kitchen, { items: [{ product_id: cheap.id, quantity: 2 }], service: 'dine_in', payment_method: 'cash', note: 'Table 4' });
    assert.equal(r.status, 201, JSON.stringify(r.data));
    const cash = r.data;
    assert.equal(cash.source, 'counter');
    assert.equal(cash.dine_in, true);
    assert.equal(cash.mode, 'pickup');
    assert.equal(cash.status, 'confirmed');
    assert.equal(cash.payment_status, 'unpaid');
    assert.equal(cash.user_id, kitchen.user.id);
    assert.equal(cash.customer_name, 'Comptoir');
    assert.equal(cash.customer_label, null);
    assert.equal(cash.delivery_fee, 0);
    assert.equal(cash.subtotal, cheap.price * 2);
    assert.equal(cash.total, cash.subtotal);
    assert.equal(cash.note, 'Table 4');
    assert.equal(cash.phone, (await client().call('GET', '/api/settings')).data.restaurant_phone);
    assert.ok(sql.prepare(`SELECT 1 FROM audit_logs WHERE action = 'counter_order_created' AND user_id = ?`).get(kitchen.user.id));

    // Cuisine : confirmed → preparing → ready → delivered (retrait).
    for (const s of ['preparing', 'ready', 'delivered']) {
      const st = await kitchen.call('PATCH', `/api/admin/orders/${cash.id}/status`, { status: s });
      assert.equal(st.status, 200, `${s} : ${JSON.stringify(st.data)}`);
    }

    r = await counter(kitchen, {
      items: [{ product_id: big.id, quantity: 1 }], service: 'takeaway', payment_method: 'flooz', phone: '90 12 34 56', customer_name: ' Ama ',
    });
    assert.equal(r.status, 201, JSON.stringify(r.data));
    const momo = r.data;
    assert.deepEqual([momo.status, momo.payment_status, momo.dine_in, momo.customer_name, momo.customer_label, momo.phone],
      ['pending', 'pending', false, 'Ama', 'Ama', '+22890123456']);
    assert.equal(momo.payment_fee, 0, 'frais absorbés par le restaurant');
    assert.equal(momo.total, momo.subtotal);
    // Le caissier (propriétaire de la commande) lance le push et suit le paiement.
    const push = await kitchen.call('POST', `/api/orders/${momo.id}/payments`, { phone: '90123456' });
    assert.equal(push.status, 201, JSON.stringify(push.data));
    assert.equal(push.data.payment.amount, momo.total);
    const cur = await kitchen.call('GET', `/api/orders/${momo.id}/payments/current`);
    assert.equal(cur.status, 200);
    assert.equal(cur.data.payment.status, 'pending');
    const sim = await kitchen.call('POST', `/api/orders/${momo.id}/payments/current/simulate`, { result: 'paid' });
    assert.equal(sim.data.order.payment_status, 'paid');
    assert.equal(sim.data.order.status, 'confirmed', 'vente au comptoir payée : en cuisine');

    // Filtres et visibilité.
    const counterList = (await kitchen.call('GET', '/api/admin/orders?source=counter')).data;
    assert.deepEqual(counterList.map((o) => o.id).sort(), [cash.id, momo.id].sort());
    assert.ok((await admin.call('GET', '/api/admin/orders?source=app')).data.every((o) => o.source === 'app'));
    assert.equal((await admin.call('GET', '/api/admin/orders?source=autre')).status, 400);
    const active = (await admin.call('GET', '/api/admin/orders?status=confirmed&source=counter')).data;
    assert.deepEqual(active.map((o) => o.id), [momo.id]);
    assert.equal((await kitchen.call('GET', '/api/orders')).data.length, 0, 'pas dans « Mes commandes » du caissier');
    const appOrder = (await admin.call('GET', '/api/admin/orders?source=app&limit=1')).data[0];
    assert.equal(appOrder.dine_in, false);
    assert.equal(appOrder.customer_label, null);
    assert.ok('delivery_zone_id' in appOrder && 'delivery_zone_name' in appOrder);

    const stats = (await admin.call('GET', '/api/admin/stats')).data;
    const ch = Object.fromEntries(stats.by_channel_today.map((c) => [c.channel, c]));
    assert.equal(ch.counter.orders, 2);
    assert.equal(ch.counter.revenue, cash.total + momo.total);
    assert.ok(ch.app.orders > 0);
    await admin.call('PUT', '/api/admin/settings', { is_open: true, min_order: 2000 });
  });

  await t.test('rapports : totaux, répartitions, jours, export CSV', async () => {
    const drv = (await admin.call('POST', '/api/admin/drivers', { name: 'Yao', phone: '91222222', password: 'livreur1' })).data;
    const uid = admin.user.id;
    const ins = sql.prepare(`INSERT INTO orders (user_id, status, mode, phone, payment_method, subtotal, delivery_fee, total, payment_status,
                               source, dine_in, customer_label, driver_id, picked_up_at, driver_delivered_at, created_at)
                             VALUES (?, ?, ?, '+22890111111', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
    const item = sql.prepare('INSERT INTO order_items (order_id, name, unit_price, quantity) VALUES (?, ?, ?, ?)');
    const payment = sql.prepare(`INSERT INTO payments (order_id, provider, amount, status, gross_amount, provider_fee, net_amount, paid_at)
                                 VALUES (?, 'simulation', ?, 'paid', ?, ?, ?, ?)`);
    const add = (o) => Number(ins.run(uid, o.status, o.mode, o.method, o.total - (o.delivery ?? 0), o.delivery ?? 0, o.total, o.pay,
      o.source ?? 'app', o.dineIn ? 1 : 0, o.label ?? null, o.driver ?? null, o.picked ?? null, o.dropped ?? null, o.at).lastInsertRowid);
    const o1 = add({ status: 'delivered', mode: 'delivery', method: 'cash', total: 5000, delivery: 1000, pay: 'unpaid', at: '2025-01-10 11:50:00',
      driver: drv.id, picked: '2025-01-10 12:00:00', dropped: '2025-01-10 12:30:00' });
    item.run(o1, 'Poulet', 2000, 2);
    const o2 = add({ status: 'delivered', mode: 'pickup', method: 'flooz', total: 3000, pay: 'paid', at: '2025-01-10 13:00:00' });
    item.run(o2, 'Frites', 3000, 1);
    payment.run(o2, 3000, 3000, 60, 2940, '2025-01-10 13:01:00');
    const o3 = add({ status: 'confirmed', mode: 'pickup', method: 'cash', total: 2000, pay: 'unpaid', at: '2025-01-12 09:00:00',
      source: 'counter', dineIn: true, label: '=HYPERLINK("http://x")' });
    item.run(o3, 'Poulet', 2000, 1);
    const o4 = add({ status: 'ready', mode: 'pickup', method: 'mixx', total: 1500, pay: 'paid', at: '2025-01-12 10:00:00', source: 'counter' });
    item.run(o4, 'Soda', 1500, 1);
    payment.run(o4, 1500, 1500, 30, 1470, '2025-01-12 10:01:00');
    add({ status: 'cancelled', mode: 'delivery', method: 'cash', total: 9999, pay: 'unpaid', at: '2025-01-12 11:00:00' });
    add({ status: 'pending', mode: 'pickup', method: 'flooz', total: 4000, pay: 'pending', at: '2025-01-12 12:00:00' });
    add({ status: 'delivered', mode: 'pickup', method: 'flooz', total: 7000, pay: 'refunded', at: '2025-01-11 12:00:00' });
    add({ status: 'delivered', mode: 'pickup', method: 'cash', total: 1000, pay: 'unpaid', at: '2025-01-13 00:00:00' });
    add({ status: 'delivered', mode: 'pickup', method: 'cash', total: 1000, pay: 'unpaid', at: '2025-01-09 23:59:59' });

    const rep = await admin.call('GET', '/api/admin/reports?from=2025-01-10&to=2025-01-12');
    assert.equal(rep.status, 200, JSON.stringify(rep.data));
    const d = rep.data;
    assert.equal(d.from, '2025-01-10');
    assert.equal(d.to, '2025-01-12');
    assert.deepEqual(d.totals, { orders: 4, revenue: 11500, avg_basket: 2875, cancelled: 1, payment_fees: 90 });
    assert.deepEqual(d.by_channel, [{ channel: 'app', orders: 2, revenue: 8000 }, { channel: 'counter', orders: 2, revenue: 3500 }]);
    assert.deepEqual(d.by_mode, [
      { mode: 'delivery', orders: 1, revenue: 5000 }, { mode: 'pickup', orders: 2, revenue: 4500 }, { mode: 'dine_in', orders: 1, revenue: 2000 },
    ]);
    assert.deepEqual(d.by_payment, [
      { method: 'cash', orders: 2, revenue: 7000, fees: 0 }, { method: 'flooz', orders: 1, revenue: 3000, fees: 60 },
      { method: 'mixx', orders: 1, revenue: 1500, fees: 30 },
    ]);
    assert.deepEqual(d.by_driver, [{ driver_id: drv.id, name: 'Yao', deliveries: 1, cash_collected: 5000, avg_minutes: 30 }]);
    assert.deepEqual(d.daily, [
      { day: '2025-01-10', orders: 2, revenue: 8000 }, { day: '2025-01-11', orders: 0, revenue: 0 }, { day: '2025-01-12', orders: 2, revenue: 3500 },
    ]);
    assert.deepEqual(d.top_products, [
      { name: 'Poulet', quantity: 3, revenue: 6000 }, { name: 'Frites', quantity: 1, revenue: 3000 }, { name: 'Soda', quantity: 1, revenue: 1500 },
    ]);

    // Période par défaut : 30 derniers jours, chaque jour présent.
    const def = (await admin.call('GET', '/api/admin/reports')).data;
    assert.equal(def.daily.length, 30);
    assert.equal(def.to, new Date().toISOString().slice(0, 10));
    assert.equal(def.daily[29].day, def.to);
    assert.equal(def.daily[0].day, def.from);
    for (const bad of ['from=2025-02-30', 'from=2025-1-01', 'to=20250101', 'from=2025-01-12&to=2025-01-10',
      'from=2024-01-01&to=2025-01-02', "from=2025-01-10'%20OR%201=1--", 'from[]=2025-01-10']) {
      assert.equal((await admin.call('GET', `/api/admin/reports?${bad}`)).status, 400, bad);
    }
    assert.equal((await admin.call('GET', '/api/admin/reports?from=2024-01-01&to=2024-12-31')).status, 200, '366 jours (année bissextile)');
    assert.equal((await kitchen.call('GET', '/api/admin/reports')).status, 403);
    assert.equal((await kitchen.call('GET', '/api/admin/reports/export.csv')).status, 403);

    const csv = await admin.call('GET', '/api/admin/reports/export.csv?from=2025-01-10&to=2025-01-12');
    assert.equal(csv.status, 200);
    assert.match(csv.headers.get('content-type'), /^text\/csv; charset=utf-8/);
    assert.equal(csv.headers.get('content-disposition'), 'attachment; filename="ventes-2025-01-10-2025-01-12.csv"');
    // fetch().text() retire le BOM : lecture des octets bruts.
    const raw = Buffer.from(await (await fetch(`${BASE}/api/admin/reports/export.csv?from=2025-01-10&to=2025-01-12`, {
      headers: { Authorization: `Bearer ${admin.token}` },
    })).arrayBuffer());
    assert.deepEqual([...raw.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'BOM UTF-8');
    const lines = raw.toString('utf8').slice(1).trimEnd().split('\r\n');
    assert.equal(lines[0], 'id;date;heure;canal;mode;zone;client;telephone;articles;sous_total;livraison;frais_paiement;total;paiement;statut_paiement;statut;livreur;commission_agregateur;net_restaurant');
    assert.equal(lines.length, 1 + 7, 'toutes les commandes de la période, annulées comprises');
    const first = lines[1].split(';');
    // Client = nom du compte (colonne 6, non vérifiée) ; téléphone protégé (commence par « + »).
    first.splice(6, 1);
    assert.deepEqual(first, [String(o1), '2025-01-10', '11:50', 'application', 'livraison', '', "'+22890111111", '2x Poulet',
      '4000', '1000', '0', '5000', 'espèces', 'à encaisser', 'livrée', 'Yao', '0', '5000']);
    const flooz = lines.find((l) => l.startsWith(`${o2};`)).split(';');
    assert.deepEqual(flooz.slice(-2), ['60', '2940']);
    const counterLine = lines.find((l) => l.startsWith(`${o3};`));
    assert.ok(counterLine.includes(`"'=HYPERLINK(""http://x"")"`), counterLine);
    assert.ok(counterLine.includes(';comptoir;sur place;'));
    assert.ok(lines.some((l) => l.includes(';annulée;')));
    assert.ok(sql.prepare(`SELECT 1 FROM audit_logs WHERE action = 'report_exported'`).get());
  });
});
