/**
 * Packs de menu : un produit composé d'autres plats du catalogue (ex. demi-poulet + alloco + bissap),
 * vendu à son propre prix.
 *
 * - products.pack_items : JSON [{ product_id, quantity }] (NULL pour un plat simple) ;
 * - un pack n'est disponible que si TOUS ses plats le sont (et existent encore) ;
 * - pack_value = somme des prix des plats ; savings = pack_value − prix du pack (0 au minimum) ;
 * - une ligne de commande garde le détail du pack (order_items.details) pour la cuisine.
 */
const { db } = require('./db');

const MAX_COMPONENTS = 10;
const MAX_COMPONENT_QTY = 20;

function httpError(status, message) {
  const err = new Error(message);
  err.status = status;
  return err;
}

/** Lit pack_items stocké en base : tableau (éventuellement vide) de { product_id, quantity }. */
function storedItems(product) {
  if (!product?.pack_items) return [];
  try {
    const list = JSON.parse(product.pack_items);
    return Array.isArray(list)
      ? list.filter((i) => Number.isInteger(i?.product_id) && Number.isInteger(i?.quantity) && i.quantity > 0)
      : [];
  } catch {
    return [];
  }
}

const isPack = (product) => storedItems(product).length > 0;

/**
 * Valide le contenu d'un pack envoyé par l'admin.
 * @returns chaîne JSON à stocker, ou null (plat simple : absent, null ou tableau vide)
 */
function parsePackItems(raw, selfId = null) {
  if (raw === undefined || raw === null) return null;
  if (!Array.isArray(raw)) throw httpError(400, 'Contenu du pack invalide');
  if (raw.length === 0) return null;
  // Un plat qui fait déjà partie d'un pack ne peut pas devenir lui-même un pack (pas de pack imbriqué).
  if (selfId !== null) {
    const parent = db.prepare('SELECT name, pack_items FROM products WHERE pack_items IS NOT NULL AND id != ?').all(Number(selfId))
      .find((o) => storedItems(o).some((i) => i.product_id === Number(selfId)));
    if (parent) throw httpError(400, `Ce plat fait partie du pack « ${parent.name} » : il ne peut pas devenir un pack`);
  }
  const merged = new Map();
  for (const it of raw) {
    const id = Number(it?.product_id);
    const qty = Number(it?.quantity ?? 1);
    if (!Number.isInteger(id) || id <= 0) throw httpError(400, 'Plat du pack invalide');
    if (!Number.isInteger(qty) || qty < 1 || qty > MAX_COMPONENT_QTY) {
      throw httpError(400, `Quantité invalide dans le pack (1 à ${MAX_COMPONENT_QTY})`);
    }
    if (selfId !== null && id === Number(selfId)) throw httpError(400, 'Un pack ne peut pas se contenir lui-même');
    const p = db.prepare('SELECT id, name, pack_items FROM products WHERE id = ?').get(id);
    if (!p) throw httpError(400, 'Un plat du pack n\'existe plus');
    if (isPack(p)) throw httpError(400, `« ${p.name} » est déjà un pack : il ne peut pas faire partie d'un autre pack`);
    merged.set(id, (merged.get(id) || 0) + qty);
  }
  if (merged.size > MAX_COMPONENTS) throw httpError(400, `Un pack contient au plus ${MAX_COMPONENTS} plats différents`);
  for (const q of merged.values()) {
    if (q > MAX_COMPONENT_QTY) throw httpError(400, `Quantité invalide dans le pack (1 à ${MAX_COMPONENT_QTY})`);
  }
  return JSON.stringify([...merged].map(([product_id, quantity]) => ({ product_id, quantity })));
}

/**
 * Détail d'un pack à partir du catalogue (Map id → produit brut).
 * @returns {{ items: object[], value: number, componentsAvailable: boolean }}
 */
function packDetails(product, byId) {
  const items = [];
  let value = 0;
  let componentsAvailable = true;
  for (const { product_id: id, quantity } of storedItems(product)) {
    const c = byId.get(id);
    if (!c) {
      componentsAvailable = false;
      continue;
    }
    if (!c.available) componentsAvailable = false;
    value += c.price * quantity;
    items.push({ product_id: id, name: c.name, quantity, price: c.price, available: !!c.available });
  }
  return { items, value, componentsAvailable };
}

/** Catalogue complet indexé par id (une requête pour toute une liste). */
function catalogById() {
  return new Map(db.prepare('SELECT id, name, price, available FROM products').all().map((p) => [p.id, p]));
}

/**
 * Produit au format API. Ajoute is_pack, pack_items (avec noms et prix), pack_value, savings.
 * `available` d'un pack = disponible ET tous ses plats disponibles ; `available_raw` = interrupteur de l'admin.
 */
function presentProduct(p, byId = catalogById()) {
  const { pack_items: _stored, ...rest } = p;
  const base = { ...rest, available: !!p.available, popular: !!p.popular, is_pack: false, pack_items: [], pack_value: null, savings: 0 };
  if (!isPack(p)) return base;
  const d = packDetails(p, byId);
  return {
    ...base,
    is_pack: true,
    pack_items: d.items,
    pack_value: d.value,
    savings: Math.max(0, d.value - p.price),
    available_raw: !!p.available,
    available: !!p.available && d.componentsAvailable,
    components_available: d.componentsAvailable,
  };
}

/**
 * Vérifie qu'un pack commandé est disponible et renvoie le texte de détail de la ligne
 * (« 1× Demi-poulet braisé, 1× Alloco »), ou null pour un plat simple.
 */
function lineDetails(product) {
  if (!isPack(product)) return null;
  const byId = catalogById();
  const d = packDetails(product, byId);
  if (!d.componentsAvailable) throw httpError(400, `« ${product.name} » n'est plus disponible (un de ses plats est épuisé)`);
  return d.items.map((i) => `${i.quantity}× ${i.name}`).join(', ').slice(0, 300);
}

/** Crée une fois la catégorie « Packs » sur une base existante (l'admin peut ensuite la renommer ou la supprimer). */
function ensurePacksCategory() {
  const done = db.prepare(`SELECT value FROM settings WHERE key = 'packs_category_created'`).get();
  if (done) return;
  const exists = db.prepare(`SELECT id FROM categories WHERE name = 'Packs' COLLATE NOCASE`).get();
  if (!exists) {
    const position = (db.prepare('SELECT MAX(position) AS m FROM categories').get()?.m ?? -1) + 1;
    db.prepare(`INSERT INTO categories (name, icon, position) VALUES ('Packs', 'pack', ?)`).run(position);
  }
  db.prepare(`INSERT INTO settings (key, value) VALUES ('packs_category_created', '1')
              ON CONFLICT(key) DO UPDATE SET value = excluded.value`).run();
}

module.exports = { parsePackItems, presentProduct, catalogById, lineDetails, isPack, ensurePacksCategory, MAX_COMPONENTS };
