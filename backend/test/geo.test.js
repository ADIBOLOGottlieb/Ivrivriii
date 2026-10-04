// Proxy cartes (geo.js) : cache, validation, erreurs. Aucun appel au vrai réseau (fetch simulé).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ivrivrii-geo-'));
process.env.DB_PATH = path.join(dir, 'geo.db');
process.env.LOG_DIR = path.join(dir, 'logs');
process.env.LOG_CONSOLE = '0';
process.env.JWT_SECRET = 'secret-geo';

const { createGeoService, TtlCache, parsePair, shortAddress } = require('../src/geo');

/** Faux fetch : enregistre les URL et rejoue les réponses fournies. */
function fakeFetch(responder) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url: String(url), init });
    const r = await responder(String(url), calls.length);
    if (r instanceof Error) throw r;
    return { ok: (r.status ?? 200) < 400, status: r.status ?? 200, json: async () => r.body };
  };
  return { fn, calls };
}

const nominatimBody = {
  display_name: 'Rue 123, Tokoin, Lomé, Golfe, Maritime, Togo',
  address: { road: 'Rue 123', suburb: 'Tokoin', city: 'Lomé', country: 'Togo' },
};

test('adresse : URL Nominatim, User-Agent, cache par coordonnées à 4 décimales', async () => {
  const f = fakeFetch(() => ({ body: nominatimBody }));
  const geo = createGeoService({ fetch: f.fn, nominatimUrl: 'http://nominatim.test/', minIntervalMs: 0, userAgent: 'Test/1.0' });
  assert.equal(await geo.reverse({ lat: 6.13191, lng: 1.22281 }), 'Rue 123, Tokoin, Lomé');
  assert.equal(f.calls.length, 1);
  assert.match(f.calls[0].url, /^http:\/\/nominatim\.test\/reverse\?format=jsonv2&lat=6\.1319&lon=1\.2228/);
  assert.equal(f.calls[0].init.headers['User-Agent'], 'Test/1.0');
  assert.ok(f.calls[0].init.signal, 'délai d\'attente (AbortSignal)');
  // Même point à 4 décimales : servi depuis le cache.
  assert.equal(await geo.reverse({ lat: 6.131899, lng: 1.222801 }), 'Rue 123, Tokoin, Lomé');
  assert.equal(f.calls.length, 1);
  assert.equal(geo.addressCache.size, 1);
});

test('adresse : erreur réseau → null sans mise en cache ; « introuvable » → null en cache', async () => {
  let fail = true;
  const f = fakeFetch(() => (fail ? new Error('ECONNRESET') : { body: { error: 'Unable to geocode' } }));
  const geo = createGeoService({ fetch: f.fn, nominatimUrl: 'http://n.test', minIntervalMs: 0 });
  assert.equal(await geo.reverse({ lat: 1, lng: 1 }), null);
  assert.equal(geo.addressCache.size, 0);
  fail = false;
  assert.equal(await geo.reverse({ lat: 1, lng: 1 }), null);
  assert.equal(geo.addressCache.size, 1);
  await geo.reverse({ lat: 1, lng: 1 });
  assert.equal(f.calls.length, 2);
});

test('adresse : file d\'attente (intervalle minimal entre deux requêtes) et requêtes identiques groupées', async () => {
  const f = fakeFetch(() => ({ body: nominatimBody }));
  const geo = createGeoService({ fetch: f.fn, nominatimUrl: 'http://n.test', minIntervalMs: 120 });
  const t0 = Date.now();
  await Promise.all([geo.reverse({ lat: 1, lng: 1 }), geo.reverse({ lat: 1, lng: 1 }), geo.reverse({ lat: 2, lng: 2 }), geo.reverse({ lat: 3, lng: 3 })]);
  assert.equal(f.calls.length, 3, 'le même point n\'est demandé qu\'une fois');
  assert.ok(Date.now() - t0 >= 230, 'trois requêtes espacées de 120 ms');
});

test('itinéraire : OSRM (lng,lat), points convertis en [lat, lng], cache, 502 sur erreur', async () => {
  let mode = 'ok';
  const f = fakeFetch(() => {
    if (mode === 'down') return { status: 503, body: {} };
    if (mode === 'noroute') return { body: { code: 'NoRoute', routes: [] } };
    return { body: { code: 'Ok', routes: [{ distance: 1234.4, duration: 300.6, geometry: { coordinates: [[1.22, 6.13], [1.23, 6.14]] } }] } };
  });
  const geo = createGeoService({ fetch: f.fn, osrmUrl: 'http://osrm.test', minIntervalMs: 0 });
  const r = await geo.route({ lat: 6.13, lng: 1.22 }, { lat: 6.14, lng: 1.23 });
  assert.deepEqual(r, { distance_m: 1234, duration_s: 301, points: [[6.13, 1.22], [6.14, 1.23]] });
  assert.match(f.calls[0].url, /^http:\/\/osrm\.test\/route\/v1\/driving\/1\.2200,6\.1300;1\.2300,6\.1400\?overview=full&geometries=geojson$/);
  await geo.route({ lat: 6.13001, lng: 1.22001 }, { lat: 6.14, lng: 1.23 });
  assert.equal(f.calls.length, 1, 'cache');
  mode = 'down';
  await assert.rejects(geo.route({ lat: 1, lng: 1 }, { lat: 2, lng: 2 }), (e) => e.status === 502);
  mode = 'noroute';
  await assert.rejects(geo.route({ lat: 1, lng: 1 }, { lat: 2, lng: 2 }), (e) => e.status === 502);
  assert.equal(geo.routeCache.size, 1, 'les échecs ne sont pas mis en cache');
});

test('validation et cache borné', () => {
  assert.deepEqual(parsePair('6.13,1.22'), { lat: 6.13, lng: 1.22 });
  for (const bad of ['6.13', '91,0', '0,181', 'a,b', ',', '', undefined, '1,2,3']) assert.equal(parsePair(bad), null, String(bad));
  let now = 0;
  const c = new TtlCache(2, 1000, () => now);
  c.set('a', 1);
  c.set('b', 2);
  c.get('a'); // a récemment utilisé
  c.set('c', 3);
  assert.equal(c.get('b'), undefined, 'le moins récent sort');
  assert.equal(c.get('a'), 1);
  now = 1001;
  assert.equal(c.get('a'), undefined, 'expiré');
  assert.equal(shortAddress({ display_name: 'Lomé, Togo', address: {} }), 'Lomé, Togo');
});
