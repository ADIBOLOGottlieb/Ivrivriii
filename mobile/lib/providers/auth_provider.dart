import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../services/api.dart';

class AuthProvider extends ChangeNotifier {
  static const _tokenKey = 'auth_token';

  AppUser? user;
  bool initializing = true;

  bool get isLoggedIn => user != null;

  AuthProvider() {
    Api.instance.onUnauthorized = () => logout();
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    if (token != null) {
      Api.instance.token = token;
      try {
        user = await Api.instance.me();
      } on ApiException catch (e) {
        // Hors ligne : on garde le jeton, l'utilisateur pourra réessayer.
        if (e.statusCode == 401) await _clear();
      }
    }
    initializing = false;
    notifyListeners();
  }

  Future<void> login(String phone, String password) async {
    final (token, u) = await Api.instance.login(phone, password);
    await _save(token, u);
  }

  Future<void> register({
    required String name,
    required String phone,
    required String password,
    String? email,
    String? address,
  }) async {
    final (token, u) = await Api.instance.register(
      name: name,
      phone: phone,
      password: password,
      email: email,
      address: address,
    );
    await _save(token, u);
  }

  Future<void> updateProfile(Map<String, dynamic> data) async {
    user = await Api.instance.updateMe(data);
    notifyListeners();
  }

  Future<void> logout() async {
    await _clear();
    notifyListeners();
  }

  Future<void> _save(String token, AppUser u) async {
    Api.instance.token = token;
    user = u;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    notifyListeners();
  }

  Future<void> _clear() async {
    Api.instance.token = null;
    user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }
}
