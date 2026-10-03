// Pages légales publiques (CGU, confidentialité) et version des conditions à accepter.
const fs = require('fs');
const path = require('path');
const express = require('express');
const { getSettings } = require('./db');

const TERMS_VERSION = '2026-10';
const LEGAL_DIR = path.join(__dirname, '..', 'public', 'legal');
const PAGES = { cgu: 'cgu.html', confidentialite: 'confidentialite.html' };

const escapeHtml = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** Base publique : PUBLIC_URL si défini, sinon déduite de la requête, sinon chemins relatifs. */
function baseUrl(req) {
  const env = String(process.env.PUBLIC_URL || '').trim().replace(/\/+$/, '');
  if (env) return env;
  if (req && req.get) return `${req.protocol}://${req.get('host')}`;
  return '';
}

/** Réglages légaux exposés à l'app (GET /api/settings, GET /api/legal). */
function legalSettings(req) {
  const base = baseUrl(req);
  return { terms_version: TERMS_VERSION, terms_url: `${base}/legal/cgu`, privacy_url: `${base}/legal/confidentialite` };
}

function renderPage(name) {
  const s = getSettings();
  const style = fs.readFileSync(path.join(LEGAL_DIR, 'style.css'), 'utf8');
  return fs
    .readFileSync(path.join(LEGAL_DIR, PAGES[name]), 'utf8')
    .replace(/\{\{STYLE\}\}/g, () => style)
    .replace(/\{\{VERSION\}\}/g, TERMS_VERSION)
    .replace(/\{\{PHONE\}\}/g, () => escapeHtml(s.restaurant_phone))
    .replace(/\{\{ADDRESS\}\}/g, () => escapeHtml(s.restaurant_address));
}

const router = express.Router();

router.get('/api/legal', (req, res) => res.json(legalSettings(req)));

for (const name of Object.keys(PAGES)) {
  router.get(`/legal/${name}`, (_req, res) => {
    try {
      res.set({
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        'Cache-Control': 'public, max-age=300',
      });
      res.send(renderPage(name));
    } catch {
      res.status(500).type('text/plain').send('Page indisponible');
    }
  });
}

module.exports = { router, legalSettings, TERMS_VERSION };
