/**
 * Frais de livraison (module pur, sans base ni réseau) — source unique pour le devis
 * (GET /api/delivery/quote) et la création de commande (POST /api/orders).
 *
 * distance_km = distance à vol d'oiseau restaurant → client × 1,3 (détours des rues), 1 décimale.
 * Mode 'fixed'    : frais = delivery_fee.
 * Mode 'distance' : frais = delivery_fee (base, delivery_free_km inclus)
 *                   + ceil(max(0, km − delivery_free_km)) × delivery_fee_per_km, arrondi aux 50 F supérieurs.
 * Sans position du restaurant ou du client : frais = base, distance inconnue (null).
 * delivery_max_km > 0 : au-delà, adresse hors zone (commande refusée).
 * Mode 'zone'     : frais = fee de la zone (table delivery_zones, zones ACTIVES passées en paramètre) :
 *                   zone_id fourni et actif → cette zone ; sinon zone reconnue par la position (cercle
 *                   centre + rayon contenant le point, distance à vol d'oiseau, le plus petit rayon gagne) ;
 *                   aucune → within_zone false, fee 0 (commande refusée).
 */
const ROAD_FACTOR = 1.3;
const EARTH_RADIUS_KM = 6371;

/** Distance à vol d'oiseau (km) entre deux points { lat, lng }. */
function haversineKm(a, b) {
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

// null / '' ne valent pas 0 : une position absente reste absente.
const validPoint = (p) => !!p && p.lat != null && p.lng != null && p.lat !== '' && p.lng !== ''
  && Number.isFinite(Number(p.lat)) && Number.isFinite(Number(p.lng))
  && Math.abs(Number(p.lat)) <= 90 && Math.abs(Number(p.lng)) <= 180;

/** Distance estimée par la route (km, 1 décimale) ; null si une position manque. */
function roadKm(a, b) {
  if (!validPoint(a) || !validPoint(b)) return null;
  const km = haversineKm({ lat: Number(a.lat), lng: Number(a.lng) }, { lat: Number(b.lat), lng: Number(b.lng) }) * ROAD_FACTOR;
  return Math.round(km * 10) / 10;
}

/** 7.4 → « 7,4 » ; 10 → « 10 ». */
const frKm = (n) => String(n).replace('.', ',');

const ZONE_REQUIRED = 'Choisissez votre zone de livraison';
const ZONE_OUTSIDE = 'Adresse hors des zones de livraison';

const hasCircle = (z) => !!z && z.center_lat != null && z.center_lng != null && Number(z.radius_km) > 0;
const isActive = (z) => !!z && z.active !== false && z.active !== 0;

/** Zone active dont le cercle contient le point (le plus petit rayon gagne) ; null sinon. */
function zoneForPoint(zones, loc) {
  if (!validPoint(loc)) return null;
  const p = { lat: Number(loc.lat), lng: Number(loc.lng) };
  let best = null;
  for (const z of zones || []) {
    if (!isActive(z) || !hasCircle(z)) continue;
    const km = haversineKm(p, { lat: Number(z.center_lat), lng: Number(z.center_lng) });
    if (km <= Number(z.radius_km) + 1e-9 && (!best || Number(z.radius_km) < Number(best.radius_km))) best = z;
  }
  return best;
}

/** Devis en mode 'zone'. */
function zoneQuote(settings, loc, zones, zoneId) {
  const list = (zones || []).filter(isActive);
  const restaurant = { lat: settings?.restaurant_lat, lng: settings?.restaurant_lng };
  const id = zoneId == null || zoneId === '' ? null : Number(zoneId);
  const chosen = id !== null ? list.find((z) => Number(z.id) === id) : null;
  const zone = chosen || zoneForPoint(list, loc);
  const result = {
    fee: 0, mode: 'zone', zone_id: null, zone_name: null, within_zone: false, message: null,
    distance_km: roadKm(restaurant, loc), max_km: null,
  };
  if (zone) {
    return {
      ...result, fee: Math.max(0, Math.round(Number(zone.fee) || 0)), zone_id: Number(zone.id), zone_name: zone.name, within_zone: true,
    };
  }
  // Position donnée mais hors de tous les cercles (s'il en existe) : adresse hors zones.
  result.message = validPoint(loc) && list.some(hasCircle) ? ZONE_OUTSIDE : ZONE_REQUIRED;
  return result;
}

/**
 * @param settings { delivery_fee, delivery_fee_mode, delivery_fee_per_km, delivery_free_km, delivery_max_km,
 *                   restaurant_lat, restaurant_lng }
 * @param loc { lat, lng } du client, ou null
 * @param zones zones de livraison (mode 'zone' seulement ; les inactives sont ignorées)
 * @param zoneId zone choisie par le client (mode 'zone' seulement)
 * @returns {{ fee: number, distance_km: number|null, mode: 'fixed'|'distance'|'zone', within_zone: boolean,
 *             max_km: number|null, message: string|null }} + zone_id, zone_name en mode 'zone'
 */
function computeDeliveryFee(settings, loc, zones = [], zoneId = null) {
  if (settings?.delivery_fee_mode === 'zone') return zoneQuote(settings, loc, zones, zoneId);
  const base = Math.max(0, Math.round(Number(settings?.delivery_fee) || 0));
  const mode = settings?.delivery_fee_mode === 'distance' ? 'distance' : 'fixed';
  const maxRaw = Number(settings?.delivery_max_km) || 0;
  const maxKm = maxRaw > 0 ? maxRaw : null;
  const restaurant = { lat: settings?.restaurant_lat, lng: settings?.restaurant_lng };
  const km = roadKm(restaurant, loc);
  const result = { fee: base, distance_km: km, mode, within_zone: true, max_km: maxKm, message: null };
  if (km === null) return result;

  if (mode === 'distance') {
    const perKm = Math.max(0, Number(settings.delivery_fee_per_km) || 0);
    const freeKm = Math.max(0, Number(settings.delivery_free_km) || 0);
    // Arrondi à 1e-6 avant ceil : 3,3 − 0,3 ne doit pas donner 3,0000000000000004 → 4 km.
    const extra = Math.ceil(Math.round(Math.max(0, km - freeKm) * 1e6) / 1e6);
    result.fee = Math.ceil((base + extra * perKm) / 50) * 50;
  }
  if (maxKm !== null && km > maxKm) {
    result.within_zone = false;
    result.message = `Adresse hors de la zone de livraison (${frKm(km)} km, maximum ${frKm(maxKm)} km)`;
  }
  return result;
}

module.exports = { computeDeliveryFee, zoneForPoint, haversineKm, roadKm, ROAD_FACTOR, ZONE_REQUIRED, ZONE_OUTSIDE };
