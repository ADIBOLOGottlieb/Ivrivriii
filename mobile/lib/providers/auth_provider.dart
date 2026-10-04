import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../services/admin_api.dart' show paymentReviewCount;
import '../services/api.dart';
import '../services/auth_api.dart' show passwordResetCount;
import '../services/push_service.dart';
import '../services/shared_location.dart';
import 'cart_provider.dart';
import 'token_store.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[AuthProvider] $message');
}

/// Exécute [action] sans jamais lever (notifications : jamais bloquant).
Future<void> _safe(String what, FutureOr<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    _log('$what : $e');
  }
}

class AuthProvider extends ChangeNotifier {
  /// Jeton de connexion chiffré (Keystore Android), migré depuis SharedPreferences.
  final TokenStore _tokens;

  /// Panier à vider à la déconnexion et à rattacher au compte connecté.
  final CartProvider? cart;

  AppUser? user;
  bool initializing = true;

  /// Jeton enregistré mais serveur injoignable : on affiche l'écran « Connexion au serveur
  /// impossible » (réessai), pas l'écran de connexion.
  bool offline = false;

  /// Nouvel essai de connexion en cours (écran hors ligne).
  bool retrying = false;

  /// La dernière déconnexion vient d'un jeton refusé par le serveur (401), pas de l'utilisateur.
  bool sessionExpired = false;

  String? _lastError;

  bool get isLoggedIn => user != null;
  String? get lastError => _lastError;

  AuthProvider({this.cart, TokenStore? tokenStore}) : _tokens = tokenStore ?? TokenStore() {
    Api.instance.onUnauthorized = _onUnauthorized;
  }

  /// Restaure la session enregistrée au démarrage.
  Future<void> init() async {
    try {
      // Réveille le serveur pendant l'écran d'accueil (jusqu'à 90 s sur l'offre gratuite) :
      // la connexion qui suit ne tombera pas sur un serveur endormi.
      final awake = await Api.instance.wakeUp();
      // Stockage chiffré illisible : null, l'utilisateur se reconnecte simplement.
      final token = await _tokens.read();
      if (token != null) {
        Api.instance.token = token;
        if (awake) {
          await _verifySession();
        } else {
          // Serveur injoignable après 90 s : inutile d'attendre encore, écran « Réessayer ».
          offline = true;
          _lastError = 'Connexion au serveur impossible';
        }
      }
    } catch (e) {
      _log('Erreur au démarrage : $e');
      _lastError = 'Impossible d\'initialiser la session';
    } finally {
      initializing = false;
      notifyListeners();
    }
  }

  /// Vérifie le jeton courant auprès du serveur (GET /auth/me).
  /// 401 : session effacée. Autre erreur (réseau, serveur endormi...) : mode [offline].
  Future<void> _verifySession() async {
    final token = Api.instance.token;
    if (token == null) return;
    try {
      final u = await Api.instance.me();
      if (Api.instance.token != token) return; // session changée entre-temps
      _startSession(u, register: true);
      _log('Session vérifiée');
    } on ApiException catch (e) {
      if (Api.instance.token != token) return;
      if (e.statusCode == 401) {
        _log('Jeton refusé (401)');
        sessionExpired = true;
        await _clear();
      } else {
        _log('Serveur injoignable : $e');
        offline = true;
        _lastError = e.message;
      }
    } catch (e) {
      if (Api.instance.token != token) return;
      _log('Erreur inattendue : $e');
      offline = true;
      _lastError = 'Connexion au serveur impossible';
    }
  }

  /// Écran hors ligne : nouvel essai de connexion au serveur.
  Future<void> retryConnection() async {
    if (!offline || retrying) return;
    retrying = true;
    notifyListeners();
    try {
      await _verifySession();
    } finally {
      retrying = false;
      notifyListeners();
    }
  }

  /// Connexion par téléphone et mot de passe. Lève une ApiException lisible en cas d'échec.
  Future<void> login(String phone, String password) async {
    try {
      final (token, u) = await Api.instance.login(phone, password);
      await applySession(token, u);
      _log('Connexion réussie');
    } on ApiException catch (e) {
      _lastError = e.message;
      rethrow;
    } catch (e) {
      _log('Erreur de connexion : $e');
      _lastError = 'Erreur lors de la connexion';
      rethrow;
    }
  }

  /// Inscription (ancienne interface, gardée pour compatibilité).
  Future<void> register({
    required String name,
    required String phone,
    required String password,
    String? email,
    String? address,
    bool acceptTerms = false,
    String? otpToken,
  }) async {
    try {
      final (token, u) = await Api.instance.register(
        name: name,
        phone: phone,
        password: password,
        email: email,
        address: address,
        acceptTerms: acceptTerms,
        otpToken: otpToken,
      );
      await applySession(token, u);
      _log('Inscription réussie');
    } on ApiException catch (e) {
      _lastError = e.message;
      rethrow;
    } catch (e) {
      _log('Erreur d\'inscription : $e');
      _lastError = 'Erreur lors de l\'inscription';
      rethrow;
    }
  }

  /// Installe une session reçue du serveur (connexion, inscription, mot de passe
  /// réinitialisé ou changé : le serveur renvoie alors un nouveau jeton).
  Future<void> applySession(String token, AppUser u) async {
    // Autre compte que celui en mémoire : on nettoie d'abord l'ancien.
    if (user != null && user!.id != u.id) await _clear();
    final newSession = user?.id != u.id;
    Api.instance.token = token;
    // Échec du stockage chiffré : session valable jusqu'à la fermeture de l'app.
    if (!await _tokens.save(token)) _log('Jeton non enregistré');
    _startSession(u, register: newSession);
    notifyListeners();
  }

  void _startSession(AppUser u, {required bool register}) {
    user = u;
    offline = false;
    sessionExpired = false;
    _lastError = null;
    unawaited(cart?.attachUser(u.id));
    if (register) {
      unawaited(_safe('Notifications indisponibles', () => PushService.instance.registerForUser()));
    }
  }

  /// Met à jour le profil. Lève une ApiException en cas d'échec.
  Future<void> updateProfile(Map<String, dynamic> data) async {
    try {
      final u = await Api.instance.updateMe(data);
      if (user == null) return; // déconnecté entre-temps
      user = u;
      _lastError = null;
      notifyListeners();
    } on ApiException catch (e) {
      _lastError = e.message;
      rethrow;
    } catch (e) {
      _log('Erreur de mise à jour du profil : $e');
      _lastError = 'Erreur lors de la mise à jour du profil';
      rethrow;
    }
  }

  /// Remplace l'utilisateur courant (après envoi de photo, modification du profil...).
  void setUser(AppUser u) {
    if (user == null) return; // déconnecté entre-temps
    user = u;
    notifyListeners();
  }

  /// Recharge le profil depuis le serveur. Les erreurs réseau sont ignorées
  /// (on garde le profil en mémoire) ; renvoie l'utilisateur à jour ou null.
  Future<AppUser?> refreshUser() async {
    if (user == null) return null;
    try {
      final u = await Api.instance.me();
      if (user == null || user!.id != u.id) return null;
      user = u;
      notifyListeners();
      return u;
    } catch (e) {
      _log('refreshUser : $e');
      return null;
    }
  }

  /// Déconnexion volontaire.
  Future<void> logout() async {
    sessionExpired = false;
    await _clear();
    notifyListeners();
  }

  /// Jeton refusé par le serveur (401) pendant l'utilisation.
  void _onUnauthorized() {
    if (Api.instance.token == null) return;
    sessionExpired = true;
    unawaited(_clear().whenComplete(notifyListeners));
  }

  /// Nettoyage centralisé de tout ce qui appartient au compte : jeton, profil, panier,
  /// position Google Maps reçue, compteurs admin, jeton de notifications, caches.
  Future<void> _clear() async {
    // Désinscription des notifications tant que le jeton est encore là (DELETE authentifié).
    final unregister = _safe('Désinscription des notifications', () => PushService.instance.unregister());
    Api.instance.token = null;
    user = null;
    offline = false;
    retrying = false;
    cart?.reset();
    SharedLocationService.instance.reset();
    paymentReviewCount.value = 0;
    passwordResetCount.value = 0;
    Api.instance.invalidateCache();
    await _tokens.clear();
    unawaited(unregister);
  }

  /// Efface le message d'erreur.
  void clearError() {
    _lastError = null;
    notifyListeners();
  }
}
