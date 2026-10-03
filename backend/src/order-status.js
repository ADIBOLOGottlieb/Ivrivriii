/**
 * Machine d'états des commandes (module pur, sans base : testable seul).
 *
 * Statuts : pending → confirmed → preparing → ready → (delivering →) delivered, ou cancelled.
 * Qui fait quoi :
 *  - admin (PATCH /api/admin/orders/:id/status) : table ADMIN_TRANSITIONS ci-dessous ;
 *  - livreur : ready → delivering (prise / attribution, livraison uniquement), delivering → ready (rendue) ;
 *  - client : pending → cancelled (non payée), delivering → delivered (« Reçu » après « Livraison faite ») ;
 *  - tâches : pending → cancelled (mobile money non payée), delivering → delivered (délai sans « Reçu »).
 * 'delivered' et 'cancelled' sont définitifs.
 */

const ORDER_STATUSES = ['pending', 'confirmed', 'preparing', 'ready', 'delivering', 'delivered', 'cancelled'];
const FINAL_STATUSES = ['delivered', 'cancelled'];
const KITCHEN = ['pending', 'confirmed', 'preparing', 'ready'];

/** Transitions possibles pour l'administrateur (avant les règles qui dépendent de la commande). */
const ADMIN_TRANSITIONS = {
  pending: ['confirmed', 'preparing', 'ready', 'cancelled'],
  confirmed: ['pending', 'preparing', 'ready', 'cancelled'],
  preparing: ['pending', 'confirmed', 'ready', 'cancelled'],
  // ready → delivered : retrait sur place seulement ; ready → delivering : jamais ici (prise / attribution d'un livreur).
  ready: ['pending', 'confirmed', 'preparing', 'delivered', 'cancelled'],
  // Retour en cuisine : le livreur est retiré (refusé après « Livraison faite »).
  delivering: ['pending', 'confirmed', 'preparing', 'ready', 'delivered', 'cancelled'],
  delivered: [],
  cancelled: [],
};

/**
 * Vérifie un changement de statut demandé par l'administrateur.
 * @param {{ status: string, mode: string, driver_id?: number|null, driver_delivered_at?: string|null }} order
 * @param {string} to
 * @returns {string|null} message d'erreur (400) ou null si autorisé
 */
function adminTransitionError(order, to) {
  if (!ORDER_STATUSES.includes(to)) return 'Statut invalide';
  const from = order.status;
  if (from === to) return null; // sans effet
  if (from === 'delivered') return 'Commande déjà livrée : son statut ne peut plus changer';
  if (from === 'cancelled') return 'Commande annulée : son statut ne peut plus changer';
  if (to === 'delivering') {
    return order.mode === 'pickup'
      ? 'Commande à emporter : pas de livraison (elle passe de « Prête » à « Livrée » quand le client la retire)'
      : 'Attribuez un livreur pour passer la commande en livraison';
  }
  if (to === 'delivered' && order.mode === 'delivery' && from !== 'delivering') {
    return 'Commande en livraison : elle doit d\'abord être prise par un livreur';
  }
  if (from === 'delivering' && KITCHEN.includes(to) && order.driver_delivered_at) {
    return 'Le livreur a déjà indiqué « Livraison faite » : retour en arrière impossible';
  }
  if (!(ADMIN_TRANSITIONS[from] || []).includes(to)) return `Passage de « ${from} » à « ${to} » impossible`;
  return null;
}

const isFinal = (status) => FINAL_STATUSES.includes(status);

module.exports = { ORDER_STATUSES, FINAL_STATUSES, ADMIN_TRANSITIONS, adminTransitionError, isFinal };
