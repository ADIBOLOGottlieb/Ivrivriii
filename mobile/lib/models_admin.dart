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

// ---------- Personnel ----------

/// Libellé d'un niveau du personnel.
String staffLevelLabel(String level) => level == 'kitchen' ? 'Cuisine' : 'Gérant';

// ---------- Réglages : horaires et frais de livraison ----------

/// Noms des jours (clés de [AppSettings.weekDays]).
const weekDayLabels = <String, String>{
  'mon': 'Lundi',
  'tue': 'Mardi',
  'wed': 'Mercredi',
  'thu': 'Jeudi',
  'fri': 'Vendredi',
  'sat': 'Samedi',
  'sun': 'Dimanche',
};

/// Nom du jour en minuscules (« samedi ») pour un [DateTime.weekday] (1 = lundi).
String frenchWeekday(int weekday) =>
    const ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'][(weekday - 1) % 7];

/// Minutes depuis minuit d'une heure « HH:MM » (« 24:00 » = 1440), null si invalide.
int? hhmmToMinutes(String v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(v.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!), min = int.parse(m.group(2)!);
  if (min > 59 || h > 24 || (h == 24 && min != 0)) return null;
  return h * 60 + min;
}

/// « HH:MM » pour un nombre de minutes depuis minuit (1440 → « 24:00 »).
String minutesToHhmm(int minutes) {
  final m = minutes.clamp(0, 1440);
  return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
}

/// Horaires par défaut : tous les jours 10:00–22:00.
Map<String, List<List<String>>> defaultOpeningHours() => {
      for (final d in AppSettings.weekDays)
        d: [
          ['10:00', '22:00'],
        ],
    };

/// Erreur de saisie d'une journée (plages invalides ou qui se chevauchent), sinon null.
String? openingRangesError(List<List<String>> ranges) {
  final parsed = <(int, int)>[];
  for (final r in ranges) {
    final a = hhmmToMinutes(r[0]), b = hhmmToMinutes(r[1]);
    if (a == null || b == null) return 'Heure invalide';
    if (a >= b) return "L'heure de fin doit suivre l'heure de début";
    parsed.add((a, b));
  }
  parsed.sort((x, y) => x.$1.compareTo(y.$1));
  for (var i = 1; i < parsed.length; i++) {
    if (parsed[i].$1 < parsed[i - 1].$2) return 'Les plages se chevauchent';
  }
  return null;
}

/// Frais de livraison au kilomètre (même calcul que le serveur) :
/// base + ceil(max(0, km − inclus)) × prix par km, arrondi aux 50 FCFA supérieurs.
int estimateDeliveryFee({required int base, required int perKm, required double freeKm, required double km}) {
  final extra = km - freeKm;
  // Petite tolérance : 5,0 − 2,0 ne doit pas devenir 3,0000001 → 4 km facturés.
  final extraKm = extra <= 0 ? 0 : (extra - 1e-9).ceil();
  final fee = base + extraKm * perKm;
  return ((fee + 49) ~/ 50) * 50;
}

/// Copie des réglages en remplaçant certains champs (les autres sont renvoyés tels quels,
/// pour ne pas les écraser par les valeurs par défaut de [AppSettings]).
extension AppSettingsCopy on AppSettings {
  AppSettings copyWith({
    int? deliveryFee,
    int? minOrder,
    bool? manualOpen,
    String? restaurantPhone,
    String? restaurantAddress,
    double? restaurantLat,
    double? restaurantLng,
    double? paymentFeePercent,
    double? paymentFeePercentSettings,
    int? momoUnpaidCancelMinutes,
    bool? hoursEnabled,
    Map<String, List<List<String>>>? openingHours,
    String? deliveryFeeMode,
    int? deliveryFeePerKm,
    double? deliveryFreeKm,
    double? deliveryMaxKm,
  }) =>
      AppSettings(
        deliveryFee: deliveryFee ?? this.deliveryFee,
        minOrder: minOrder ?? this.minOrder,
        isOpen: isOpen,
        manualOpen: manualOpen ?? this.manualOpen,
        restaurantPhone: restaurantPhone ?? this.restaurantPhone,
        restaurantAddress: restaurantAddress ?? this.restaurantAddress,
        restaurantLat: restaurantLat ?? this.restaurantLat,
        restaurantLng: restaurantLng ?? this.restaurantLng,
        otpRequired: otpRequired,
        termsVersion: termsVersion,
        termsUrl: termsUrl,
        privacyUrl: privacyUrl,
        paymentFeePercent: paymentFeePercent ?? this.paymentFeePercent,
        paymentFeePercentByOperator: paymentFeePercentByOperator,
        paymentFeeSource: paymentFeeSource,
        paymentFeePercentSettings: paymentFeePercentSettings ?? this.paymentFeePercentSettings,
        paymentMode: paymentMode,
        paymentProvider: paymentProvider,
        maxQuantityPerItem: maxQuantityPerItem,
        momoUnpaidCancelMinutes: momoUnpaidCancelMinutes ?? this.momoUnpaidCancelMinutes,
        hoursEnabled: hoursEnabled ?? this.hoursEnabled,
        openingHours: openingHours ?? this.openingHours,
        nextOpeningAt: nextOpeningAt,
        nextClosingAt: nextClosingAt,
        deliveryFeeMode: deliveryFeeMode ?? this.deliveryFeeMode,
        deliveryFeePerKm: deliveryFeePerKm ?? this.deliveryFeePerKm,
        deliveryFreeKm: deliveryFreeKm ?? this.deliveryFreeKm,
        deliveryMaxKm: deliveryMaxKm ?? this.deliveryMaxKm,
      );
}
