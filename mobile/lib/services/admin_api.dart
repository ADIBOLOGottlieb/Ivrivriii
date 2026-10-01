// Appels API de l'espace administrateur : paiements, encaissements, reversements.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models.dart';
import '../models_admin.dart';
import 'api.dart';

/// Nombre de paiements à vérifier (badge dans l'espace admin), mis à jour par AdminShell.
final paymentReviewCount = ValueNotifier<int>(0);

Map<String, dynamic> _map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _list(dynamic v) => v is List ? v.map(_map).toList() : <Map<String, dynamic>>[];

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ---------- Paiements à vérifier ----------

Future<List<PaymentReview>> fetchPaymentsReview() async {
  final list = _list(await Api.instance.get('/admin/payments/review')).map(PaymentReview.fromJson).toList();
  paymentReviewCount.value = list.length;
  return list;
}

/// Valide manuellement un paiement (référence de transaction obligatoire, montant >= total).
Future<({Order? order, PaymentAttempt? payment})> validatePayment(int id,
    {required String reference, required int amount}) async {
  final r = _map(await Api.instance.post('/admin/payments/$id/validate', {'reference': reference, 'amount': amount}));
  return (
    order: r['order'] is Map ? Order.fromJson(_map(r['order'])) : null,
    payment: r['payment'] is Map ? PaymentAttempt.fromJson(_map(r['payment'])) : null,
  );
}

Future<({Order? order, PaymentAttempt? payment})> rejectPayment(int id, {required String reason}) async {
  final r = _map(await Api.instance.post('/admin/payments/$id/reject', {'reason': reason}));
  return (
    order: r['order'] is Map ? Order.fromJson(_map(r['order'])) : null,
    payment: r['payment'] is Map ? PaymentAttempt.fromJson(_map(r['payment'])) : null,
  );
}

/// Paiements reçus après [sinceId] ; sans [sinceId], les 20 plus récents (point de départ, sans notification).
Future<List<RecentPayment>> fetchRecentPayments({int? sinceId}) async =>
    _list(await Api.instance.get('/admin/payments/recent', sinceId == null ? null : {'since_id': '$sinceId'}))
        .map(RecentPayment.fromJson)
        .toList();

Future<MerchantInfo> fetchMerchant() async => MerchantInfo.fromJson(_map(await Api.instance.get('/admin/payments/merchant')));

// ---------- Encaissements ----------

/// Filtres communs à la liste des encaissements et à l'export CSV.
Map<String, String> collectionsQuery({
  required DateTime from,
  required DateTime to,
  String? operator, // flooz | mixx | null = tous
  String? settlement, // en_attente | reverse | null = tous
}) =>
    {
      'from': _ymd(from),
      'to': _ymd(to),
      'operator': ?operator,
      'settlement': ?settlement,
    };

Future<CollectionsReport> fetchCollections(Map<String, String> query) async =>
    CollectionsReport.fromJson(_map(await Api.instance.get('/admin/collections', query)));

/// Marque des paiements comme reversés par le prestataire. Renvoie le nombre de paiements mis à jour.
Future<int> createSettlement(List<int> paymentIds, String reference) async {
  final r = _map(await Api.instance.post('/admin/settlements', {'payment_ids': paymentIds, 'reference': reference}));
  final n = r['updated'];
  return n is num ? n.toInt() : paymentIds.length;
}

/// Télécharge l'export CSV (séparateur `;`). Le BOM UTF-8 éventuel est retiré.
/// Api.instance.get décode du JSON : on passe donc directement par http avec le jeton.
Future<String> downloadCollectionsCsv(Map<String, String> query) async {
  final uri = Uri.parse('$apiBaseUrl/api/admin/collections/export.csv').replace(queryParameters: query);
  final res = await _getRaw(uri);
  final text = utf8.decode(res.bodyBytes, allowMalformed: true);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    var msg = 'Export impossible (${res.statusCode})';
    final body = _tryJson(text);
    if (body is Map && body['error'] is String) msg = body['error'] as String;
    if (res.statusCode == 401) Api.instance.onUnauthorized?.call();
    throw ApiException(msg, res.statusCode);
  }
  final bom = String.fromCharCode(0xFEFF);
  return text.startsWith(bom) ? text.substring(1) : text;
}

Future<http.Response> _getRaw(Uri uri) async {
  try {
    return await http.get(uri, headers: {
      if (Api.instance.token != null) 'Authorization': 'Bearer ${Api.instance.token}',
    }).timeout(const Duration(seconds: 30));
  } on TimeoutException {
    throw ApiException('Le serveur ne répond pas. Vérifiez votre connexion.', null, true);
  } catch (_) {
    throw ApiException('Impossible de joindre le serveur. Vérifiez votre connexion.', null, true);
  }
}

dynamic _tryJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
