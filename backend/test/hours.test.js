// Horaires d'ouverture (module pur hours.js) : node --test. Lomé = UTC.
const test = require('node:test');
const assert = require('node:assert/strict');
const { openState, closedMessage, validateOpeningHours, parseOpeningHours, defaultOpeningHours } = require('../src/hours');

// 2026-10-05 est un lundi.
const at = (iso) => new Date(`${iso}Z`);
const week = (ranges) => Object.fromEntries(['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'].map((d) => [d, ranges]));
const settings = (opening_hours, extra = {}) => ({ is_open: true, hours_enabled: true, opening_hours, ...extra });

test('manuel fermé : fermé, aucune réouverture annoncée', () => {
  const s = openState(settings(week([['00:00', '24:00']]), { is_open: false }), at('2026-10-05T12:00:00'));
  assert.deepEqual(s, { is_open: false, next_opening_at: null, next_closing_at: null });
  assert.equal(closedMessage(s), 'Le restaurant est actuellement fermé');
});

test('horaires désactivés : ouvert selon le seul interrupteur', () => {
  const s = openState({ is_open: true, hours_enabled: false, opening_hours: week([]) }, at('2026-10-05T03:00:00'));
  assert.deepEqual(s, { is_open: true, next_opening_at: null, next_closing_at: null });
});

test('dans une plage : ouvert, heure de fermeture', () => {
  const s = openState(settings(defaultOpeningHours()), at('2026-10-05T12:00:00'));
  assert.equal(s.is_open, true);
  assert.equal(s.next_closing_at, '2026-10-05T22:00:00.000Z');
  assert.equal(s.next_opening_at, null);
  // Bornes : ouvert à 10:00 pile, fermé à 22:00 pile.
  assert.equal(openState(settings(defaultOpeningHours()), at('2026-10-05T10:00:00')).is_open, true);
  const closed = openState(settings(defaultOpeningHours()), at('2026-10-05T22:00:00'));
  assert.equal(closed.is_open, false);
  assert.equal(closed.next_opening_at, '2026-10-06T10:00:00.000Z');
  assert.equal(closedMessage(closed, at('2026-10-05T22:00:00')), 'Le restaurant est fermé. Réouverture demain à 10:00');
});

test('avant l\'ouverture : réouverture aujourd\'hui', () => {
  const s = openState(settings(defaultOpeningHours()), at('2026-10-05T08:30:00'));
  assert.equal(s.is_open, false);
  assert.equal(s.next_opening_at, '2026-10-05T10:00:00.000Z');
  assert.equal(closedMessage(s, at('2026-10-05T08:30:00')), 'Le restaurant est fermé. Réouverture aujourd\'hui à 10:00');
});

test('fermeture à 24:00 enchaînée avec 00:00 le lendemain : une seule ouverture', () => {
  const h = week([]);
  h.mon = [['18:00', '24:00']];
  h.tue = [['00:00', '02:00'], ['11:00', '14:00']];
  const s = openState(settings(h), at('2026-10-05T23:30:00'));
  assert.equal(s.is_open, true);
  assert.equal(s.next_closing_at, '2026-10-06T02:00:00.000Z');
  // 24:00 seul : fermeture à minuit.
  const h2 = week([]);
  h2.mon = [['18:00', '24:00']];
  assert.equal(openState(settings(h2), at('2026-10-05T23:59:00')).next_closing_at, '2026-10-06T00:00:00.000Z');
});

test('jour sans plage : réouverture le jour suivant ouvert (nom du jour)', () => {
  const h = week([['10:00', '22:00']]);
  h.tue = [];
  h.wed = [];
  const s = openState(settings(h), at('2026-10-05T23:00:00')); // lundi soir
  assert.equal(s.is_open, false);
  assert.equal(s.next_opening_at, '2026-10-08T10:00:00.000Z');
  assert.equal(closedMessage(s, at('2026-10-05T23:00:00')), 'Le restaurant est fermé. Réouverture jeudi à 10:00');
});

test('aucune plage de la semaine : fermé sans réouverture ; 24 h/24 : pas de fermeture', () => {
  const none = openState(settings(week([])), at('2026-10-05T12:00:00'));
  assert.deepEqual(none, { is_open: false, next_opening_at: null, next_closing_at: null });
  const always = openState(settings(week([['00:00', '24:00']])), at('2026-10-05T12:00:00'));
  assert.deepEqual(always, { is_open: true, next_opening_at: null, next_closing_at: null });
});

test('validation des horaires', () => {
  assert.ok(validateOpeningHours(week([['10:00', '14:00'], ['18:00', '24:00']])).value);
  const ok = validateOpeningHours({ mon: [['18:00', '22:00'], ['08:00', '12:00']] }).value;
  assert.deepEqual(ok.mon, [['08:00', '12:00'], ['18:00', '22:00']], 'plages triées');
  assert.deepEqual(ok.sun, [], 'jour absent = fermé');
  assert.ok(validateOpeningHours(JSON.stringify(week([]))).value, 'texte JSON accepté');
  for (const bad of [
    null, [], 'pas du json', { lundi: [] }, { mon: 'x' }, { mon: [['10:00']] },
    { mon: [['10:00', '09:00']] }, { mon: [['10:00', '10:00']] }, { mon: [['24:00', '24:00']] },
    { mon: [['9:00', '12:00']] }, { mon: [['10:00', '24:30']] }, { mon: [['10:60', '12:00']] },
    { mon: [['08:00', '12:00'], ['11:00', '14:00']] },
    { mon: [['01:00', '02:00'], ['03:00', '04:00'], ['05:00', '06:00'], ['07:00', '08:00']] },
  ]) {
    assert.ok(validateOpeningHours(bad).error, JSON.stringify(bad));
  }
  // Lecture tolérante : réglage abîmé → horaires par défaut.
  assert.deepEqual(parseOpeningHours('{abîmé'), defaultOpeningHours());
  assert.deepEqual(parseOpeningHours(undefined), defaultOpeningHours());
});
