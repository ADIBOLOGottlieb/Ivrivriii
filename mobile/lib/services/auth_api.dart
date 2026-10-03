import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models.dart';
import 'account_api.dart';
import 'api.dart';

/// Inscription, code de vérification (OTP), mot de passe oublié, documents légaux
/// et demandes de réinitialisation côté admin.
///
/// Les routes publiques passent par des requêtes « brutes » ([rawJsonRequest]) :
/// un 401 (code faux, mot de passe faux) ne doit jamais déconnecter l'utilisateur.

/// Nombre de demandes « mot de passe oublié » en attente (badge admin).
final passwordResetCount = ValueNotifier<int>(0);

/// Canal d'envoi d'un code : vrai SMS, ou appel du restaurant (pas de prestataire SMS).
bool _isSmsChannel(dynamic channel, bool fallback) {
  if (channel is! String || channel.isEmpty) return fallback;
  return channel == 'sms' || channel == 'http';
}

/// Le code est-il réellement envoyé par SMS ? (sinon le restaurant appelle le client)
Future<bool> _smsConfigured() async {
  try {
    return (await Api.instance.settings()).otpRequired;
  } catch (_) {
    return false;
  }
}

/// Demande un code de vérification. Renvoie vrai si le code part par SMS.
Future<bool> requestOtp(String phone, {String purpose = 'register'}) async {
  final body = await rawJsonRequest('POST', '/auth/otp/request', {'phone': phone, 'purpose': purpose}, auth: false);
  return _isSmsChannel(body is Map ? body['channel'] : null, true);
}

/// Vérifie le code reçu : renvoie le jeton de vérification (valable 15 min).
Future<String> verifyOtp(String phone, String code, {String purpose = 'register'}) async {
  final body = await rawJsonRequest(
      'POST', '/auth/otp/verify', {'phone': phone, 'code': code, 'purpose': purpose}, auth: false);
  final token = body is Map ? body['otp_token'] : null;
  if (token is! String || token.isEmpty) throw ApiException('Code invalide');
  return token;
}

/// Crée un compte (acceptation des conditions obligatoire) et renvoie la session.
Future<(String, AppUser)> registerAccount({
  required String name,
  required String phone,
  required String password,
  String? email,
  String? address,
  String? otpToken,
}) async {
  final body = await rawJsonRequest(
    'POST',
    '/auth/register',
    {
      'name': name,
      'phone': phone,
      'password': password,
      'email': email,
      'address': address,
      'accept_terms': true,
      'otp_token': ?otpToken,
    },
    auth: false,
  );
  final session = sessionFromJson(body);
  if (session == null) throw ApiException('Réponse inattendue du serveur');
  return session;
}

/// « Mot de passe oublié » : crée une demande de code. Renvoie vrai si le code part par SMS,
/// faux si le restaurant va appeler le client pour le lui communiquer.
Future<bool> forgotPassword(String phone) async {
  final body = await rawJsonRequest('POST', '/auth/password/forgot', {'phone': phone}, auth: false);
  final channel = body is Map ? body['channel'] : null;
  if (channel is String && channel.isNotEmpty) return _isSmsChannel(channel, false);
  return _smsConfigured();
}

/// Nouveau mot de passe avec le code reçu : renvoie la session (connexion directe).
Future<(String, AppUser)> resetPassword({
  required String phone,
  required String code,
  required String newPassword,
}) async {
  final body = await rawJsonRequest(
    'POST',
    '/auth/password/reset',
    {'phone': phone, 'code': code, 'new_password': newPassword},
    auth: false,
  );
  final session = sessionFromJson(body);
  if (session == null) throw ApiException('Réponse inattendue du serveur');
  return session;
}

// ---------- Documents légaux ----------

enum LegalDoc { terms, privacy }

String _absolute(String? url, String fallbackPath) {
  final u = (url ?? '').trim();
  if (u.isEmpty) return '$apiBaseUrl$fallbackPath';
  if (u.startsWith('http')) return u;
  return '$apiBaseUrl${u.startsWith('/') ? u : '/$u'}';
}

/// Adresse de la page publique (réglages du serveur si chargés, sinon chemin par défaut).
Future<Uri> legalUrl(LegalDoc doc) async {
  AppSettings? s;
  try {
    s = await Api.instance.settings();
  } catch (_) {
    s = null;
  }
  return Uri.parse(doc == LegalDoc.terms
      ? _absolute(s?.termsUrl, '/legal/cgu')
      : _absolute(s?.privacyUrl, '/legal/confidentialite'));
}

// ---------- Admin : demandes de réinitialisation ----------

DateTime? _date(dynamic v) {
  if (v is! String || v.isEmpty) return null;
  // SQLite renvoie "YYYY-MM-DD HH:MM:SS" en UTC.
  final s = v.contains('T') ? v : '${v.replaceFirst(' ', 'T')}Z';
  return DateTime.tryParse(s)?.toLocal();
}

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

/// Demande « mot de passe oublié » en attente.
class PasswordResetRequest {
  final int id;
  final String phone;
  final String name;
  final String? code; // à communiquer au client (mode sans SMS uniquement)
  final DateTime? createdAt;
  final DateTime? expiresAt;

  const PasswordResetRequest({
    required this.id,
    required this.phone,
    required this.name,
    this.code,
    this.createdAt,
    this.expiresAt,
  });

  bool get expired => expiresAt != null && expiresAt!.isBefore(DateTime.now());

  factory PasswordResetRequest.fromJson(Map<String, dynamic> j) {
    final user = j['user'] is Map ? j['user'] as Map : const {};
    final code = j['code'];
    return PasswordResetRequest(
      id: _int(j['id']),
      phone: '${j['phone'] ?? user['phone'] ?? ''}',
      name: '${j['name'] ?? j['user_name'] ?? user['name'] ?? ''}',
      code: code == null || '$code'.isEmpty ? null : '$code',
      createdAt: _date(j['created_at']),
      expiresAt: _date(j['expires_at']),
    );
  }
}

/// Demandes en attente (met aussi à jour le badge).
Future<List<PasswordResetRequest>> fetchPasswordResets() async {
  final list = await Api.instance.get('/admin/password-resets');
  final items = list is List
      ? list.whereType<Map>().map((e) => PasswordResetRequest.fromJson(Map<String, dynamic>.from(e))).toList()
      : <PasswordResetRequest>[];
  passwordResetCount.value = items.length;
  return items;
}

/// Rafraîchit le badge sans lever d'erreur.
Future<void> refreshPasswordResetCount() async {
  try {
    await fetchPasswordResets();
  } catch (_) {
    // Badge inchangé.
  }
}

/// Marque une demande comme traitée.
Future<void> markPasswordResetDone(int id) async {
  await Api.instance.post('/admin/password-resets/$id/done');
}
