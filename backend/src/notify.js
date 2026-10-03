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
  delivering: () => 'Votre commande est en route avec le livreur.',
  delivered: (o) => (o.mode === 'pickup' ? 'Commande récupérée. Bon appétit !' : 'Commande livrée. Bon appétit !'),
  cancelled: () => 'Votre commande a été annulée.',
};

/** Changement de statut → client (+ livreurs quand une livraison devient disponible). */
function statusChanged(order, status) {
  const text = STATUS_TEXT[status];
  if (text) toUser(order.user_id, { title: `Commande n°${order.id}`, body: text(order), data: data(order) });
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

/** « Livraison faite » du livreur → client. */
function driverDelivered(order) {
  toUser(order.user_id, {
    title: `Commande n°${order.id}`,
    body: 'Le livreur indique vous avoir livré — confirmez la réception.',
    data: data(order),
  });
}

/** Paiement reçu → client et administrateurs. */
function paymentReceived(order, amount) {
  toUser(order.user_id, { title: 'Paiement reçu', body: `Paiement de ${amount} FCFA reçu pour la commande n°${order.id}. Merci !`, data: data(order) });
  toRole('admin', { title: 'Paiement reçu', body: `Commande n°${order.id} – ${amount} FCFA`, data: data(order) });
}

module.exports = { newOrder, statusChanged, readyForDrivers, deliveryAssigned, driverDelivered, paymentReceived };
