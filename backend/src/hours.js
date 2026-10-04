/**
 * Horaires d'ouverture (module pur, sans base ni réseau).
 *
 * Réglages : is_open (interrupteur manuel), hours_enabled, opening_hours
 *   { "mon": [["10:00","22:00"]], ..., "sun": [] } — 0 à 3 plages par jour, "HH:MM", début < fin,
 *   la fin peut valoir "24:00". Lomé = UTC+0 : les heures sont lues en UTC.
 * Ouvert (effectif) = interrupteur manuel ET (horaires désactivés OU heure dans une plage).
 * Deux plages qui se touchent (22:00–24:00 puis 00:00–02:00 le lendemain) forment une seule ouverture.
 */
const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
const DAY_NAMES = { mon: 'lundi', tue: 'mardi', wed: 'mercredi', thu: 'jeudi', fri: 'vendredi', sat: 'samedi', sun: 'dimanche' };
const MAX_RANGES_PER_DAY = 3;
const DAY_MS = 24 * 60 * 60 * 1000;

/** Défaut : tous les jours 10:00–22:00. */
function defaultOpeningHours() {
  return Object.fromEntries(DAYS.map((d) => [d, [['10:00', '22:00']]]));
}

/** "HH:MM" → minutes depuis minuit (24:00 = 1440 seulement si allow24) ; null si invalide. */
function toMinutes(text, allow24 = false) {
  if (typeof text !== 'string') return null;
  const m = /^(\d{2}):(\d{2})$/.exec(text.trim());
  if (!m) return null;
  const hh = Number(m[1]);
  const mm = Number(m[2]);
  if (allow24 && hh === 24 && mm === 0) return 1440;
  if (hh > 23 || mm > 59) return null;
  return hh * 60 + mm;
}

/**
 * Valide des horaires envoyés par l'admin (objet ou texte JSON).
 * @returns {{ value?: object, error?: string }} value normalisé (les 7 jours, plages triées)
 */
function validateOpeningHours(raw) {
  let input = raw;
  if (typeof input === 'string') {
    try {
      input = JSON.parse(input);
    } catch {
      return { error: 'Horaires invalides' };
    }
  }
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { error: 'Horaires invalides' };
  const unknown = Object.keys(input).filter((k) => !DAYS.includes(k));
  if (unknown.length) return { error: `Jour inconnu dans les horaires : ${unknown[0]}` };
  const value = {};
  for (const day of DAYS) {
    const ranges = input[day] ?? [];
    if (!Array.isArray(ranges)) return { error: `Horaires du ${DAY_NAMES[day]} invalides` };
    if (ranges.length > MAX_RANGES_PER_DAY) return { error: `${MAX_RANGES_PER_DAY} plages au plus par jour (${DAY_NAMES[day]})` };
    const parsed = [];
    for (const r of ranges) {
      if (!Array.isArray(r) || r.length !== 2) return { error: `Plage invalide le ${DAY_NAMES[day]}` };
      const start = toMinutes(r[0]);
      const end = toMinutes(r[1], true);
      if (start === null || end === null) return { error: `Heure invalide le ${DAY_NAMES[day]} (format HH:MM)` };
      if (start >= end) return { error: `Le ${DAY_NAMES[day]}, l'ouverture doit précéder la fermeture` };
      parsed.push({ start, end, text: [r[0].trim(), r[1].trim()] });
    }
    parsed.sort((a, b) => a.start - b.start);
    for (let i = 1; i < parsed.length; i++) {
      if (parsed[i].start < parsed[i - 1].end) return { error: `Plages qui se chevauchent le ${DAY_NAMES[day]}` };
    }
    value[day] = parsed.map((p) => p.text);
  }
  return { value };
}

/** Lecture tolérante du réglage enregistré : défaut si absent ou invalide. */
function parseOpeningHours(raw) {
  if (raw === undefined || raw === null || raw === '') return defaultOpeningHours();
  const { value } = validateOpeningHours(raw);
  return value || defaultOpeningHours();
}

/** Plages absolues (ms) du jour de `now` sur 8 jours, fusionnées quand elles se touchent. */
function intervals(hours, now) {
  const midnight = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const list = [];
  for (let i = 0; i < 8; i++) {
    const dayStart = midnight + i * DAY_MS;
    // getUTCDay : 0 = dimanche → index dans DAYS (lundi d'abord).
    const key = DAYS[(new Date(dayStart).getUTCDay() + 6) % 7];
    for (const [s, e] of hours[key] || []) {
      const start = toMinutes(s);
      const end = toMinutes(e, true);
      if (start === null || end === null || start >= end) continue;
      list.push([dayStart + start * 60000, dayStart + end * 60000]);
    }
  }
  list.sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const iv of list) {
    const last = merged[merged.length - 1];
    if (last && iv[0] <= last[1]) last[1] = Math.max(last[1], iv[1]);
    else merged.push([...iv]);
  }
  return { merged, windowEnd: midnight + 8 * DAY_MS };
}

/**
 * État d'ouverture effectif.
 * @param settings { is_open (manuel), hours_enabled, opening_hours }
 * @returns {{ is_open: boolean, next_opening_at: string|null, next_closing_at: string|null }} dates ISO 8601 UTC
 */
function openState(settings, now = new Date()) {
  const manual = settings?.is_open !== false;
  if (!manual) return { is_open: false, next_opening_at: null, next_closing_at: null };
  if (!settings?.hours_enabled) return { is_open: true, next_opening_at: null, next_closing_at: null };
  const hours = settings.opening_hours && typeof settings.opening_hours === 'object'
    ? settings.opening_hours
    : parseOpeningHours(settings.opening_hours);
  const t = now.getTime();
  const { merged, windowEnd } = intervals(hours, now);
  const current = merged.find(([s, e]) => s <= t && t < e);
  if (current) {
    // Ouvert sans interruption sur toute la fenêtre (24 h/24) : pas d'heure de fermeture.
    return { is_open: true, next_opening_at: null, next_closing_at: current[1] >= windowEnd ? null : new Date(current[1]).toISOString() };
  }
  const next = merged.find(([s]) => s > t);
  return { is_open: false, next_opening_at: next ? new Date(next[0]).toISOString() : null, next_closing_at: null };
}

/** Message de refus d'une commande quand le restaurant est fermé. */
function closedMessage(state, now = new Date()) {
  if (!state?.next_opening_at) return 'Le restaurant est actuellement fermé';
  const at = new Date(state.next_opening_at);
  const dayIndex = (d) => Math.floor(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()) / DAY_MS);
  const diff = dayIndex(at) - dayIndex(now);
  const day = diff === 0 ? 'aujourd\'hui' : diff === 1 ? 'demain' : DAY_NAMES[DAYS[(at.getUTCDay() + 6) % 7]];
  const hhmm = `${String(at.getUTCHours()).padStart(2, '0')}:${String(at.getUTCMinutes()).padStart(2, '0')}`;
  return `Le restaurant est fermé. Réouverture ${day} à ${hhmm}`;
}

module.exports = { DAYS, defaultOpeningHours, validateOpeningHours, parseOpeningHours, openState, closedMessage };
