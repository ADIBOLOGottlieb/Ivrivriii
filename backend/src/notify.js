/**
 * Notifications push des événements de commande (textes en un seul endroit).
 * S'appuie sur push.js (notifyUser / notifyRole) ; ne lève jamais et n'attend jamais l'envoi.
 */
const { log } = require('./logger');

let push = null;
function pushModule() {
  if (push) return push;
  try {
    push = require('./push');
  } catch (err) {
    push = { notifyUser: async () => {}, notifyRole: async () => {} };
    log.warn('push.js indisponible : notifications désactivées', { error: err.message });
  }
  return push;
}

const data = (order, type = 'order') => ({ type, order_id: String(order.id) });

function fire(fn, ...args) {
  try {
    Promise.resolve(fn(...args)).catch((err) => log.warn('notification', { error: err?.message }));
  } catch (err) {
    log.warn('notification', { error: err?.message });
  }
}
const toUser = (userId, message) => userId && fire((...a) => pushModule().notifyUser(...a), userId, message);
const toRole = (role, message) => fire((...a) => pushModule().notifyRole(...a), role, message);

/** Nouvelle commande → administrateurs. */
function newOrder(order) {
  toRole('admin', {
    title: `Nouvelle commande n°${order.id}`,
    body: `${order.customer_name || 'Client'} – ${order.total} FCFA (${order.mode === 'delivery' ? 'livraison' : 'à emporter'})`,
    data: data(order),
  });
}

const STATUS_TEXT = {
  confirmed: () => 'Votre commande est confirmée.',
  preparing: () => 'Votre commande est en préparation.',
  ready: (o) => (o.mode === 'pickup' ? 'Votre commande est prête : vous pouvez venir la chercher.' : 'Votre commande est prête, un livreur va la prendre en charge.'),
  delivering: (_o, extra) => `Votre commande est en route avec ${extra?.driverName || 'le livreur'}. Suivez-la en direct dans l'app.`,
  delivered: (o) => (o.mode === 'pickup' ? 'Commande récupérée. Bon appétit !' : 'Commande livrée. Bon appétit !'),
  cancelled: () => 'Votre commande a été annulée.',
};

/**
 * Changement de statut → client (+ livreurs quand une livraison devient disponible).
 * extra.driverName : nom du livreur (statut 'delivering').
 */
function statusChanged(order, status, extra = {}) {
  const text = STATUS_TEXT[status];
  // Vente au comptoir : la commande appartient au caissier, pas de notification « client ».
  if (text && order.source !== 'counter') toUser(order.user_id, { title: `Commande n°${order.id}`, body: text(order, extra), data: data(order) });
  if (status === 'ready' && order.mode === 'delivery') readyForDrivers(order);
}

/** Commande prête sans livreur → tous les livreurs. */
function readyForDrivers(order) {
  toRole('driver', {
    title: 'Nouvelle livraison disponible',
    body: `Commande n°${order.id}${order.address ? ` – ${String(order.address).slice(0, 80)}` : ''}`,
    data: data(order, 'delivery'),
  });
}

/** Livraison attribuée par l'admin → livreur. */
function deliveryAssigned(order, driverId) {
  toUser(driverId, {
    title: 'Livraison attribuée',
    body: `Commande n°${order.id}${order.address ? ` – ${String(order.address).slice(0, 80)}` : ''}`,
    data: data(order, 'delivery'),
  });
}

/** Livraison prise par un livreur → administrateurs. */
function driverTook(order, driverName) {
  toRole('admin', {
    title: 'Livraison prise en charge',
    body: `${driverName || 'Un livreur'} a pris la livraison n°${order.id}`,
    data: data(order),
  });
}

/** « Livraison faite » du livreur → client et administrateurs. */
function driverDelivered(order, driverName = order.driver_name) {
  toUser(order.user_id, {
    title: `Commande n°${order.id}`,
    body: 'Le livreur indique vous avoir livré — confirmez la réception.',
    data: data(order),
  });
  toRole('admin', {
    title: 'Livraison faite',
    body: `Commande n°${order.id} livrée par ${driverName || 'le livreur'}`,
    data: data(order),
  });
}

/** « Reçu » du client → administrateurs. */
function deliveryReceived(order) {
  toRole('admin', {
    title: 'Réception confirmée',
    body: `Commande n°${order.id} : réception confirmée par le client`,
    data: data(order),
  });
}

/** Paiement reçu → client et administrateurs. */
function paymentReceived(order, amount) {
  if (order.source !== 'counter') toUser(order.user_id, { title: 'Paiement reçu', body: `Paiement de ${amount} FCFA reçu pour la commande n°${order.id}. Merci !`, data: data(order) });
  toRole('admin', { title: 'Paiement reçu', body: `Commande n°${order.id} – ${amount} FCFA`, data: data(order) });
}

module.exports = {
  newOrder, statusChanged, readyForDrivers, deliveryAssigned, driverTook, driverDelivered, deliveryReceived, paymentReceived,
};
