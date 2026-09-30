# 🐔 Ivrivrii Chicken — Application de commande en ligne

Application mobile (Android / iOS) de commande pour le restaurant **Ivrivrii Chicken**, avec un espace **client** et un espace **administrateur** dans la même app. Le rôle du compte connecté détermine l'interface affichée.

```
backend/   API Node.js (Express + SQLite intégré à Node) — port 4000
mobile/    Application Flutter (client + admin), logo dans assets/images/logo.jpg
```

## Fonctionnalités

**Client**
- Inscription et connexion par numéro de téléphone
- Menu par catégories, recherche, section « Les plus demandés »
- Fiche produit, panier (quantités, balayer pour supprimer)
- Commande en livraison ou à emporter, adresse, note pour la cuisine
- Paiement : espèces, T-Money (Togocom), Flooz (Moov Africa)
- Suivi en temps réel (rafraîchi toutes les 15 s) avec étapes, annulation tant que la commande est en attente
- Historique des commandes, profil, appel direct du restaurant

**Admin**
- Tableau de bord : CA du jour, commandes, en cours, clients, graphique sur 7 jours, top ventes
- Commandes : filtres, passage à l'étape suivante en un clic, annulation, appel du client, alerte « Nouvelle commande »
- Menu : ajout, modification et suppression des produits ; photo prise avec l'appareil ou choisie dans la galerie ; rupture de stock en un clic ; mise en avant
- Catégories : ajout, modification, suppression, icône
- Paramètres : ouvert/fermé, frais de livraison, minimum de commande, téléphone et adresse
- Liste des clients (nombre de commandes, total dépensé)

## 1. Lancer le backend

Il faut Node.js 22.13 ou plus récent.

```bash
cd backend
npm install
npm start
```

Au premier lancement, l'API crée la base `ivrivrii.db`, un menu de démonstration et un **compte admin** :

| Téléphone    | Mot de passe |
|--------------|--------------|
| `0700000000` | `admin123`   |

⚠️ Changez ce mot de passe dès la première connexion (Plus → Mon compte administrateur). Vous pouvez aussi définir `ADMIN_PHONE` et `ADMIN_PASSWORD` avant le premier lancement.

Variables d'environnement : `PORT` (4000 par défaut), `JWT_SECRET` (**obligatoire en production**), `DB_PATH`, `ADMIN_PHONE`, `ADMIN_PASSWORD`.

## 2. Lancer l'application mobile

```bash
cd mobile
flutter pub get

# Émulateur Android (10.0.2.2 = le PC hôte)
flutter run

# Vrai téléphone sur le même Wi-Fi : utilisez l'IP locale du PC
flutter run --dart-define=API_URL=http://192.168.1.20:4000
```

Pour produire l'APK : `flutter build apk --release --dart-define=API_URL=https://votre-serveur.com`

L'icône de l'app est générée à partir du logo (`dart run flutter_launcher_icons`).

## Mise en production

- Hébergez le backend (VPS, Render, Railway…) derrière **HTTPS** et définissez `JWT_SECRET`.
- Retirez ensuite `android:usesCleartextTraffic="true"` (AndroidManifest) et `NSAllowsArbitraryLoads` (Info.plist). Ces options autorisent le HTTP local pendant le développement.
- Sauvegardez régulièrement `ivrivrii.db` et le dossier `uploads/`.
- Les paiements mobiles sont enregistrés comme moyen de paiement choisi, et le restaurant confirme par téléphone. Le paiement automatique (CinetPay, PayDunya…) se branche au moment de la création de la commande (`POST /api/orders`).

## API (résumé)

| Méthode | Route | Accès |
|---|---|---|
| POST | `/api/auth/register`, `/api/auth/login` | public |
| GET/PUT | `/api/auth/me` | connecté |
| GET | `/api/settings`, `/api/categories`, `/api/products` | public |
| POST/GET | `/api/orders` · GET `/api/orders/:id` · POST `/api/orders/:id/cancel` | client |
| GET | `/api/admin/stats`, `/api/admin/orders?status=`, `/api/admin/users` | admin |
| PATCH | `/api/admin/orders/:id/status` | admin |
| POST/PUT/DELETE | `/api/admin/products[/:id]`, `/api/admin/categories[/:id]` | admin |
| PATCH | `/api/admin/products/:id/availability` | admin |
| POST | `/api/admin/upload` (multipart `image`) | admin |
| PUT | `/api/admin/settings` | admin |

Les prix sont toujours recalculés par le serveur à partir du catalogue : un client ne peut pas modifier le montant de sa commande.
