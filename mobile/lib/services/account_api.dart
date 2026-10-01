import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config.dart';
import '../models.dart';
import 'api.dart';

/// Appels « mon compte » (photo, mot de passe, statistiques, adresses, suppression).

const Duration _timeout = Duration(seconds: 30);

/// Statistiques personnelles du client.
class AccountStats {
  final int ordersCount;
  final int totalSpent;

  const AccountStats({required this.ordersCount, required this.totalSpent});

  factory AccountStats.fromJson(Map<String, dynamic> j) =>
      AccountStats(ordersCount: _toInt(j['orders_count']), totalSpent: _toInt(j['total_spent']));
}

int _toInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

Uri _accountUri(String path) => Uri.parse('$apiBaseUrl/api$path');

/// Décode la réponse d'une requête « brute ». Contrairement à Api._send, un 401 ici
/// ne déconnecte pas : le serveur répond 401 quand le mot de passe saisi est faux.
dynamic _decode(http.Response res) {
  dynamic body;
  if (res.bodyBytes.isNotEmpty) {
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      body = null;
    }
  }
  if (res.statusCode >= 200 && res.statusCode < 300) return body;
  final msg = body is Map && body['error'] is String ? body['error'] as String : 'Erreur (${res.statusCode})';
  throw ApiException(msg, res.statusCode, res.statusCode >= 500);
}

/// Exécute une requête et convertit les erreurs réseau en [ApiException] lisibles.
Future<dynamic> _run(Future<http.Response> Function() send) async {
  try {
    final res = await send().timeout(_timeout);
    return _decode(res);
  } on ApiException {
    rethrow;
  } on TimeoutException catch (e) {
    throw ApiException('Le serveur ne répond pas. Vérifiez votre connexion.', null, true, e);
  } on SocketException catch (e) {
    throw ApiException('Impossible de joindre le serveur. Vérifiez votre connexion.', null, true, e);
  } on http.ClientException catch (e) {
    throw ApiException('Impossible de joindre le serveur. Vérifiez votre connexion.', null, true, e);
  }
}

/// Requête JSON avec corps (y compris pour DELETE), sans déconnexion automatique sur 401.
Future<dynamic> _jsonRequest(String method, String path, Map<String, dynamic> body) {
  return _run(() async {
    final req = http.Request(method, _accountUri(path))
      ..headers['Content-Type'] = 'application/json'
      ..headers['Authorization'] = 'Bearer ${Api.instance.token}'
      ..body = jsonEncode(body);
    return http.Response.fromStream(await req.send());
  });
}

/// Profil à jour depuis le serveur.
Future<AppUser> fetchMe() => Api.instance.me();

/// Met à jour nom, e-mail, adresse et numéro mobile money préféré.
Future<AppUser> updateAccount(Map<String, dynamic> data) async =>
    AppUser.fromJson(await Api.instance.put('/auth/me', data) as Map<String, dynamic>);

/// Change le mot de passe (l'ancien est obligatoire).
Future<void> changePassword({required String oldPassword, required String newPassword}) async {
  await _jsonRequest('PUT', '/auth/me/password', {'old_password': oldPassword, 'new_password': newPassword});
}

/// Envoie une nouvelle photo de profil (multipart, champ `image`).
Future<AppUser> uploadAvatar(Uint8List bytes, {String filename = 'avatar.png', String subtype = 'png'}) async {
  final body = await _run(() async {
    final req = http.MultipartRequest('POST', _accountUri('/auth/me/avatar'))
      ..headers['Authorization'] = 'Bearer ${Api.instance.token}'
      ..files.add(http.MultipartFile.fromBytes(
        'image',
        bytes,
        filename: filename,
        contentType: MediaType('image', subtype),
      ));
    return http.Response.fromStream(await req.send());
  });
  return AppUser.fromJson(body as Map<String, dynamic>);
}

/// Supprime la photo de profil.
Future<AppUser> deleteAvatar() async =>
    AppUser.fromJson(await Api.instance.delete('/auth/me/avatar') as Map<String, dynamic>);

/// Nombre de commandes et total dépensé.
Future<AccountStats> fetchAccountStats() async =>
    AccountStats.fromJson(await Api.instance.get('/auth/me/stats') as Map<String, dynamic>);

/// Adresses enregistrées.
Future<List<SavedAddress>> fetchSavedAddresses() async {
  final list = await Api.instance.get('/auth/me/addresses') as List;
  return list.map((e) => SavedAddress.fromJson(e as Map<String, dynamic>)).toList();
}

Map<String, dynamic> _addressBody(String label, String address, double? lat, double? lng) =>
    {'label': label, 'address': address, 'lat': lat, 'lng': lng};

Future<SavedAddress> createSavedAddress({
  required String label,
  required String address,
  double? lat,
  double? lng,
}) async =>
    SavedAddress.fromJson(
        await Api.instance.post('/auth/me/addresses', _addressBody(label, address, lat, lng)) as Map<String, dynamic>);

Future<SavedAddress> updateSavedAddress(
  int id, {
  required String label,
  required String address,
  double? lat,
  double? lng,
}) async =>
    SavedAddress.fromJson(
        await Api.instance.put('/auth/me/addresses/$id', _addressBody(label, address, lat, lng)) as Map<String, dynamic>);

Future<void> deleteSavedAddress(int id) async {
  await Api.instance.delete('/auth/me/addresses/$id');
}

/// Supprime (anonymise) le compte. Les commandes restent conservées pour la comptabilité.
Future<void> deleteAccount(String password) async {
  await _jsonRequest('DELETE', '/auth/me', {'password': password});
}
