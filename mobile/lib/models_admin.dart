// Modèles propres à l'espace administrateur (paiements, encaissements, compte marchand).
import 'models.dart';

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

DateTime? _date(dynamic v) {
  // SQLite renvoie "YYYY-MM-DD HH:MM:SS" en UTC ; accepte aussi l'ISO 8601.
  if (v is! String || v.isEmpty) return null;
  final s = v.contains('T') ? v : v.replaceFirst(' ', 'T');
  final hasZone = s.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(s);
  return DateTime.tryParse(hasZone ? s : '${s}Z')?.toLocal();
}

String? _str(dynamic v) => v == null ? null : '$v';

/// Paiement à vérifier manuellement (en attente depuis plus de 2 min, ou refusé avec un écart).
class PaymentReview {
  final PaymentAttempt attempt;
  final int orderId;
  final String customerName;
  final int orderTotal;
  final int waitingMinutes;
  final int? receivedAmount; // montant effectivement reçu (si connu)
  final DateTime? createdAt;

  PaymentReview({
    required this.attempt,
    required this.orderId,
    required this.customerName,
    required this.orderTotal,
    required this.waitingMinutes,
    this.receivedAmount,
    this.createdAt,
  });

  int get id => attempt.id;

  factory PaymentReview.fromJson(Map<String, dynamic> j) => PaymentReview(
        attempt: PaymentAttempt.fromJson(j),
        orderId: _int(j['order_id']),
        customerName: _str(j['customer_name']) ?? '',
        orderTotal: _int(j['order_total']),
        waitingMinutes: _int(j['waiting_minutes']),
        receivedAmount: j['received_amount'] == null ? null : _int(j['received_amount']),
        createdAt: _date(j['created_at']),
      );
}

/// Ligne du récapitulatif des encaissements (un jour × un opérateur).
class CollectionDay {
  final String day; // YYYY-MM-DD
  final String operator;
  final int gross;
  final int fees;
  final int net;
  final int settled;

  CollectionDay({
    required this.day,
    required this.operator,
    required this.gross,
    required this.fees,
    required this.net,
    required this.settled,
  });

  factory CollectionDay.fromJson(Map<String, dynamic> j) => CollectionDay(
        day: _str(j['day']) ?? '',
        operator: _str(j['operator']) ?? '',
        gross: _int(j['gross']),
        fees: _int(j['fees']),
        net: _int(j['net']),
        settled: _int(j['settled']),
      );
}

class CollectionTotals {
  final int gross;
  final int fees;
  final int net;
  final int settled;

  const CollectionTotals({this.gross = 0, this.fees = 0, this.net = 0, this.settled = 0});

  /// Net restant à recevoir du prestataire.
  int get toReceive => net - settled < 0 ? 0 : net - settled;

  factory CollectionTotals.fromJson(Map<String, dynamic>? j) => j == null
      ? const CollectionTotals()
      : CollectionTotals(
          gross: _int(j['gross']),
          fees: _int(j['fees']),
          net: _int(j['net']),
          settled: _int(j['settled']),
        );
}

/// Paiement encaissé (pour le suivi des reversements).
class CollectionPayment {
  final int id;
  final int orderId;
  final String operator;
  final int gross;
  final int providerFee;
  final int net;
  final String? operatorReference;
  final String settlementStatus; // en_attente, reverse
  final String? settlementReference;
  final DateTime? settledAt;
  final DateTime? paidAt;
  final String customerName;

  CollectionPayment({
    required this.id,
    required this.orderId,
    required this.operator,
    required this.gross,
    required this.providerFee,
    required this.net,
    this.operatorReference,
    required this.settlementStatus,
    this.settlementReference,
    this.settledAt,
    this.paidAt,
    required this.customerName,
  });

  bool get isSettled => settlementStatus == 'reverse' || settledAt != null;

  factory CollectionPayment.fromJson(Map<String, dynamic> j) => CollectionPayment(
        id: _int(j['id']),
        orderId: _int(j['order_id']),
        operator: _str(j['operator']) ?? '',
        gross: _int(j['gross']),
        providerFee: _int(j['provider_fee']),
        net: _int(j['net']),
        operatorReference: _str(j['operator_reference']),
        settlementStatus: _str(j['settlement_status']) ?? 'en_attente',
        settlementReference: _str(j['settlement_reference']),
        settledAt: _date(j['settled_at']),
        paidAt: _date(j['paid_at']),
        customerName: _str(j['customer_name']) ?? '',
      );
}

class CollectionsReport {
  final List<CollectionDay> summary;
  final CollectionTotals totals;
  final List<CollectionPayment> payments;

  CollectionsReport({required this.summary, required this.totals, required this.payments});

  factory CollectionsReport.fromJson(Map<String, dynamic> j) => CollectionsReport(
        summary: ((j['summary'] as List?) ?? [])
            .map((e) => CollectionDay.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        totals: CollectionTotals.fromJson(j['totals'] is Map ? Map<String, dynamic>.from(j['totals'] as Map) : null),
        payments: ((j['payments'] as List?) ?? [])
            .map((e) => CollectionPayment.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// Compte marchand (numéros masqués par le serveur, jamais en clair).
class MerchantInfo {
  final String provider;
  final String displayName;
  final String? flooz;
  final String? mixx;
  final String settlement;

  MerchantInfo({required this.provider, required this.displayName, this.flooz, this.mixx, required this.settlement});

  factory MerchantInfo.fromJson(Map<String, dynamic> j) => MerchantInfo(
        provider: _str(j['provider']) ?? '',
        displayName: _str(j['display_name']) ?? '',
        flooz: _str(j['flooz']),
        mixx: _str(j['mixx']),
        settlement: _str(j['settlement']) ?? '',
      );
}

/// Paiement reçu récemment (notification dans l'espace admin).
class RecentPayment {
  final int id;
  final int orderId;
  final int amount;
  final String operator;
  final DateTime? paidAt;

  RecentPayment({required this.id, required this.orderId, required this.amount, required this.operator, this.paidAt});

  factory RecentPayment.fromJson(Map<String, dynamic> j) => RecentPayment(
        id: _int(j['id']),
        orderId: _int(j['order_id']),
        amount: _int(j['amount']),
        operator: _str(j['operator']) ?? '',
        paidAt: _date(j['paid_at']),
      );
}

/// Libellé court d'un opérateur : « Flooz », « Mixx ».
String operatorShortLabel(String op) {
  switch (op) {
    case 'flooz':
      return 'Flooz';
    case 'mixx':
      return 'Mixx';
  }
  return op.isEmpty ? '—' : op;
}

/// Libellé d'un prestataire de paiement.
String providerLabel(String p) {
  switch (p) {
    case 'simulation':
      return 'Simulation (test)';
    case 'paygate':
      return 'PayGate Global';
    case 'kadev':
      return 'KADEV PAY';
  }
  return p.isEmpty ? '—' : p;
}
