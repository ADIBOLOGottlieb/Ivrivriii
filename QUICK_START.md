# Démarrage Rapide - Ivrivrii Chicken

## ⏱️ 5 minutes pour démarrer

### 1. Backend (Node.js)

```bash
cd backend
npm install
npm start
```

**Résultat:**
```
🐔 API Ivrivrii Chicken sur http://localhost:4000
```

**Vérifier:**
```bash
curl http://localhost:4000/api/health
# → {"status":"ok","uptime":2}
```

**Admin par défaut:**
- Téléphone: `0700000000`
- Mot de passe: `admin123`

---

### 2. Mobile (Flutter)

```bash
cd mobile
flutter pub get
flutter run
```

**Émulateur Android:**
- Choisir un device avec Google Play Services (pour Maps)
- Accepter les permissions (GPS, etc.)

---

### 3. Test Complet (Simulation)

#### Étape A: Créer un compte client
1. Cliquer "Créer un compte"
2. Nom: "Kossi"
3. Téléphone: "90000001"
4. Mot de passe: "secret123"

#### Étape B: Parcourir le menu
1. Voir la page d'accueil
2. Rechercher "poulet" (barre visible en haut)
3. Sélectionner une catégorie (épices 🌶️)
4. Ajouter 3 plats au panier

#### Étape C: Checkout avec GPS
1. Panier → "Finaliser la commande"
2. Mode: "Livraison" ✓
3. Adresse: "Tokoin, Bè"
4. **Cliquer "📍 Localisation"** → Maps s'ouvre
5. Cliquer la position → Marker apparaît
6. Cliquer "Confirmer cette localisation"
7. Téléphone: (pré-rempli)
8. Paiement: "Flooz" → **Frais affichés (2%)**
9. "Commander" → Commande créée

#### Étape D: Paiement (Simulation)
1. Dialogue: "Commande reçue"
2. "Suivre ma commande"
3. Voir la commande avec lien "Payer"
4. Cliquer "Payer"
5. Page de paiement: "MODE TEST" écrit en haut
6. Sélectionner "Succès"
7. Confirmation: "Paiement réussi" ✓

#### Étape E: Admin confirme la commande
1. Switch vers compte **admin**: Tirer vers la droite (AppBar)
2. Aller à "Commandes"
3. Voir la commande "Kossi • 4080 FCFA"
4. Cliquer pour ouvrir
5. Cliquer "Confirmer" → Status change
6. Cliquer "Prêt"
7. Cliquer "En livraison"
8. **GPS du client affiché** (6.1319, 1.2228)
9. Cliquer "Livrée" → Fini!

---

## 🔍 Points Clés à Tester

| Fonctionnalité | Chemin | Résultat Attendu |
|---|---|---|
| **Onboarding** | 1ère visite → 4 pages | Carousel animé + boutons |
| **Recherche** | Accueil → Barre | Filtre en temps réel |
| **GPS** | Checkout → "📍" | Maps + Marker + Lat/Lng |
| **Frais** | Panier Flooz | +2% affichés |
| **Paiement** | "Payer" → Simulation | MODE TEST + Succès/Échec |
| **Admin Status** | Dashboard → Commande | 5 boutons de statut |
| **Sécurité** | Admin → Monitoring | Alertes + Logs |

---

## 📊 Dashboard Admin

**URL:** `http://localhost:4000/api/admin/monitoring`

Voir:
- Mode paiement: "test" ou "live"
- Commandes dernières 10 min
- Paiements payés/échoués aujourd'hui
- Tentatives de connexion échouées
- Alertes en attente

---

## 🚨 Problèmes Courants

### Google Maps ne s'affiche pas (Android)
**Solution:** L'émulateur a besoin de Google Play Services
```bash
# Tester sur device réel ou utiliser Pixel 5 Pro avec Play Services
flutter devices  # Voir les devices disponibles
flutter run -d <device_id>
```

### "Trop de requêtes" (429)
**C'est normal** après avoir cliqué "Commander" 10+ fois rapidement.
Attendre 10 minutes ou redémarrer le serveur.

### Payment fee ne s'affiche pas
**Solution:** Sélectionner d'abord une méthode mobile money (Flooz, Mixx)
Cash n'a pas de frais.

### Onboarding n'apparaît pas
**Solution:** Première visite seulement
- Supprimer l'app et réinstaller
- Ou accéder à: `SharedPreferences` → `onboarding_completed` = false

---

## 📱 Changement de Compte

**Dans l'app:**
1. Admin: AppBar → Menu (icône 3 barres)
2. Cliquer "Se déconnecter"
3. Créer/login nouveau compte

---

## 🧰 Commandes Utiles

### Voir les logs en temps réel
```bash
tail -f backend/logs/app-2026-09-30.log
```

### Vérifier la base de données
```bash
# SQLite
sqlite3 backend/data.db
sqlite> SELECT id, status, payment_status, delivery_lat FROM orders LIMIT 5;
```

### Redémarrer le serveur
```bash
# Kill & restart
npm start
# ou Ctrl+C puis npm start
```

### Nettoyer les alertes
```bash
curl -X POST http://localhost:4000/api/admin/alerts/1/resolve \
  -H "Authorization: Bearer <admin_token>"
```

---

## ✨ Prochaines Étapes

1. **Déployer en production:**
   - Mettre `NODE_ENV=production`
   - Générer `JWT_SECRET` fort
   - Ajouter `KADEV_PUBLIC_KEY`, `KADEV_SECRET_KEY` (si pas simulation)

2. **Monter l'app sur le Google Play Store:**
   - Générer clé de signature
   - `flutter build apk --split-per-abi`
   - Soumettre à Google Play

3. **Configurer un domaine personnalisé:**
   - Backend: VPS + Nginx + SSL
   - Mobile: Mettre l'URL de base dans `lib/config.dart`

4. **Activer notifications push:**
   - Firebase Cloud Messaging (FCM)
   - Alerter clients quand le poulet est prêt

---

**Vous êtes prêt! Bon test 🚀**
