import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../services/api.dart';

class AuthProvider extends ChangeNotifier {
  static const _tokenKey = 'auth_token';

  AppUser? user;
  bool initializing = true;
  String? _lastError;

  bool get isLoggedIn => user != null;
  String? get lastError => _lastError;

  AuthProvider() {
    Api.instance.onUnauthorized = () => logout();
  }

  /// Initialize auth state from stored preferences
  /// Handles offline mode gracefully - retains token if server is unreachable
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_tokenKey);

      if (token != null) {
        Api.instance.token = token;
        try {
          // Attempt to verify token with server
          user = await Api.instance.me();
          _lastError = null;
          debugPrint('[AuthProvider] Successfully verified token with server');
        } on ApiException catch (e) {
          debugPrint('[AuthProvider] Failed to verify token: $e (statusCode: ${e.statusCode})');

          // 401 = Token is invalid or expired, clear it
          if (e.statusCode == 401) {
            debugPrint('[AuthProvider] Token is invalid (401) - clearing credentials');
            await _clear();
          } else if (e.isNetworkError) {
            // Network error - keep token, user will be in "offline mode"
            debugPrint('[AuthProvider] Network error during init - keeping token for offline mode');
            _lastError = 'Mode hors ligne - vous pouvez continuer avec les données en cache';
          } else {
            // Other client errors - keep token but warn user
            debugPrint('[AuthProvider] Client error during init: ${e.message}');
            _lastError = e.message;
          }
        } catch (e) {
          // Catch ALL other exceptions (not just ApiException)
          debugPrint('[AuthProvider] Unexpected error during init: $e');
          _lastError = 'Erreur lors de l\'initialisation: ${e.toString()}';
          // Keep the token - user might be offline
        }
      }
    } catch (e) {
      debugPrint('[AuthProvider] Fatal error during init: $e');
      _lastError = 'Impossible d\'initialiser l\'authentification';
    } finally {
      // GUARANTEE: Always set initializing to false, even on error
      initializing = false;
      notifyListeners();
    }
  }

  /// Login user with phone and password
  /// Throws ApiException with user-friendly message on failure
  Future<void> login(String phone, String password) async {
    try {
      debugPrint('[AuthProvider] Attempting login for phone: $phone');
      final (token, u) = await Api.instance.login(phone, password);
      await _save(token, u);
      _lastError = null;
      debugPrint('[AuthProvider] Login successful');
    } on ApiException catch (e) {
      debugPrint('[AuthProvider] Login failed: $e');
      _lastError = e.message;
      rethrow;
    } catch (e) {
      debugPrint('[AuthProvider] Unexpected error during login: $e');
      _lastError = 'Erreur lors de la connexion: ${e.toString()}';
      rethrow;
    }
  }

  /// Register new user account
  /// Throws ApiException with user-friendly message on failure
  Future<void> register({
    required String name,
    required String phone,
    required String password,
    String? email,
    String? address,
  }) async {
    try {
      debugPrint('[AuthProvider] Attempting registration for phone: $phone');
      final (token, u) = await Api.instance.register(
        name: name,
        phone: phone,
        password: password,
        email: email,
        address: address,
      );
      await _save(token, u);
      _lastError = null;
      debugPrint('[AuthProvider] Registration successful');
    } on ApiException catch (e) {
      debugPrint('[AuthProvider] Registration failed: $e');
      _lastError = e.message;
      rethrow;
    } catch (e) {
      debugPrint('[AuthProvider] Unexpected error during registration: $e');
      _lastError = 'Erreur lors de l\'inscription: ${e.toString()}';
      rethrow;
    }
  }

  /// Update user profile information
  /// Throws ApiException on failure
  Future<void> updateProfile(Map<String, dynamic> data) async {
    try {
      debugPrint('[AuthProvider] Updating user profile');
      user = await Api.instance.updateMe(data);
      _lastError = null;
      notifyListeners();
      debugPrint('[AuthProvider] Profile updated successfully');
    } on ApiException catch (e) {
      debugPrint('[AuthProvider] Failed to update profile: $e');
      _lastError = e.message;
      rethrow;
    } catch (e) {
      debugPrint('[AuthProvider] Unexpected error during profile update: $e');
      _lastError = 'Erreur lors de la mise à jour du profil';
      rethrow;
    }
  }

  /// Logout and clear all authentication data
  Future<void> logout() async {
    try {
      debugPrint('[AuthProvider] Logging out');
      await _clear();
      _lastError = null;
      notifyListeners();
      debugPrint('[AuthProvider] Logout successful');
    } catch (e) {
      debugPrint('[AuthProvider] Error during logout: $e');
      _lastError = 'Erreur lors de la déconnexion';
      // Continue logout even if there's an error
      notifyListeners();
    }
  }

  /// Save token and user to persistent storage and API instance
  Future<void> _save(String token, AppUser u) async {
    try {
      Api.instance.token = token;
      user = u;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
      notifyListeners();
    } catch (e) {
      debugPrint('[AuthProvider] Error saving credentials: $e');
      _lastError = 'Impossible de sauvegarder les données';
      rethrow;
    }
  }

  /// Clear all authentication data from storage and API instance
  Future<void> _clear() async {
    try {
      Api.instance.token = null;
      user = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      Api.instance.clearCache();
    } catch (e) {
      debugPrint('[AuthProvider] Error clearing credentials: $e');
      // Set to null anyway even if there's an error
      Api.instance.token = null;
      user = null;
    }
  }

  /// Clear stored error message
  void clearError() {
    _lastError = null;
    notifyListeners();
  }
}
