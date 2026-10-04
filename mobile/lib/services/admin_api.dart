// Appels API de l'espace administrateur : paiements, encaissements, reversements, personnel, erreurs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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

// ---------- Listes de commandes paginées (client et admin) ----------

/// Taille d'une page de commandes (« Charger plus »).
const ordersPageSize = 50;

/// Une page de commandes, des plus récentes aux plus anciennes. [beforeId] : commandes plus
/// anciennes que celle-ci. Il en reste probablement d'autres si la page est pleine.
Future<List<Order>> fetchOrdersPage({
  bool admin = false,
  String? status,
  int? beforeId,
  int limit = ordersPageSize,
}) async {
  final r = await Api.instance.get(admin ? '/admin/orders' : '/orders', {
    'limit': '$limit',
    'before_id': ?beforeId?.toString(),
    'status': ?status,
  });
  return r is List ? r.map((e) => Order.fromJson(_map(e))).toList() : <Order>[];
}

/// Remplace la première page par sa version à jour en gardant les pages plus anciennes
/// déjà chargées (si la première page est incomplète, elle contient tout).
List<Order> mergeFirstPage(List<Order> firstPage, List<Order>? current, {int limit = ordersPageSize}) {
  if (firstPage.length < limit || current == null || current.isEmpty) return firstPage;
  final oldest = firstPage.map((o) => o.id).reduce((a, b) => a < b ? a : b);
  return [...firstPage, ...current.where((o) => o.id < oldest)];
}

/// Plus petit identifiant de la liste (curseur `before_id` pour la page suivante).
int? oldestOrderId(List<Order>? orders) =>
    orders == null || orders.isEmpty ? null : orders.map((o) => o.id).reduce((a, b) => a < b ? a : b);

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

// ---------- Personnel (gérant) ----------

/// Comptes du personnel (gérants et cuisine), y compris désactivés.
Future<List<StaffMember>> fetchStaff() async =>
    _list(await Api.instance.get('/admin/staff')).map(StaffMember.fromJson).toList();

/// Crée un compte du personnel ([adminLevel] : 'manager' ou 'kitchen'). Numéro déjà utilisé → erreur 409.
Future<StaffMember> createStaff({
  required String name,
  required String phone,
  required String password,
  required String adminLevel,
}) async =>
    StaffMember.fromJson(_map(await Api.instance.post('/admin/staff', {
      'name': name,
      'phone': phone,
      'password': password,
      'admin_level': adminLevel,
    })));

/// Modifie un compte du personnel (champs null non envoyés). Le serveur refuse de retirer
/// le dernier gérant actif (« Il faut au moins un gérant actif »).
Future<StaffMember> updateStaff(int id, {String? name, String? password, String? adminLevel, bool? active}) async =>
    StaffMember.fromJson(_map(await Api.instance.patch('/admin/staff/$id', {
      'name': ?name,
      'password': ?password,
      'admin_level': ?adminLevel,
      'active': ?active,
    })));

// ---------- Journal des erreurs (gérant) ----------

/// Erreurs enregistrées, des plus récentes aux plus anciennes. [source] : 'app', 'server' ou null (toutes).
Future<List<ErrorLogEntry>> fetchErrorLogs({String? source, int limit = 200}) async =>
    _list(await Api.instance.get('/admin/errors', {'limit': '$limit', 'source': ?source}))
        .map(ErrorLogEntry.fromJson)
        .toList();

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

const _utf8Bom = [0xEF, 0xBB, 0xBF];

bool _hasBom(List<int> b) => b.length >= 3 && b[0] == _utf8Bom[0] && b[1] == _utf8Bom[1] && b[2] == _utf8Bom[2];

/// Export CSV téléchargé (séparateur `;`). Le BOM UTF-8 est conservé dans le fichier
/// pour qu'Excel affiche correctement les accents.
class CollectionsCsv {
  final Uint8List bytes;
  final String fileName; // encaissements_<du>_<au>.csv
  const CollectionsCsv(this.bytes, this.fileName);

  /// Texte sans BOM (pour le presse-papiers).
  String get text => utf8.decode(_hasBom(bytes) ? bytes.sublist(3) : bytes, allowMalformed: true);

  /// Nombre de paiements (lignes non vides, sans l'en-tête).
  int get rows {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).length;
    return lines > 0 ? lines - 1 : 0;
  }
}

/// Télécharge l'export CSV des encaissements.
/// Api.instance.get décode du JSON : on passe donc directement par http avec le jeton.
Future<CollectionsCsv> downloadCollectionsCsv(Map<String, String> query) async {
  final uri = Uri.parse('$apiBaseUrl/api/admin/collections/export.csv').replace(queryParameters: query);
  final res = await _getRaw(uri);
  if (res.statusCode < 200 || res.statusCode >= 300) {
    var msg = 'Export impossible (${res.statusCode})';
    final body = _tryJson(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (body is Map && body['error'] is String) msg = body['error'] as String;
    if (res.statusCode == 401) Api.instance.onUnauthorized?.call();
    throw ApiException(msg, res.statusCode);
  }
  final raw = res.bodyBytes;
  final bytes = _hasBom(raw) ? raw : Uint8List.fromList([..._utf8Bom, ...raw]);
  return CollectionsCsv(bytes, 'encaissements_${query['from'] ?? ''}_${query['to'] ?? ''}.csv');
}

/// Écrit le CSV dans le dossier temporaire de l'application (sous-dossier « exports »).
Future<File> writeCollectionsCsvFile(CollectionsCsv csv) async {
  try {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}${Platform.pathSeparator}exports');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${csv.fileName}');
    return await file.writeAsBytes(csv.bytes, flush: true);
  } catch (_) {
    throw ApiException("Impossible d'enregistrer le fichier CSV sur le téléphone.");
  }
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
