DateTime _parseDate(dynamic v) {
  // SQLite renvoie "YYYY-MM-DD HH:MM:SS" en UTC.
  if (v is! String) return DateTime.now();
  return DateTime.tryParse('${v.replaceFirst(' ', 'T')}Z')?.toLocal() ?? DateTime.now();
}

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

class AppUser {
  final int id;
  final String name;
  final String phone;
  final String? email;
  final String role;
  final String? address;
  final String? avatarUrl; // chemin relatif (/uploads/...) : passer par resolveImageUrl
  final String? momoPhone; // numéro mobile money préféré, pré-rempli au paiement

  AppUser({
    required this.id,
    required this.name,
    required this.phone,
    this.email,
    required this.role,
    this.address,
    this.avatarUrl,
    this.momoPhone,
  });

  bool get isAdmin => role == 'admin';
  bool get isDriver => role == 'driver';

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: _int(j['id']),
        name: j['name'] ?? '',
        phone: j['phone'] ?? '',
        email: j['email'],
        role: j['role'] ?? 'customer',
        address: j['address'],
        avatarUrl: j['avatar_url'],
        momoPhone: j['momo_phone'],
      );
}

/// Adresse enregistrée par le client (Maison, Bureau...), réutilisable à la commande.
class SavedAddress {
  final int id;
  final String label;
  final String address;
  final double? lat;
  final double? lng;

  SavedAddress({required this.id, required this.label, required this.address, this.lat, this.lng});

  bool get hasLocation => lat != null && lng != null;

  factory SavedAddress.fromJson(Map<String, dynamic> j) => SavedAddress(
        id: _int(j['id']),
        label: j['label'] ?? '',
        address: j['address'] ?? '',
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {'label': label, 'address': address, 'lat': lat, 'lng': lng};
}

/// Tentative de paiement mobile money (push USSD : le client tape son code PIN sur son téléphone).
class PaymentAttempt {
  final int id;
  final String status; // pending, paid, failed, expired, rejected
  final String provider; // simulation, paygate, kadev...
  final String operator; // flooz, mixx
  final int amount;
  final String? phone;
  final String? message; // explication lisible (refus, montant incorrect...)
  final bool simulated;
  final DateTime? expiresAt;

  PaymentAttempt({
    required this.id,
    required this.status,
    required this.provider,
    required this.operator,
    required this.amount,
    this.phone,
    this.message,
    this.simulated = false,
    this.expiresAt,
  });

  bool get isPending => status == 'pending';
  bool get isPaid => status == 'paid';

  factory PaymentAttempt.fromJson(Map<String, dynamic> j) => PaymentAttempt(
        id: _int(j['id']),
        status: j['status'] ?? 'pending',
        provider: j['provider'] ?? '',
        operator: j['operator'] ?? '',
        amount: _int(j['amount']),
        phone: j['phone'],
        message: j['message'],
        simulated: j['simulated'] == true,
        expiresAt: j['expires_at'] == null ? null : _parseDate(j['expires_at']),
      );
}

class Category {
  final int id;
  final String name;
  final String? icon;
  final int position;

  Category({required this.id, required this.name, this.icon, this.position = 0});

  factory Category.fromJson(Map<String, dynamic> j) =>
      Category(id: _int(j['id']), name: j['name'] ?? '', icon: j['icon'], position: _int(j['position']));

  Map<String, dynamic> toJson() => {'name': name, 'icon': icon, 'position': position};
}

class Product {
  final int id;
  final int? categoryId;
  final String name;
  final String? description;
  final int price;
  final String? imageUrl;
  final bool available;
  final bool popular;

  Product({
    required this.id,
    this.categoryId,
    required this.name,
    this.description,
    required this.price,
    this.imageUrl,
    this.available = true,
    this.popular = false,
  });

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: _int(j['id']),
        categoryId: j['category_id'] == null ? null : _int(j['category_id']),
        name: j['name'] ?? '',
        description: j['description'],
        price: _int(j['price']),
        imageUrl: j['image_url'],
        available: j['available'] == true || j['available'] == 1,
        popular: j['popular'] == true || j['popular'] == 1,
      );

  Map<String, dynamic> toJson() => {
        'category_id': categoryId,
        'name': name,
        'description': description,
        'price': price,
        'image_url': imageUrl,
        'available': available,
        'popular': popular,
      };
}

class OrderItem {
  final int? productId;
  final String name;
  final int unitPrice;
  final int quantity;

  OrderItem({this.productId, required this.name, required this.unitPrice, required this.quantity});

  int get total => unitPrice * quantity;

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        productId: j['product_id'] == null ? null : _int(j['product_id']),
        name: j['name'] ?? '',
        unitPrice: _int(j['unit_price']),
        quantity: _int(j['quantity']),
      );
}

class Order {
  final int id;
  final int userId;
  final String status;
  final String mode;
  final String? address;
  final String phone;
  final String? note;
  final String paymentMethod;
  final int subtotal;
  final int deliveryFee;
  final int paymentFee;
  final int total;
  final String paymentStatus; // unpaid, pending, paid, failed, expired, refunded
  final String? paymentReference;
  final double? deliveryLat;
  final double? deliveryLng;
  final double? deliveryAccuracy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String customerName;
  final List<OrderItem> items;
  final String? payUrl;
  // Livraison : livreur attribué, prise en charge, « Livraison faite » (livreur), « Reçu » (client).
  final int? driverId;
  final String? driverName;
  final String? driverPhone;
  final DateTime? pickedUpAt;
  final DateTime? driverDeliveredAt;
  final DateTime? receivedAt;

  Order({
    required this.id,
    required this.userId,
    required this.status,
    required this.mode,
    this.address,
    required this.phone,
    this.note,
    required this.paymentMethod,
    required this.subtotal,
    required this.deliveryFee,
    this.paymentFee = 0,
    required this.total,
    this.paymentStatus = 'unpaid',
    this.paymentReference,
    this.deliveryLat,
    this.deliveryLng,
    this.deliveryAccuracy,
    required this.createdAt,
    required this.updatedAt,
    required this.customerName,
    required this.items,
    this.payUrl,
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.pickedUpAt,
    this.driverDeliveredAt,
    this.receivedAt,
  });

  bool get isDelivery => mode == 'delivery';
  bool get isFinished => status == 'delivered' || status == 'cancelled';
  bool get isCancelled => status == 'cancelled';
  bool get needsPayment => paymentStatus == 'pending' || paymentFailed;
  bool get isPaid => paymentStatus == 'paid';
  bool get isRefunded => paymentStatus == 'refunded';

  /// Dernière tentative mobile money refusée, abandonnée ou expirée.
  bool get paymentFailed => paymentStatus == 'failed' || paymentStatus == 'expired';
  int get itemCount => items.fold(0, (s, i) => s + i.quantity);
  bool get hasLocation => deliveryLat != null && deliveryLng != null;
  bool get hasDriver => driverId != null;
  /// Le livreur a indiqué « Livraison faite » : on attend le « Reçu » du client.
  bool get awaitingReceipt => status == 'delivering' && driverDeliveredAt != null;

  factory Order.fromJson(Map<String, dynamic> j) => Order(
        id: _int(j['id']),
        userId: _int(j['user_id']),
        status: j['status'] ?? 'pending',
        mode: j['mode'] ?? 'delivery',
        address: j['address'],
        phone: j['phone'] ?? '',
        note: j['note'],
        paymentMethod: j['payment_method'] ?? 'cash',
        subtotal: _int(j['subtotal']),
        deliveryFee: _int(j['delivery_fee']),
        paymentFee: _int(j['payment_fee']),
        total: _int(j['total']),
        paymentStatus: j['payment_status'] ?? 'unpaid',
        paymentReference: j['payment_reference'],
        deliveryLat: j['delivery_lat'] is num ? (j['delivery_lat'] as num).toDouble() : null,
        deliveryLng: j['delivery_lng'] is num ? (j['delivery_lng'] as num).toDouble() : null,
        deliveryAccuracy: j['delivery_accuracy'] is num ? (j['delivery_accuracy'] as num).toDouble() : null,
        createdAt: _parseDate(j['created_at']),
        updatedAt: _parseDate(j['updated_at']),
        customerName: j['customer_name'] ?? '',
        items: ((j['items'] as List?) ?? []).map((e) => OrderItem.fromJson(e)).toList(),
        payUrl: j['pay_url'],
        driverId: j['driver_id'] == null ? null : _int(j['driver_id']),
        driverName: j['driver_name'],
        driverPhone: j['driver_phone'],
        pickedUpAt: j['picked_up_at'] == null ? null : _parseDate(j['picked_up_at']),
        driverDeliveredAt: j['driver_delivered_at'] == null ? null : _parseDate(j['driver_delivered_at']),
        receivedAt: j['received_at'] == null ? null : _parseDate(j['received_at']),
      );
}

/// Livreur (vue admin).
class Driver {
  final int id;
  final String name;
  final String phone;
  final bool active;
  final int activeDeliveries; // en cours
  final int deliveredCount; // total livrées

  Driver({
    required this.id,
    required this.name,
    required this.phone,
    this.active = true,
    this.activeDeliveries = 0,
    this.deliveredCount = 0,
  });

  factory Driver.fromJson(Map<String, dynamic> j) => Driver(
        id: _int(j['id']),
        name: j['name'] ?? '',
        phone: j['phone'] ?? '',
        active: j['active'] == true || j['active'] == 1,
        activeDeliveries: _int(j['active_deliveries']),
        deliveredCount: _int(j['delivered_count']),
      );
}

class AppSettings {
  final int deliveryFee;
  final int minOrder;
  final bool isOpen;
  final String restaurantPhone;
  final String restaurantAddress;
  // Position du restaurant (départ des itinéraires de livraison) ; null tant que l'admin ne l'a pas placée.
  final double? restaurantLat;
  final double? restaurantLng;
  /// Taux Flooz (compatibilité) : préférer [feePercentFor].
  final double paymentFeePercent;
  /// Taux des frais par opérateur ('flooz', 'mixx') = commission de l'agrégateur ou réglage admin.
  final Map<String, double> paymentFeePercentByOperator;
  /// 'aggregator' (commission fixée par le contrat PayGate/KADEV) ou 'settings' (réglage admin).
  final String paymentFeeSource;
  /// Réglage admin des frais (utilisé seulement si la source est 'settings').
  final double? paymentFeePercentSettings;
  final String paymentMode; // 'test' ou 'live'
  final String paymentProvider; // simulation, paygate, kadev...
  final int maxQuantityPerItem;
  final int momoUnpaidCancelMinutes; // annulation auto d'une commande mobile money non payée

  AppSettings({
    required this.deliveryFee,
    required this.minOrder,
    required this.isOpen,
    required this.restaurantPhone,
    required this.restaurantAddress,
    this.restaurantLat,
    this.restaurantLng,
    this.paymentFeePercent = 2,
    Map<String, double>? paymentFeePercentByOperator,
    this.paymentFeeSource = 'settings',
    this.paymentFeePercentSettings,
    this.paymentMode = 'test',
    this.paymentProvider = 'simulation',
    this.maxQuantityPerItem = 999,
    this.momoUnpaidCancelMinutes = 30,
  }) : paymentFeePercentByOperator =
            paymentFeePercentByOperator ?? {'flooz': paymentFeePercent, 'mixx': paymentFeePercent};

  /// Frais fixés par l'agrégateur : le réglage admin ne s'applique pas.
  bool get feesFromAggregator => paymentFeeSource == 'aggregator';

  /// Taux des frais (en %) pour un moyen de paiement mobile money.
  double feePercentFor(String method) => paymentFeePercentByOperator[method] ?? paymentFeePercent;

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final percent = (j['payment_fee_percent'] as num?)?.toDouble() ?? 2;
    final rawByOp = j['payment_fee_percent_by_operator'];
    final byOp = <String, double>{'flooz': percent, 'mixx': percent};
    if (rawByOp is Map) {
      rawByOp.forEach((k, v) {
        if (v is num) byOp['$k'] = v.toDouble();
      });
    }
    return AppSettings(
      deliveryFee: _int(j['delivery_fee']),
      minOrder: _int(j['min_order']),
      isOpen: j['is_open'] == true,
      restaurantPhone: j['restaurant_phone'] ?? '',
      restaurantAddress: j['restaurant_address'] ?? '',
      restaurantLat: (j['restaurant_lat'] as num?)?.toDouble(),
      restaurantLng: (j['restaurant_lng'] as num?)?.toDouble(),
      paymentFeePercent: percent,
      paymentFeePercentByOperator: byOp,
      paymentFeeSource: j['payment_fee_source'] == 'aggregator' ? 'aggregator' : 'settings',
      paymentFeePercentSettings: (j['payment_fee_percent_settings'] as num?)?.toDouble(),
      paymentMode: j['payment_mode'] ?? 'test',
      paymentProvider: j['payment_provider'] ?? 'simulation',
      maxQuantityPerItem: j['max_quantity_per_item'] == null ? 999 : _int(j['max_quantity_per_item']),
      momoUnpaidCancelMinutes:
          j['momo_unpaid_cancel_minutes'] == null ? 30 : _int(j['momo_unpaid_cancel_minutes']),
    );
  }

  Map<String, dynamic> toJson() => {
        'delivery_fee': deliveryFee,
        'min_order': minOrder,
        'is_open': isOpen,
        'restaurant_phone': restaurantPhone,
        'restaurant_address': restaurantAddress,
        'restaurant_lat': restaurantLat,
        'restaurant_lng': restaurantLng,
        // Frais fixés par l'agrégateur : on ne renvoie pas le taux (sinon il écraserait le réglage admin).
        if (!feesFromAggregator) 'payment_fee_percent': paymentFeePercentSettings ?? paymentFeePercent,
        'payment_mode': paymentMode,
        'momo_unpaid_cancel_minutes': momoUnpaidCancelMinutes,
      };
}

class DailyStat {
  final String day;
  final int orders;
  final int revenue;
  DailyStat(this.day, this.orders, this.revenue);
}

class TopProduct {
  final String name;
  final int quantity;
  final int revenue;
  TopProduct(this.name, this.quantity, this.revenue);
}

class AdminStats {
  final int todayOrders;
  final int todayRevenue;
  final int deliveredOrders;
  final int deliveredRevenue;
  final int active;
  final int pending;
  final int customers;
  final List<TopProduct> topProducts;
  final List<DailyStat> last7Days;

  AdminStats({
    required this.todayOrders,
    required this.todayRevenue,
    required this.deliveredOrders,
    required this.deliveredRevenue,
    required this.active,
    required this.pending,
    required this.customers,
    required this.topProducts,
    required this.last7Days,
  });

  factory AdminStats.fromJson(Map<String, dynamic> j) => AdminStats(
        todayOrders: _int(j['today']?['orders']),
        todayRevenue: _int(j['today']?['revenue']),
        deliveredOrders: _int(j['total']?['orders']),
        deliveredRevenue: _int(j['total']?['revenue']),
        active: _int(j['active']),
        pending: _int(j['pending']),
        customers: _int(j['customers']),
        topProducts: ((j['topProducts'] as List?) ?? [])
            .map((e) => TopProduct(e['name'] ?? '', _int(e['quantity']), _int(e['revenue'])))
            .toList(),
        last7Days: ((j['last7Days'] as List?) ?? [])
            .map((e) => DailyStat(e['day'] ?? '', _int(e['orders']), _int(e['revenue'])))
            .toList(),
      );
}

class CustomerSummary {
  final AppUser user;
  final int ordersCount;
  final int totalSpent;
  final DateTime createdAt;

  CustomerSummary(this.user, this.ordersCount, this.totalSpent, this.createdAt);

  factory CustomerSummary.fromJson(Map<String, dynamic> j) => CustomerSummary(
        AppUser.fromJson(j),
        _int(j['orders_count']),
        _int(j['total_spent']),
        _parseDate(j['created_at']),
      );
}
