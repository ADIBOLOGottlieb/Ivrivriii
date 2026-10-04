// Frais de livraison selon la distance (module pur delivery-fee.js) : node --test.
const test = require('node:test');
const assert = require('node:assert/strict');
const { computeDeliveryFee, haversineKm, roadKm } = require('../src/delivery-fee');

const RESTO = { lat: 6.1319, lng: 1.2228 }; // Lomé
// Point à ≈ 1 km de distance par degré : 1° de latitude ≈ 111,19 km.
const north = (km) => ({ lat: RESTO.lat + km / 111.195, lng: RESTO.lng });

const base = {
  delivery_fee: 1000,
  delivery_fee_mode: 'distance',
  delivery_fee_per_km: 200,
  delivery_free_km: 2,
  delivery_max_km: 0,
  restaurant_lat: RESTO.lat,
  restaurant_lng: RESTO.lng,
};

test('haversine et distance par la route (× 1,3, 1 décimale)', () => {
  assert.ok(Math.abs(haversineKm(RESTO, north(10)) - 10) < 0.01);
  assert.equal(roadKm(RESTO, north(10)), 13);
  assert.equal(roadKm(RESTO, null), null);
  assert.equal(roadKm({ lat: null, lng: null }, north(1)), null, 'null ne vaut pas 0');
  assert.equal(roadKm(RESTO, { lat: 95, lng: 0 }), null);
});

test('mode fixe : toujours la base, distance renseignée si connue', () => {
  const r = computeDeliveryFee({ ...base, delivery_fee_mode: 'fixed' }, north(10));
  assert.equal(r.fee, 1000);
  assert.equal(r.mode, 'fixed');
  assert.equal(r.distance_km, 13);
  assert.equal(r.within_zone, true);
  assert.equal(r.max_km, null);
  assert.equal(r.message, null);
  // Mode inconnu → fixe.
  assert.equal(computeDeliveryFee({ ...base, delivery_fee_mode: 'autre' }, north(10)).mode, 'fixed');
});

test('mode distance : base + km au-delà des km inclus × tarif, arrondi aux 50 F supérieurs', () => {
  // 1 km réel → 1,3 km ≤ 2 km inclus : base seule.
  assert.equal(computeDeliveryFee(base, north(1)).fee, 1000);
  // 10 km réels → 13 km : 11 km facturés → 1000 + 2200 = 3200.
  const r = computeDeliveryFee(base, north(10));
  assert.equal(r.distance_km, 13);
  assert.equal(r.fee, 3200);
  // Km entamé : 2,1 km → 1 km facturé.
  const k = computeDeliveryFee({ ...base, delivery_fee_per_km: 130 }, north(2.1 / 1.3));
  assert.equal(k.distance_km, 2.1);
  assert.equal(k.fee, 1150, '1000 + 130 = 1130 → arrondi à 1150');
  // Arrondi à 50 sur une base non ronde.
  assert.equal(computeDeliveryFee({ ...base, delivery_fee: 1010, delivery_fee_per_km: 0 }, north(10)).fee, 1050);
  // Pas d'erreur flottante : 3,3 − 0,3 = 3 km facturés, pas 4.
  const f = computeDeliveryFee({ ...base, delivery_free_km: 0.3, delivery_fee_per_km: 100 }, north(3.3 / 1.3));
  assert.equal(f.distance_km, 3.3);
  assert.equal(f.fee, 1300);
});

test('sans position du restaurant ou du client : base, distance inconnue', () => {
  const noResto = computeDeliveryFee({ ...base, restaurant_lat: null, restaurant_lng: null }, north(10));
  assert.deepEqual(noResto, { fee: 1000, distance_km: null, mode: 'distance', within_zone: true, max_km: null, message: null });
  const noClient = computeDeliveryFee({ ...base, delivery_max_km: 5 }, null);
  assert.equal(noClient.fee, 1000);
  assert.equal(noClient.distance_km, null);
  assert.equal(noClient.within_zone, true, 'zone non vérifiable : accepté');
  assert.equal(noClient.max_km, 5);
});

test('hors zone : within_zone false et message', () => {
  const r = computeDeliveryFee({ ...base, delivery_max_km: 10 }, north(10));
  assert.equal(r.within_zone, false);
  assert.equal(r.max_km, 10);
  assert.equal(r.message, 'Adresse hors de la zone de livraison (13 km, maximum 10 km)');
  const dec = computeDeliveryFee({ ...base, delivery_max_km: 7.5 }, north(6));
  assert.equal(dec.message, 'Adresse hors de la zone de livraison (7,8 km, maximum 7,5 km)');
  // Exactement à la limite : accepté.
  assert.equal(computeDeliveryFee({ ...base, delivery_max_km: 13 }, north(10)).within_zone, true);
  // 0 = illimité.
  assert.equal(computeDeliveryFee({ ...base, delivery_max_km: 0 }, north(100)).within_zone, true);
});
