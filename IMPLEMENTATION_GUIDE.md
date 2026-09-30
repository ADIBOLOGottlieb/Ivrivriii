# Ivrivrii Chicken - Implémentation Complète

## Vue d'ensemble

L'application Ivrivrii Chicken est une solution mobile-first complète pour les commandes en ligne incluant:
- **Application mobile** (Flutter): Client + Admin en une seule app
- **Backend API** (Node.js/Express): Gestion des commandes, paiements, et monitoring
- **Paiement intégré** (KADEV PAY): Support Flooz + Mixx by Yas
- **Sécurité avancée**: Audit logging + détection d'anomalies

---

## 🎯 Nouvelles Fonctionnalités Implémentées

### 1. **Agrégateur de Paiement KADEV PAY**
- **Méthodes supportées**: Flooz, Mixx by Yas (Togo)
- **Modes opératoires**:
  - **Simulation** (sans identifiants): Test complet du flux paiement
  - **Production** (avec clés KADEV): Intégration réelle
- **Frais**: 2% automatiquement ajoutés à la facture client
- **Webhook**: Vérification signature HMAC-SHA512

**Fichier**: `backend/src/payments.js` (~9 KB)

### 2. **Localisation GPS pour Livraison**
- **Intégration Google Maps**: Sélection précise de la position
- **Stockage**: Latitude, Longitude, Précision (±m)
- **UI Flutter**: Écran dédié avec bouton "Ma position"

**Fichiers**:
- `mobile/lib/screens/client/gps_picker_screen.dart` (nouveau)
- `mobile/lib/screens/client/checkout_screen.dart` (mis à jour)

### 3. **Tutoriel Onboarding Animé**
- **4 pages** d'introduction pour nouveaux utilisateurs
- **Animation fluide**: Fade + Slide
- **Contenu**: Menu, recherche, localisation GPS, paiement

**Fichier**: `mobile/lib/screens/onboarding_screen.dart` (nouveau)

### 4. **Sécurité & Monitoring**
**Audit Logging** (`logger.js`):
- Tous les événements en JSON
- Masquage automatique des champs sensibles (password, token, secret, signature)
- Stockage en fichiers journaux quotidiens

**Monitoring** (`monitor.js`):
- **Détection pic de commandes**: Alertes si 10+ commandes en 10 min
- **Détection utilisateur lourd**: Alertes si 5+ commandes rapides
- **Suivi paiements échoués**: 5+ échecs = alerte
- **Détection brute-force**: 20+ tentatives de connexion en 15 min
- **Alertes dédupliquées**: Évite le spam

**Fichiers**:
- `backend/src/logger.js` (nouveau)
- `backend/src/monitor.js` (nouveau)

---

## 🗄️ Schéma de Base de Données

### Nouvelles Colonnes (table `orders`)
```sql
delivery_lat          REAL           -- Latitude GPS de livraison
delivery_lng          REAL           -- Longitude GPS de livraison
delivery_accuracy     REAL           -- Précision (mètres)
payment_fee           INTEGER        -- Frais appliqués (FCFA)
payment_status        TEXT           -- 'unpaid', 'pending', 'paid', 'failed'
payment_reference     TEXT           -- ID de transaction KADEV
payment_token         TEXT           -- Token temporaire pour page de paiement
paid_at               TIMESTAMP      -- Quand le paiement a été confirmé
```

### Nouvelles Tables
```sql
-- Enregistrement des transactions
CREATE TABLE payments (
  id INTEGER PRIMARY KEY,
  order_id INTEGER NOT NULL,
  amount INTEGER NOT NULL,
  status TEXT ('paid', 'failed', 'pending'),
  reference TEXT,
  updated_at TIMESTAMP
);

-- Journal d'audit (90 jours de rétention)
CREATE TABLE audit_logs (
  id INTEGER PRIMARY KEY,
  user_id INTEGER,
  action TEXT,
  details JSON,
  ip TEXT,
  created_at TIMESTAMP
);

-- Alertes de sécurité
CREATE TABLE alerts (
  id INTEGER PRIMARY KEY,
  type TEXT,
  severity TEXT ('info', 'warning', 'critical'),
  message TEXT,
  details JSON,
  resolved BOOLEAN DEFAULT 0,
  created_at TIMESTAMP
);
```

### Nouveaux Paramètres (table `settings`)
```
payment_fee_percent      2         -- Frais appliqués au client (%)
spike_min_orders        10         -- Seuil minimum pour pic de commandes
spike_factor             3         -- Multiplicateur de baseline
high_amount_alert   200000         -- Montant déclencheur alerte (FCFA)
```

---

## 🚀 Déploiement

### Backend

**1. Installation des dépendances**
```bash
cd backend
npm install
```

**2. Variables d'environnement** (`.env`)
```bash
# Serveur
PORT=4000
NODE_ENV=production
JWT_SECRET=votre-clé-secrète-très-longue

# Paiement (optionnel si simulation)
KADEV_PUBLIC_KEY=pk_xxx
KADEV_SECRET_KEY=sk_xxx
KADEV_WEBHOOK_SECRET=secret_webhook_xxx

# Journaux
LOG_DIR=./logs

# Localisation
TRUST_PROXY=1  # Si derrière proxy (Nginx, CloudFlare, etc.)
```

**3. Démarrage**
```bash
npm start
```

**Endpoints clés:**
- `GET /api/settings` → Paramètres (incluent payment_mode: 'test'|'live')
- `POST /api/orders` → Créer commande (accepte 'location': {lat, lng, accuracy})
- `GET /api/orders/:id` → Détail (inclut pay_url si paiement en attente)
- `POST /api/payments/kadev/webhook` → Webhook KADEV (signature vérifiée)
- `GET /api/admin/monitoring` → Dashboard sécurité + alertes

### Mobile (Flutter)

**1. Dépendances nouvelles**
```yaml
geolocator: ^11.1.0          # Localisation GPS
google_maps_flutter: ^2.10.0 # Maps interactives
```

**2. Configuration Android** (`android/app/src/main/AndroidManifest.xml`)
```xml
<!-- Permissions GPS -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />

<!-- Clé Google Maps -->
<meta-data
    android:name="com.google.android.geo.API_KEY"
    android:value="AIzaSy..." />
```

**3. Configuration iOS** (`ios/Runner/Info.plist`)
```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Nous utilisons votre position pour livrer précisément.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Nous utilisons votre position pour livrer précisément.</string>
```

**4. Build & Test**
```bash
cd mobile
flutter pub get
flutter run
```

---

## 🧪 Test du Flux de Paiement

### Simulation (sans identifiants)

**1. Créer une commande avec Flooz**
```bash
curl -X POST http://localhost:4000/api/orders \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "items": [{"product_id": 1, "quantity": 3}],
    "mode": "delivery",
    "address": "Tokoin",
    "phone": "90000001",
    "payment_method": "flooz",
    "location": {"lat": 6.1319, "lng": 1.2228}
  }'
```

**Réponse:**
```json
{
  "id": 5,
  "subtotal": 3000,
  "delivery_fee": 1000,
  "payment_fee": 80,
  "total": 4080,
  "payment_status": "pending",
  "payment_token": "test_abc123",
  "pay_url": "/pay/5?t=test_abc123"
}
```

**2. Accéder à la page de paiement**
```
http://localhost:4000/pay/5?t=test_abc123
```
→ Formulaire de simulation (MODE TEST en haut)

**3. Simuler un paiement réussi**
```bash
curl -X POST http://localhost:4000/pay/5/simulate \
  -d "result=paid"
```

**4. Vérifier le paiement**
```bash
curl http://localhost:4000/api/orders/5 \
  -H "Authorization: Bearer <token>"
```

**Réponse:**
```json
{
  "payment_status": "paid",
  "payment_reference": "TEST-1790772424794",
  "pay_url": null
}
```

---

## 🔒 Sécurité

### Audit Logging (JSON par jour)
**Fichier:** `backend/logs/app-2026-09-30.log`

Chaque ligne = 1 événement:
```json
{
  "time": "2026-09-30T12:46:25.671Z",
  "level": "info",
  "message": "http",
  "method": "POST",
  "path": "/api/orders",
  "status": 201,
  "ms": 14,
  "ip": "127.0.0.1",
  "user": 2
}
```

**Champs masqués automatiquement:**
- password, token, secret, authorization, signature → `[masqué]`

### Monitoring Dashboard
**Endpoint:** `GET /api/admin/monitoring`

```json
{
  "payment": {"provider": "simulation", "mode": "test"},
  "orders": {
    "last10min": 8,
    "baselinePer10min": 0.5,
    "lastHour": 42
  },
  "payments": {
    "paid24h": 12,
    "failed24h": 2,
    "pending": 3
  },
  "security": {
    "loginFailures1h": 0,
    "adminLogins24h": 5
  },
  "http": {
    "requests": 234,
    "errors": 2,
    "clientErrors": 11,
    "perMinute": [3, 4, 2, ...]
  },
  "alerts": [
    {
      "type": "order_spike",
      "severity": "warning",
      "message": "Pic de commandes : 10 en 10 min"
    }
  ]
}
```

---

## 📱 Interface Mobile

### Checkout amélioré
1. **Mode retrait/livraison** → RadioButtons
2. **Adresse de livraison** → TextForm
3. **📍 Localisation GPS** → ✨ Nouveau écran Maps interactif
4. **Téléphone** → TextForm
5. **Note** → Optionnel
6. **Moyen de paiement** → Flooz, Mixx, Espèces
7. **Résumé** → Avec frais de paiement affichés

### Onboarding (1ère visite)
Écran 1: Bienvenue 🍗
Écran 2: Menu & Recherche 🔍
Écran 3: Localisation GPS 📍
Écran 4: Paiement 💳

---

## 🐛 Dépannage

### 1. "Frais de paiement" apparaissent deux fois
**Solution:** Vérifier que `_payment != 'cash'` avant d'afficher

### 2. Google Maps ne s'affiche pas
**Causes possibles:**
- Clé API manquante ou invalide
- Permissions Android/iOS non accordées
- Émulateur sans Google Play Services

**Solution:**
```bash
# Android: Tester sur device réel ou émulateur avec Play Services
# iOS: Vérifier Info.plist
```

### 3. GPS ne demande pas la permission
**Solution:** Tester sur device réel (émulateur peut être limité)

### 4. "Paiement pas encore reçu" lors de la préparation
**C'est attendu** pour les paiements mobile money (Flooz, Mixx).
L'admin ne peut confirmer que si `payment_status = 'paid'`.

### 5. Moniteur n'envoie pas d'alertes
**Vérifier:**
```bash
# Les moniteurs tournent toutes les 60 secondes
# Chercher dans les logs
grep "alerte" backend/logs/app-*.log

# Vérifier les seuils
SELECT * FROM settings WHERE key IN ('spike_min_orders', 'spike_factor');
```

---

## 📊 Exemple de Scénario Complet

**Scénario:** Client passe une commande livrée par Flooz

### Client (Mobile)
1. Connexion → Authentification JWT
2. Parcourt menu (recherche visuelle + barre)
3. Ajoute 3 plats au panier
4. Clique "Finaliser la commande"
5. Mode livraison sélectionné
6. Saisit adresse "Tokoin, Bè"
7. **Clique le bouton "📍 Localisation"**
   - Écran Google Maps s'ouvre
   - Client clique sa position → Marker ajouté
   - Client clique "Confirmer cette localisation"
8. Saisit son numéro +228 90000001
9. Choisit Flooz comme moyen de paiement
   - **Affichage:** Frais 2% calculés automatiquement
   - **Total:** 3000 + 1000 + 80 = 4080 FCFA
10. Clique "Commander • 4080 FCFA"
    - Commande créée: `{id: 5, payment_status: 'pending'}`
    - Lien de paiement: `/pay/5?t=token_xyz`

### Agrégateur de Paiement (KADEV)
1. Client clique "Passer au paiement"
2. Redirection vers `/pay/5?t=token_xyz`
3. **Mode simulation:** Formulaire simple
   - "MODE TEST" affiché en haut
   - 2 boutons: "Succès" ou "Échec"
4. Client clique "Succès"
5. POST /pay/5/simulate → payment_status = 'paid'
6. Redirection vers `/pay/5/return` (succès)

### Admin (Mobile)
1. Dashboard → Voir la commande n°5 en attente
2. Cliquer sur la commande
   - Status: **PENDING** (pas encore commencée)
   - Paiement: **PAYÉ** ✓
3. Cliquer "Confirmer" → Status = **CONFIRMED**
4. Faire cuire le poulet...
5. Cliquer "Prêt" → Status = **READY**
6. Cliquer "En livraison" → Status = **DELIVERING**
   - GPS du client affichée (6.1319, 1.2228)
   - Livreur navigue avec Google Maps
7. Client reçoit la livraison
8. Cliquer "Livrée" → Status = **DELIVERED**

### Backend (Logs & Monitoring)
- **Audit:** order_created, order_status x4, payment_paid
- **Monitoring:** Aucune alerte (1 commande = normal)
- **Paiement:** Transaction enregistrée, webhook confirmé

---

## 🔧 Configuration Avancée

### Activer mode LIVE (production)

**Backend `.env`:**
```bash
KADEV_PUBLIC_KEY=pk_live_xxxxx
KADEV_SECRET_KEY=sk_live_xxxxx
KADEV_WEBHOOK_SECRET=secret_live_xxxxx
```

**Redémarrer:** `npm start`

**Vérifier:**
```bash
curl http://localhost:4000/api/settings | jq .payment_mode
# → "live"
```

### Ajuster les seuils de sécurité

**Admin → Paramètres:**
```
Frais de paiement (%):         2
Seuil pic de commandes:       10
Multiplicateur (baseline):     3
Montant alerte élevé (FCFA): 200000
```

Ou SQL:
```sql
INSERT INTO settings VALUES ('spike_min_orders', '5')
  ON CONFLICT(key) DO UPDATE SET value = '5';
```

---

## 📞 Support

**Erreurs API:**
- 400: Données invalides (Vérifier le format JSON)
- 401: Non authentifié (Vérifier le token JWT)
- 403: Pas admin (Réservé administrateurs)
- 429: Trop de requêtes (Rate limiting activé)
- 500: Erreur serveur (Consulter `backend/logs/`)

**Erreurs Firebase (paiement):**
- `webhook_invalid_signature`: Signature KADEV incorrecte
- `amount_mismatch`: Montant ne correspond pas (alerte critique)

---

**Version:** 1.0.0 (30 septembre 2026)
**Dernière mise à jour:** Intégration KADEV + GPS + Monitoring
