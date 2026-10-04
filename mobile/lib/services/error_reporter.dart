import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'api.dart';

/// Version de l'app envoyée avec les plantages : `--dart-define=APP_VERSION=1.0.0+42` (CI),
/// sinon la version de pubspec.yaml.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

/// Remontée des plantages vers le serveur (POST /api/client-errors), visible par le gérant.
///
/// Jamais bloquant ni plantant : envoi en arrière-plan, toutes les erreurs avalées.
/// Anti-rafale : un même message au plus une fois par minute, 20 envois par session.
/// Les jetons, mots de passe et numéros sont masqués avant l'envoi.
class ErrorReporter {
  ErrorReporter({this._client, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static final ErrorReporter instance = ErrorReporter();

  static const maxPerSession = 20;
  static const sameMessageInterval = Duration(minutes: 1);
  static const _timeout = Duration(seconds: 10);

  final http.Client? _client;
  final DateTime Function() _clock;
  final Map<String, DateTime> _lastSent = {};
  int _sent = 0;
  bool _sending = false; // erreur pendant un envoi : pas de nouvel envoi (anti-boucle)

  /// Nombre d'envois de la session (tests).
  @visibleForTesting
  int get sentCount => _sent;

  /// Branche les gestionnaires globaux d'erreurs Flutter et Dart. À appeler une fois au démarrage.
  void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      // Affichage habituel (console en debug) puis envoi.
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
      final where = [
        if (details.library != null) details.library!,
        if (details.context != null) details.context!.toDescription(),
      ].join(' : ');
      report(details.exception, details.stack, context: where.isEmpty ? 'flutter' : where);
    };
    // Erreurs asynchrones non interceptées (Future sans catchError, plugins...).
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      if (kDebugMode) debugPrint('[ErrorReporter] Erreur non gérée : $error\n$stack');
      report(error, stack, context: 'async');
      return true; // gérée : pas de fermeture brutale de l'app
    };
  }

  /// Envoie une erreur au serveur (si les limites le permettent). Ne lève jamais.
  void report(Object error, StackTrace? stack, {String? context}) {
    try {
      final message = truncate(sanitize('$error'), 500);
      if (message.isEmpty || !shouldSend(message)) return;
      final body = {
        'message': message,
        if (stack != null) 'stack': truncate(sanitize('$stack'), 4000),
        if (context != null && context.isNotEmpty) 'context': truncate(sanitize(context), 300),
        'app_version': appVersion,
        'platform': platformName(),
      };
      unawaited(_send(body));
    } catch (_) {
      // Jamais de plantage dans la remontée des plantages.
    }
  }

  /// Applique les limites (même message : 1 par minute ; 20 par session) et les enregistre.
  @visibleForTesting
  bool shouldSend(String message) {
    if (_sending || _sent >= maxPerSession) return false;
    final now = _clock();
    final last = _lastSent[message];
    if (last != null && now.difference(last) < sameMessageInterval) return false;
    if (_lastSent.length > 100) _lastSent.clear();
    _lastSent[message] = now;
    _sent++;
    return true;
  }

  Future<void> _send(Map<String, Object?> body) async {
    _sending = true;
    try {
      final token = Api.instance.token;
      final uri = Uri.parse('$apiBaseUrl/api/client-errors');
      final headers = {
        'Content-Type': 'application/json',
        // Jeton joint s'il existe : le gérant voit quel compte a rencontré l'erreur.
        if (token != null) 'Authorization': 'Bearer $token',
      };
      final payload = jsonEncode(body);
      final client = _client;
      final future = client != null
          ? client.post(uri, headers: headers, body: payload)
          : http.post(uri, headers: headers, body: payload);
      await future.timeout(_timeout);
    } catch (e) {
      if (kDebugMode) debugPrint('[ErrorReporter] Envoi impossible : $e');
    } finally {
      _sending = false;
    }
  }

  /// 'android', 'ios', 'web'...
  static String platformName() => kIsWeb ? 'web' : defaultTargetPlatform.name;

  static String truncate(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

  /// Masque les données sensibles : jetons (Bearer, JWT), mots de passe, codes, numéros.
  static String sanitize(String input) {
    var s = input;
    // En-tête d'autorisation et jetons JWT (xxx.yyy.zzz en base64url).
    s = s.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9\-_.=+/]+', caseSensitive: false), 'Bearer [masqué]');
    s = s.replaceAll(RegExp(r'eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]*'), '[jeton masqué]');
    // "password": "...", password=..., token: ... (JSON, requêtes, messages).
    s = s.replaceAllMapped(
      RegExp(
        r'''(["']?\b(?:password|mot_de_passe|new_password|current_password|token|otp_token|otp|pin|authorization)\b["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,&}\]]+)''',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[masqué]',
    );
    // Numéros de téléphone (8 chiffres ou plus, avec ou sans +228).
    s = s.replaceAll(RegExp(r'\+?\d[\d ]{7,}\d'), '[numéro masqué]');
    return s.trim();
  }
}
