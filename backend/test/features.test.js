// Suivi du livreur, rôles du personnel, changement d'opérateur, tableau de bord, journal des erreurs,
// frais selon la distance et horaires (node --test). Serveur de test sur le port 4610 (base temporaire).
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const bcrypt = require('bcryptjs');
const { roadKm } = require('../src/delivery-fee');

const BACKEND = path.join(__dirname, '..');
const PORT = 4610;
const BASE = `http://localhost:${PORT}`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function startServer(dir) {
  const env = {
    ...process.env, PORT: String(PORT), DB_PATH: path.join(dir, 'features.db'), LOG_DIR: path.join(dir, 'logs'), LOG_CONSOLE: '0',
    JWT_SECRET: 'test-secret-features', ADMIN_PHONE: '0700000000', ADMIN_PASSWORD: 'admin123', NODE_ENV: 'test',
    PAYMENT_PROVIDER: '', PAYGATE_AUTH_TOKEN: '', KADEV_PUBLIC_KEY: '', KADEV_SECRET_KEY: '', ALLOW_SIMULATION: '',
    PROVIDER_FEE_PERCENT: '', PROVIDER_FEE_PERCENT_FLOOZ: '', PROVIDER_FEE_PERCENT_MIXX: '', SMS_PROVIDER: '',
    FIREBASE_SERVICE_ACCOUNT: '', BACKUP_GITHUB_REPO: '', BACKUP_GITHUB_TOKEN: '',
    // Aucun appel réseau réel : services de cartes injoignables (non utilisés par ces tests).
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
    return { status: res.status, data };
  };
  return { call, token: () => token, setToken: (t) => (token = t) };
}
async function login(phone, password) {
  const c = client();
  const r = await c.call('POST', '/api/auth/login', { phone, password });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  c.setToken(r.data.token);
  c.user = r.data.user;
  return c;
}

test('serveur : suivi, rôles, paiement, stats, erreurs, frais et horaires', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-features-'));
  const srv = startServer(dir);
  t.after(() => stop(srv));
  await waitHealth(srv);
  const sql = new DatabaseSync(path.join(dir, 'features.db'));
  sql.exec('PRAGMA busy_timeout = 5000');
  t.after(() => sql.close());

  const admin = await login('0700000000', 'admin123');
  const hash = bcrypt.hashSync('secret123', 4);
  let seq = 0;
  async function customer() {
    const local = String(93000000 + ++seq);
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

  await t.test('stats : même jour la semaine dernière, heures, pic', async () => {
    const adminId = admin.user.id;
    const ins = sql.prepare(`INSERT INTO orders (user_id, status, mode, phone, payment_method, subtotal, total, created_at)
                             VALUES (?, ?, 'pickup', '90111111', 'cash', ?, ?, ?)`);
    const ago2 = (hm) => sql.prepare(`SELECT datetime(date('now', '-2 days') || ' ' || ?) AS d`).get(hm).d;
    // 6 commandes à 12 h et 5 à 13 h : la fenêtre 12 h–14 h l'emporte quelle que soit l'heure du test.
    for (const hm of ['12:05:00', '12:20:00', '12:30:00', '12:40:00', '12:50:00', '12:59:00']) ins.run(adminId, 'delivered', 1000, 1000, ago2(hm));
    for (const hm of ['13:00:00', '13:15:00', '13:30:00', '13:45:00', '13:59:00']) ins.run(adminId, 'delivered', 1000, 1000, ago2(hm));
    ins.run(adminId, 'delivered', 1000, 1000, ago2('20:00:00'));
    for (let i = 0; i < 5; i++) ins.run(adminId, 'cancelled', 1000, 1000, ago2('05:10:00'));
    const at = (...mods) => sql.prepare(`SELECT datetime('now', ${mods.map(() => '?').join(', ')}) AS d`).get(...mods).d;
    ins.run(adminId, 'delivered', 1000, 1000, at('-7 days', '-1 second'));
    ins.run(adminId, 'delivered', 1000, 1000, at('-7 days', '-1 second'));
    ins.run(adminId, 'pending', 3000, 3000, at('-1 second'));
    // Plus tard dans la journée il y a 7 jours : hors comparaison.
    ins.run(adminId, 'delivered', 5000, 5000, at('-7 days', '+1 hour'));

    const s = (await admin.call('GET', '/api/admin/stats')).data;
    assert.deepEqual(s.same_day_last_week, { orders: 2, revenue: 2000 });
    assert.equal(s.today.orders, 1);
    assert.equal(s.today.revenue, 3000);
    assert.equal(s.revenue_change_percent, 50);
    assert.equal(s.orders_change_percent, -50);
    assert.equal(s.hourly.length, 24);
    assert.ok(s.hourly[12] >= 6 && s.hourly[13] >= 5 && s.hourly[20] >= 1);
    assert.equal(s.hourly[5] >= 5, false, 'commandes annulées exclues');
    assert.equal(s.hourly.reduce((a, b) => a + b, 0), 16, 'non annulées des 30 derniers jours');
    assert.equal(s.peak_window.start_hour, 12);
    assert.equal(s.peak_window.end_hour, 14);
    assert.ok(s.peak_window.orders >= 11);
    sql.exec('DELETE FROM orders');
    const empty = (await admin.call('GET', '/api/admin/stats')).data;
    assert.equal(empty.peak_window, null);
    assert.equal(empty.revenue_change_percent, null, 'semaine dernière à 0');
    assert.deepEqual(empty.hourly, Array(24).fill(0));
  });

  let kitchen;
  await t.test('personnel : création, rôles, dernier gérant', async () => {
    assert.equal(admin.user.admin_level, 'manager', 'compte créé par seed.js = gérant');
    let r = await admin.call('POST', '/api/admin/staff', { name: 'Cuisine', phone: '91 44 44 44', password: 'cuisine1', admin_level: 'kitchen' });
    assert.equal(r.status, 201, JSON.stringify(r.data));
    assert.deepEqual(Object.keys(r.data).sort(), ['active', 'admin_level', 'created_at', 'id', 'name', 'phone']);
    assert.equal(r.data.admin_level, 'kitchen');
    assert.equal(r.data.phone, '+22891444444');
    const kitchenId = r.data.id;
    assert.equal((await admin.call('POST', '/api/admin/staff', { name: 'X', phone: '91444444', password: 'cuisine1', admin_level: 'kitchen' })).status, 409);
    assert.equal((await admin.call('POST', '/api/admin/staff', { name: 'X', phone: '91555555', password: '123', admin_level: 'kitchen' })).status, 400);
    assert.equal((await admin.call('POST', '/api/admin/staff', { name: 'X', phone: '91555555', password: 'secret1', admin_level: 'chef' })).status, 400);

    kitchen = await login('91444444', 'cuisine1');
    assert.equal(kitchen.user.admin_level, 'kitchen');
    assert.equal((await kitchen.call('GET', '/api/auth/me')).data.admin_level, 'kitchen');
    // Interdit à la cuisine (403).
    for (const [m, p, b] of [
      ['GET', '/api/admin/stats'], ['PUT', '/api/admin/settings', { min_order: 0 }], ['GET', '/api/admin/payments/review'],
      ['GET', '/api/admin/collections'], ['POST', '/api/admin/orders/1/refund', {}], ['GET', '/api/admin/staff'],
      ['GET', '/api/admin/errors'], ['GET', '/api/admin/users'], ['GET', '/api/admin/monitoring'], ['GET', '/api/admin/audit'],
      ['GET', '/api/admin/password-resets'], ['POST', '/api/admin/products', { name: 'X', price: 100 }],
      ['POST', '/api/admin/drivers', { name: 'X', phone: '91666666', password: 'secret1' }],
    ]) {
      const res = await kitchen.call(m, p, b);
      assert.equal(res.status, 403, `${m} ${p}`);
      assert.equal(res.data.error, 'Accès réservé au gérant');
    }
    // Autorisé à la cuisine.
    assert.equal((await kitchen.call('GET', '/api/admin/orders')).status, 200);
    assert.equal((await kitchen.call('GET', '/api/admin/drivers')).status, 200);
    assert.equal((await kitchen.call('GET', '/api/products?all=1')).status, 200);
    const av = await kitchen.call('PATCH', `/api/admin/products/${big.id}/availability`, { available: true });
    assert.equal(av.status, 200);

    // Dernier gérant actif : ni rétrogradé ni désactivé.
    r = await admin.call('PATCH', `/api/admin/staff/${admin.user.id}`, { admin_level: 'kitchen' });
    assert.equal(r.status, 400);
    assert.equal(r.data.error, 'Il faut au moins un gérant actif');
    assert.equal((await admin.call('PATCH', `/api/admin/staff/${admin.user.id}`, { active: false })).status, 400);
    // Un second gérant, désactivé : ne compte pas.
    const m2 = (await admin.call('POST', '/api/admin/staff', { name: 'Gérant 2', phone: '91777777', password: 'gerant1', admin_level: 'manager' })).data;
    assert.equal((await admin.call('PATCH', `/api/admin/staff/${m2.id}`, { active: false })).data.active, false);
    assert.equal((await admin.call('PATCH', `/api/admin/staff/${admin.user.id}`, { admin_level: 'kitchen' })).status, 400);
    // Ancien admin sans niveau (NULL) = gérant.
    sql.prepare('UPDATE users SET admin_level = NULL WHERE id = ?').run(admin.user.id);
    assert.equal((await admin.call('GET', '/api/admin/stats')).status, 200);
    assert.equal((await admin.call('PATCH', `/api/admin/staff/${admin.user.id}`, { active: false })).status, 400);
    const list = (await admin.call('GET', '/api/admin/staff')).data;
    assert.equal(list.length, 3);
    assert.equal(list.find((s) => s.id === admin.user.id).admin_level, 'manager');

    // Niveau changé : sessions fermées ; la cuisine promue gérant se reconnecte.
    r = await admin.call('PATCH', `/api/admin/staff/${kitchenId}`, { admin_level: 'manager', name: 'Chef' });
    assert.equal(r.data.admin_level, 'manager');
    assert.equal(r.data.name, 'Chef');
    assert.equal((await kitchen.call('GET', '/api/admin/orders')).status, 401);
    await admin.call('PATCH', `/api/admin/staff/${kitchenId}`, { admin_level: 'kitchen', password: 'cuisine2' });
    kitchen = await login('91444444', 'cuisine2');
    const audits = sql.prepare(`SELECT action FROM audit_logs WHERE action IN ('staff_created', 'staff_updated')`).all();
    assert.ok(audits.length >= 5);
  });

  await t.test('suivi du livreur : position, driver_location, eta_minutes', async () => {
    const drv = await admin.call('POST', '/api/admin/drivers', { name: 'Yao', phone: '91222222', password: 'livreur1' });
    assert.equal(drv.status, 201);
    const driver = await login('91222222', 'livreur1');
    // Sans livraison : rien n'est enregistré.
    let r = await driver.call('POST', '/api/driver/location', { lat: 6.14, lng: 1.23 });
    assert.deepEqual(r.data, { tracking: false, active_orders: 0 });
    assert.equal(sql.prepare('SELECT COUNT(*) AS n FROM driver_locations').get().n, 0);
    for (const bad of [{}, { lat: 'a', lng: 1 }, { lat: 91, lng: 1 }, { lat: 6, lng: 181 }, { lat: 6, lng: 1, accuracy: -1 },
      { lat: 6, lng: 1, heading: 400 }, { lat: 6, lng: 1, speed: 'vite' }]) {
      assert.equal((await driver.call('POST', '/api/driver/location', bad)).status, 400, JSON.stringify(bad));
    }
    const cust = await customer();
    assert.equal((await cust.call('POST', '/api/driver/location', { lat: 6, lng: 1 })).status, 403);

    const o = (await order(cust)).data;
    assert.equal(o.driver_location, null);
    assert.equal(o.eta_minutes, null);
    await status(o.id, 'ready');
    assert.equal((await driver.call('POST', `/api/driver/orders/${o.id}/take`)).data.status, 'delivering');
    r = await driver.call('POST', '/api/driver/location', { lat: 6.14, lng: 1.23, accuracy: 12, heading: 90, speed: 5 });
    assert.deepEqual(r.data, { tracking: true, active_orders: 1 });
    // Envoi trop rapproché (< 3 s) : ignoré.
    r = await driver.call('POST', '/api/driver/location', { lat: 6.2, lng: 1.3 });
    assert.deepEqual(r.data, { tracking: true, active_orders: 1 });
    assert.equal(sql.prepare('SELECT lat FROM driver_locations').get().lat, 6.14);

    const seen = (await cust.call('GET', `/api/orders/${o.id}`)).data;
    assert.equal(seen.driver_location.lat, 6.14);
    assert.equal(seen.driver_location.lng, 1.23);
    assert.equal(seen.driver_location.accuracy, 12);
    assert.equal(seen.driver_location.heading, 90);
    assert.match(seen.driver_location.updated_at, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);
    const km = roadKm({ lat: 6.14, lng: 1.23 }, { lat: 6.13, lng: 1.22 });
    assert.equal(seen.eta_minutes, Math.ceil((km / 20) * 60) + 1);
    assert.ok(Number.isInteger(seen.eta_minutes) && seen.eta_minutes >= 1);
    assert.equal((await admin.call('GET', '/api/admin/orders?status=active')).data.find((x) => x.id === o.id).eta_minutes, seen.eta_minutes);

    // Position de plus de 10 min : plus montrée.
    sql.prepare(`UPDATE driver_locations SET updated_at = datetime('now', '-11 minutes')`).run();
    assert.equal((await cust.call('GET', `/api/orders/${o.id}`)).data.driver_location, null);
    await driver.call('POST', '/api/driver/location', { lat: 6.15, lng: 1.24 });
    assert.equal((await cust.call('GET', `/api/orders/${o.id}`)).data.driver_location.lat, 6.15);

    // « Livraison faite » : suivi terminé, position effacée.
    const done = (await driver.call('POST', `/api/driver/orders/${o.id}/delivered`)).data;
    assert.equal(done.driver_location, null);
    assert.equal(done.eta_minutes, null);
    assert.equal(sql.prepare('SELECT COUNT(*) AS n FROM driver_locations').get().n, 0);
    assert.deepEqual((await driver.call('POST', '/api/driver/location', { lat: 6.14, lng: 1.23 })).data, { tracking: false, active_orders: 0 });
  });

  await t.test('changement d\'opérateur : frais et total recalculés, refus', async () => {
    const cust = await customer();
    const o = (await order(cust, { payment_method: 'flooz' })).data;
    let r = await cust.call('POST', `/api/orders/${o.id}/payment-method`, { payment_method: 'mixx' });
    assert.equal(r.status, 200, JSON.stringify(r.data));
    assert.equal(r.data.payment_method, 'mixx');
    assert.equal(r.data.total, r.data.subtotal + r.data.delivery_fee + r.data.payment_fee);
    assert.ok(sql.prepare(`SELECT 1 FROM audit_logs WHERE action = 'payment_method_changed'`).get());
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/payment-method`, { payment_method: 'cash' })).status, 400);
    const other = await customer();
    assert.equal((await other.call('POST', `/api/orders/${o.id}/payment-method`, { payment_method: 'flooz' })).status, 404);

    // Demande de paiement en cours (non expirée) : refus.
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/payments`, { phone: '90111111' })).status, 201);
    r = await cust.call('POST', `/api/orders/${o.id}/payment-method`, { payment_method: 'flooz' });
    assert.equal(r.status, 400);
    assert.equal(r.data.error, 'Une demande de paiement est en cours : attendez son expiration');
    // Tentative expirée : changement possible.
    sql.prepare(`UPDATE payments SET expires_at = datetime('now', '-1 minute') WHERE order_id = ?`).run(o.id);
    r = await cust.call('POST', `/api/orders/${o.id}/payment-method`, { payment_method: 'flooz' });
    assert.equal(r.status, 200, JSON.stringify(r.data));
    assert.equal(r.data.payment_method, 'flooz');

    // Commande espèces, payée ou plus en attente : refus.
    const cash = (await order(cust)).data;
    assert.equal((await cust.call('POST', `/api/orders/${cash.id}/payment-method`, { payment_method: 'flooz' })).status, 400);
    sql.prepare(`UPDATE orders SET payment_status = 'paid' WHERE id = ?`).run(o.id);
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/payment-method`, { payment_method: 'mixx' })).status, 400);
    sql.prepare(`UPDATE orders SET payment_status = 'pending', status = 'confirmed' WHERE id = ?`).run(o.id);
    assert.equal((await cust.call('POST', `/api/orders/${o.id}/payment-method`, { payment_method: 'mixx' })).status, 400);
  });

  await t.test('journal des erreurs : rapports de l\'app, lecture par le gérant', async () => {
    assert.equal((await client().call('POST', '/api/client-errors', { message: 'Crash anonyme', platform: 'android' })).status, 204);
    const cust = await customer();
    const r = await cust.call('POST', '/api/client-errors', {
      message: 'x'.repeat(800), stack: 'trace', context: 'ecran_panier', app_version: '1.4.0', platform: 'android',
    });
    assert.equal(r.status, 204);
    assert.equal((await client().call('POST', '/api/client-errors', { stack: 'sans message' })).status, 400);
    assert.equal((await client().call('POST', '/api/client-errors', { message: 'ok', stack: 42 })).status, 400);
    // Jeton invalide : rapport accepté quand même, sans utilisateur.
    assert.equal((await client('jeton-invalide').call('POST', '/api/client-errors', { message: 'Jeton faux' })).status, 204);

    const list = (await admin.call('GET', '/api/admin/errors?source=app')).data;
    assert.equal(list.length, 3);
    assert.equal(list[0].message, 'Jeton faux', 'du plus récent au plus ancien');
    assert.equal(list[0].user_id, null);
    assert.equal(list[1].message.length, 500);
    assert.equal(list[1].user_id, cust.user.id);
    assert.equal(list[1].app_version, '1.4.0');
    assert.equal(list[1].context, 'ecran_panier');
    assert.equal(list[2].platform, 'android');
    assert.equal((await admin.call('GET', '/api/admin/errors?limit=1')).data.length, 1);
    assert.equal((await admin.call('GET', '/api/admin/errors?source=autre')).status, 400);
    assert.ok((await admin.call('GET', '/api/admin/errors?source=server')).data.every((e) => e.source === 'server'));

    // Plus de 20 erreurs de l'app en 10 min : alerte.
    for (let i = 0; i < 19; i++) await client().call('POST', '/api/client-errors', { message: `Crash ${i}` });
    assert.ok(sql.prepare(`SELECT 1 FROM alerts WHERE type = 'app_crashes'`).get(), 'alerte app_crashes');
  });

  await t.test('frais selon la distance : devis, commande, hors zone', async () => {
    let r = await admin.call('PUT', '/api/admin/settings', {
      delivery_fee: 500, delivery_fee_mode: 'distance', delivery_fee_per_km: 200, delivery_free_km: 1, delivery_max_km: 5,
      restaurant_lat: 6.13, restaurant_lng: 1.22,
    });
    assert.equal(r.status, 200, JSON.stringify(r.data));
    assert.equal(r.data.delivery_fee_mode, 'distance');
    for (const bad of [{ delivery_fee_mode: 'km' }, { delivery_fee_per_km: 60000 }, { delivery_free_km: -1 }, { delivery_max_km: 201 }]) {
      assert.equal((await admin.call('PUT', '/api/admin/settings', bad)).status, 400, JSON.stringify(bad));
    }
    const s = (await client().call('GET', '/api/settings')).data;
    assert.equal(s.delivery_fee_mode, 'distance');
    assert.equal(s.delivery_fee_per_km, 200);
    assert.equal(s.delivery_free_km, 1);
    assert.equal(s.delivery_max_km, 5);

    // Sans position : base.
    assert.deepEqual((await client().call('GET', '/api/delivery/quote')).data,
      { fee: 500, distance_km: null, mode: 'distance', within_zone: true, max_km: 5, message: null });
    assert.equal((await client().call('GET', '/api/delivery/quote?lat=abc&lng=1')).status, 400);
    const near = { lat: 6.13 + 2 / 111.195, lng: 1.22 }; // 2 km → 2,6 km par la route
    const q = (await client().call('GET', `/api/delivery/quote?lat=${near.lat}&lng=${near.lng}`)).data;
    assert.equal(q.distance_km, 2.6);
    assert.equal(q.fee, 500 + 2 * 200);
    const cust = await customer();
    const o = await order(cust, { location: near, delivery_fee: 0 });
    assert.equal(o.status, 201, JSON.stringify(o.data));
    assert.equal(o.data.delivery_fee, q.fee, 'montant du serveur, jamais celui de l\'app');
    assert.equal(o.data.delivery_distance_km, 2.6);
    const far = { lat: 6.13 + 5 / 111.195, lng: 1.22 };
    const out = await order(cust, { location: far });
    assert.equal(out.status, 400);
    assert.equal(out.data.error, 'Adresse hors de la zone de livraison (6,5 km, maximum 5 km)');
    const pickup = await order(cust, { mode: 'pickup', location: undefined });
    assert.equal(pickup.data.delivery_fee, 0);
    assert.equal(pickup.data.delivery_distance_km, null);
    await admin.call('PUT', '/api/admin/settings', { delivery_fee_mode: 'fixed', delivery_max_km: 0 });
  });

  await t.test('horaires d\'ouverture : état effectif, refus de commande', async () => {
    assert.equal((await admin.call('PUT', '/api/admin/settings', { opening_hours: { mon: [['22:00', '10:00']] } })).status, 400);
    assert.equal((await admin.call('PUT', '/api/admin/settings', { hours_enabled: 'oui' })).status, 400);
    const empty = Object.fromEntries(['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'].map((d) => [d, []]));
    let r = await admin.call('PUT', '/api/admin/settings', { hours_enabled: true, opening_hours: empty, is_open: true });
    assert.equal(r.status, 200);
    assert.equal(r.data.is_open, false, 'réponse au format de GET /api/settings');
    let s = (await client().call('GET', '/api/settings')).data;
    assert.equal(s.is_open, false);
    assert.equal(s.manual_open, true);
    assert.equal(s.hours_enabled, true);
    assert.deepEqual(s.opening_hours, empty);
    assert.equal(s.next_opening_at, null);
    const cust = await customer();
    let o = await order(cust);
    assert.equal(o.status, 400);
    assert.equal(o.data.error, 'Le restaurant est actuellement fermé');

    // Ouverture demain seulement : message de réouverture.
    const tomorrow = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'][(new Date().getUTCDay() + 1) % 7];
    await admin.call('PUT', '/api/admin/settings', { opening_hours: { ...empty, [tomorrow]: [['09:30', '24:00']] } });
    s = (await client().call('GET', '/api/settings')).data;
    assert.match(s.next_opening_at, /T09:30:00\.000Z$/);
    o = await order(cust);
    assert.equal(o.data.error, 'Le restaurant est fermé. Réouverture demain à 09:30');

    // Tous les jours 24 h/24 : ouvert, sans fermeture annoncée.
    await admin.call('PUT', '/api/admin/settings', { opening_hours: Object.fromEntries(Object.keys(empty).map((d) => [d, [['00:00', '24:00']]])) });
    s = (await client().call('GET', '/api/settings')).data;
    assert.equal(s.is_open, true);
    assert.equal(s.next_closing_at, null);
    assert.equal((await order(cust)).status, 201);

    // Interrupteur manuel fermé : prioritaire.
    await admin.call('PUT', '/api/admin/settings', { is_open: false });
    s = (await client().call('GET', '/api/settings')).data;
    assert.equal(s.is_open, false);
    assert.equal(s.manual_open, false);
    assert.equal(s.next_opening_at, null);
    await admin.call('PUT', '/api/admin/settings', { is_open: true, hours_enabled: false });
    assert.equal((await client().call('GET', '/api/settings')).data.is_open, true);
  });
});
