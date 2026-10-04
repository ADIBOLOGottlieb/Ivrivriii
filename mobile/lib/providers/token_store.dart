import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[TokenStore] $message');
}

/// Jeton de connexion enregistré de façon chiffrée (Keystore Android, Trousseau iOS).
///
/// Les anciennes versions le gardaient en clair dans SharedPreferences : au premier
/// démarrage, il est copié dans le stockage chiffré puis effacé de SharedPreferences,
/// sans déconnecter l'utilisateur. Aucune méthode ne lève d'exception.
class TokenStore {
  /// Clé des anciennes versions (SharedPreferences, en clair).
  static const legacyKey = 'auth_token';
  static const _secureKey = 'auth_token';

  /// Lecture / écriture bloquées (Keystore indisponible) : on n'attend pas indéfiniment.
  static const _timeout = Duration(seconds: 6);

  TokenStore({FlutterSecureStorage? storage}) : _secure = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  /// Jeton enregistré, ou null (aucun, ou stockage chiffré illisible : on considère
  /// alors l'utilisateur déconnecté). Fait la migration depuis SharedPreferences.
  Future<String?> read() async {
    String? token;
    try {
      token = await _secure.read(key: _secureKey).timeout(_timeout);
    } catch (e) {
      // Arrive sur certains Android après une restauration de sauvegarde (clé du Keystore perdue).
      _log('Stockage chiffré illisible : $e');
      // Utilisateur considéré comme déconnecté ; la prochaine connexion réécrit le jeton
      // (sur Android, l'option resetOnError efface déjà les données indéchiffrables).
      token = null;
    }
    if (token != null && token.isEmpty) token = null;

    // Migration de l'ancien jeton en clair.
    SharedPreferences? prefs;
    String? legacy;
    try {
      prefs = await SharedPreferences.getInstance();
      legacy = prefs.getString(legacyKey);
    } catch (e) {
      _log('Préférences illisibles : $e');
    }
    if (prefs == null || legacy == null) return token;
    if (legacy.isEmpty || token != null) {
      // Déjà migré (ou vide) : on retire seulement la copie en clair.
      await _removeLegacy(prefs);
      return token;
    }
    if (await _write(legacy)) {
      await _removeLegacy(prefs);
      _log('Jeton migré vers le stockage chiffré');
    } else {
      // Stockage chiffré indisponible : on garde l'ancien jeton (pas de déconnexion)
      // et on retentera la migration au prochain démarrage.
      _log('Migration reportée');
    }
    return legacy;
  }

  /// Enregistre le jeton (connexion, nouveau mot de passe...). Renvoie false si le
  /// stockage chiffré a échoué : la session reste valable jusqu'à la fermeture de l'app.
  Future<bool> save(String token) async {
    final ok = await _write(token);
    try {
      await _removeLegacy(await SharedPreferences.getInstance());
    } catch (_) {}
    return ok;
  }

  /// Efface le jeton (déconnexion), y compris une éventuelle copie en clair.
  Future<void> clear() async {
    try {
      await _secure.delete(key: _secureKey).timeout(_timeout);
    } catch (e) {
      _log('Jeton chiffré non supprimé : $e');
    }
    try {
      await _removeLegacy(await SharedPreferences.getInstance());
    } catch (e) {
      _log('Ancien jeton non supprimé : $e');
    }
  }

  Future<bool> _write(String token) async {
    try {
      await _secure.write(key: _secureKey, value: token).timeout(_timeout);
      return true;
    } catch (e) {
      _log('Jeton non enregistré : $e');
      return false;
    }
  }

  Future<void> _removeLegacy(SharedPreferences prefs) async {
    if (!prefs.containsKey(legacyKey)) return;
    try {
      await prefs.remove(legacyKey);
    } catch (e) {
      _log('Ancien jeton non supprimé : $e');
    }
  }
}
