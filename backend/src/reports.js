/**
 * Rapports des ventes par période (gérant) :
 *  - GET /api/admin/reports?from=YYYY-MM-DD&to=YYYY-MM-DD           synthèse JSON
 *  - GET /api/admin/reports/export.csv?from=&to=                    une ligne par commande (CSV « ; », BOM UTF-8)
 *
 * Dates incluses, en UTC (= heure de Lomé). Défaut : les 30 derniers jours (aujourd'hui compris).
 * Commandes comptées = même règle que /api/admin/stats (non annulée ET (espèces OU payée)), hors remboursées ;
 * chiffre d'affaires = total des commandes comptées.
 * SQL paramétré uniquement : les dates validées sont passées en paramètres, jamais concaténées.
 */
const express = require('express');
const { db } = require('./db');
const { requireManager } = require('./auth');
const { audit } = require('./monitor');
const { h, httpError, csvCell } = require('./payments/util');

const MAX_DAYS = 366;
const DEFAULT_DAYS = 30;
const DAY_MS = 24 * 3600 * 1000;

// Commande comptée (alias o) : non annulée, encaissée ou à encaisser, non remboursée.
const COUNTED = `o.status != 'cancelled' AND (o.payment_method = 'cash' OR o.payment_status = 'paid') AND o.payment_status != 'refunded'`;
// Période (dates incluses) : created_at « YYYY-MM-DD HH:MM:SS » comparé en texte (index idx_orders_created).
const IN_PERIOD = `o.created_at >= ? AND o.created_at < date(?, '+1 day')`;
// Mode affiché : la vente au comptoir sur place est un mode à part.
const MODE_EXPR = `CASE WHEN o.dine_in = 1 THEN 'dine_in' ELSE o.mode END`;

/** « YYYY-MM-DD » strict et date réelle → millisecondes UTC ; null sinon. */
function parseDay(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const [y, m, d] = value.split('-').map(Number);
  const ms = Date.UTC(y, m - 1, d);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== m - 1 || back.getUTCDate() !== d) return null;
  return ms;
}
const dayString = (ms) => new Date(ms).toISOString().slice(0, 10);

/** Période demandée (from, to inclus) : 400 si une date est invalide, inversée ou trop longue. */
function parsePeriod(q = {}) {
  const given = (v) => v !== undefined && v !== '';
  let toMs;
  if (given(q.to)) {
    toMs = parseDay(q.to);
    if (toMs === null) throw httpError(400, 'Date de fin invalide (AAAA-MM-JJ)');
  }
  let fromMs;
  if (given(q.from)) {
    fromMs = parseDay(q.from);
    if (fromMs === null) throw httpError(400, 'Date de début invalide (AAAA-MM-JJ)');
  }
  if (toMs === undefined) toMs = fromMs !== undefined ? Math.max(fromMs, parseDay(dayString(Date.now()))) : parseDay(dayString(Date.now()));
  if (fromMs === undefined) fromMs = toMs - (DEFAULT_DAYS - 1) * DAY_MS;
  if (fromMs > toMs) throw httpError(400, 'La date de début doit précéder la date de fin');
  const days = Math.round((toMs - fromMs) / DAY_MS) + 1;
  if (days > MAX_DAYS) throw httpError(400, `Période trop longue (${MAX_DAYS} jours au plus)`);
  return { from: dayString(fromMs), to: dayString(toMs), days, fromMs };
}

const int = (v) => Math.round(Number(v) || 0);

/** Lignes complétées : chaque clé attendue figure, à 0 si absente. */
function fillBuckets(rows, field, keys) {
  return keys.map((key) => {
    const r = rows.find((x) => x.k === key);
    return { [field]: key, orders: int(r?.orders), revenue: int(r?.revenue) };
  });
}

function buildReport(period) {
  const { from, to } = period;
  const p = [from, to];
  const totals = db
    .prepare(`SELECT COUNT(*) AS orders, COALESCE(SUM(o.total), 0) AS revenue FROM orders o WHERE ${IN_PERIOD} AND ${COUNTED}`)
    .get(...p);
  const cancelled = db.prepare(`SELECT COUNT(*) AS n FROM orders o WHERE ${IN_PERIOD} AND o.status = 'cancelled'`).get(...p).n;
  // Commissions de l'agrégateur : paiements payés des commandes de la période.
  const feeRows = db
    .prepare(
      `SELECT o.payment_method AS k, COALESCE(SUM(pay.provider_fee), 0) AS fees
       FROM payments pay JOIN orders o ON o.id = pay.order_id
       WHERE pay.status = 'paid' AND ${IN_PERIOD} GROUP BY o.payment_method`,
    )
    .all(...p);
  const paymentFees = feeRows.reduce((s, r) => s + int(r.fees), 0);

  const group = (expr) => db
    .prepare(`SELECT ${expr} AS k, COUNT(*) AS orders, COALESCE(SUM(o.total), 0) AS revenue
              FROM orders o WHERE ${IN_PERIOD} AND ${COUNTED} GROUP BY k`)
    .all(...p);

  const byDriver = db
    .prepare(
      `SELECT o.driver_id, d.name, COUNT(*) AS deliveries,
              COALESCE(SUM(CASE WHEN o.payment_method = 'cash' AND o.payment_status != 'refunded' THEN o.total END), 0) AS cash_collected,
              AVG(CASE WHEN o.picked_up_at IS NOT NULL AND o.driver_delivered_at IS NOT NULL
                       THEN (julianday(o.driver_delivered_at) - julianday(o.picked_up_at)) * 1440 END) AS avg_minutes
       FROM orders o JOIN users d ON d.id = o.driver_id
       WHERE o.driver_id IS NOT NULL AND o.mode = 'delivery'
         AND (o.status = 'delivered' OR (o.status = 'delivering' AND o.driver_delivered_at IS NOT NULL))
         AND COALESCE(o.driver_delivered_at, o.received_at, o.updated_at) >= ?
         AND COALESCE(o.driver_delivered_at, o.received_at, o.updated_at) < date(?, '+1 day')
       GROUP BY o.driver_id ORDER BY deliveries DESC, d.name`,
    )
    .all(...p)
    .map((r) => ({
      driver_id: r.driver_id,
      name: r.name,
      deliveries: int(r.deliveries),
      cash_collected: int(r.cash_collected),
      avg_minutes: r.avg_minutes === null || r.avg_minutes === undefined ? null : Math.round(Number(r.avg_minutes) * 10) / 10,
    }));

  const dailyRows = db
    .prepare(`SELECT date(o.created_at) AS day, COUNT(*) AS orders, COALESCE(SUM(o.total), 0) AS revenue
              FROM orders o WHERE ${IN_PERIOD} AND ${COUNTED} GROUP BY day`)
    .all(...p);
  const byDay = new Map(dailyRows.map((r) => [r.day, r]));
  const daily = [];
  for (let i = 0; i < period.days; i++) {
    const day = dayString(period.fromMs + i * DAY_MS);
    const r = byDay.get(day);
    daily.push({ day, orders: int(r?.orders), revenue: int(r?.revenue) });
  }

  const topProducts = db
    .prepare(
      `SELECT oi.name, SUM(oi.quantity) AS quantity, SUM(oi.quantity * oi.unit_price) AS revenue
       FROM order_items oi JOIN orders o ON o.id = oi.order_id
       WHERE ${IN_PERIOD} AND ${COUNTED} GROUP BY oi.name ORDER BY quantity DESC, revenue DESC, oi.name LIMIT 10`,
    )
    .all(...p)
    .map((r) => ({ name: r.name, quantity: int(r.quantity), revenue: int(r.revenue) }));

  const orders = int(totals.orders);
  const revenue = int(totals.revenue);
  return {
    from,
    to,
    totals: { orders, revenue, avg_basket: orders ? Math.round(revenue / orders) : 0, cancelled: int(cancelled), payment_fees: paymentFees },
    by_channel: fillBuckets(group('o.source'), 'channel', ['app', 'counter']),
    by_mode: fillBuckets(group(MODE_EXPR), 'mode', ['delivery', 'pickup', 'dine_in']),
    by_payment: fillBuckets(group('o.payment_method'), 'method', ['cash', 'flooz', 'mixx'])
      .map((b) => ({ ...b, fees: int(feeRows.find((f) => f.k === b.method)?.fees) })),
    by_driver: byDriver,
    daily,
    top_products: topProducts,
  };
}

const CHANNEL_LABELS = { app: 'application', counter: 'comptoir' };
const MODE_LABELS = { delivery: 'livraison', pickup: 'à emporter', dine_in: 'sur place' };
const METHOD_LABELS = { cash: 'espèces', flooz: 'Flooz', mixx: 'Mixx' };
const PAYMENT_STATUS_LABELS = { unpaid: 'à encaisser', pending: 'en attente', paid: 'payé', failed: 'échoué', expired: 'expiré', refunded: 'remboursé' };
const STATUS_LABELS = {
  pending: 'en attente', confirmed: 'confirmée', preparing: 'en préparation', ready: 'prête', delivering: 'en livraison',
  delivered: 'livrée', cancelled: 'annulée',
};
const CSV_HEADER = ['id', 'date', 'heure', 'canal', 'mode', 'zone', 'client', 'telephone', 'articles', 'sous_total', 'livraison',
  'frais_paiement', 'total', 'paiement', 'statut_paiement', 'statut', 'livreur', 'commission_agregateur', 'net_restaurant'];

/** Lignes CSV (une par commande de la période, annulées comprises). */
function exportRows({ from, to }) {
  const orders = db
    .prepare(
      `SELECT o.*, ${MODE_EXPR} AS shown_mode,
              CASE WHEN o.source = 'counter' THEN COALESCE(o.customer_label, 'Comptoir') ELSE u.name END AS customer_name,
              d.name AS driver_name,
              (SELECT COALESCE(SUM(pay.provider_fee), 0) FROM payments pay WHERE pay.order_id = o.id AND pay.status = 'paid') AS commission,
              CASE WHEN ${COUNTED} THEN 1 ELSE 0 END AS counted
       FROM orders o JOIN users u ON u.id = o.user_id LEFT JOIN users d ON d.id = o.driver_id
       WHERE ${IN_PERIOD} ORDER BY o.created_at, o.id`,
    )
    .all(from, to);
  const items = new Map();
  if (orders.length) {
    for (const it of db
      .prepare(`SELECT oi.order_id, oi.name, oi.quantity FROM order_items oi JOIN orders o ON o.id = oi.order_id
                WHERE ${IN_PERIOD} ORDER BY oi.id`)
      .all(from, to)) {
      if (!items.has(it.order_id)) items.set(it.order_id, []);
      items.get(it.order_id).push(`${it.quantity}x ${it.name}`);
    }
  }
  return orders.map((o) => {
    const commission = int(o.commission);
    return [
      o.id,
      String(o.created_at).slice(0, 10),
      String(o.created_at).slice(11, 16),
      CHANNEL_LABELS[o.source] || o.source,
      MODE_LABELS[o.shown_mode] || o.shown_mode,
      o.delivery_zone_name || '',
      o.customer_name,
      o.phone,
      (items.get(o.id) || []).join(', '),
      int(o.subtotal),
      int(o.delivery_fee),
      int(o.payment_fee),
      int(o.total),
      METHOD_LABELS[o.payment_method] || o.payment_method,
      PAYMENT_STATUS_LABELS[o.payment_status] || o.payment_status,
      STATUS_LABELS[o.status] || o.status,
      o.driver_name || '',
      commission,
      // Net du restaurant : commande comptée → total − commission de l'agrégateur ; sinon rien d'encaissé.
      o.counted ? int(o.total) - commission : 0,
    ];
  });
}

function createReportsRouter() {
  const router = express.Router();

  router.get('/api/admin/reports', requireManager, h((req, res) => {
    res.json(buildReport(parsePeriod(req.query)));
  }));

  router.get('/api/admin/reports/export.csv', requireManager, h((req, res) => {
    const period = parsePeriod(req.query);
    const rows = exportRows(period);
    const lines = [CSV_HEADER.join(';'), ...rows.map((r) => r.map(csvCell).join(';'))];
    audit('report_exported', { userId: req.user.id, details: { from: period.from, to: period.to, count: rows.length }, ip: req.ip });
    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', `attachment; filename="ventes-${period.from}-${period.to}.csv"`);
    res.send(`﻿${lines.join('\r\n')}\r\n`);
  }));

  return router;
}

module.exports = { createReportsRouter, parsePeriod, parseDay, buildReport };
