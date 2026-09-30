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

  AppUser({required this.id, required this.name, required this.phone, this.email, required this.role, this.address});

  bool get isAdmin => role == 'admin';

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: _int(j['id']),
        name: j['name'] ?? '',
        phone: j['phone'] ?? '',
        email: j['email'],
        role: j['role'] ?? 'customer',
        address: j['address'],
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
  final String paymentStatus; // 'unpaid', 'pending', 'paid', 'failed'
  final String? paymentReference;
  final double? deliveryLat;
  final double? deliveryLng;
  final double? deliveryAccuracy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String customerName;
  final List<OrderItem> items;
  final String? payUrl;

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
  });

  bool get isDelivery => mode == 'delivery';
  bool get isFinished => status == 'delivered' || status == 'cancelled';
  bool get needsPayment => paymentStatus == 'pending' || paymentStatus == 'failed';
  bool get isPaid => paymentStatus == 'paid';
  int get itemCount => items.fold(0, (s, i) => s + i.quantity);
  bool get hasLocation => deliveryLat != null && deliveryLng != null;

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
      );
}

class AppSettings {
  final int deliveryFee;
  final int minOrder;
  final bool isOpen;
  final String restaurantPhone;
  final String restaurantAddress;
  final double paymentFeePercent;
  final String paymentMode; // 'test' ou 'live'

  AppSettings({
    required this.deliveryFee,
    required this.minOrder,
    required this.isOpen,
    required this.restaurantPhone,
    required this.restaurantAddress,
    this.paymentFeePercent = 2,
    this.paymentMode = 'test',
  });

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        deliveryFee: _int(j['delivery_fee']),
        minOrder: _int(j['min_order']),
        isOpen: j['is_open'] == true,
        restaurantPhone: j['restaurant_phone'] ?? '',
        restaurantAddress: j['restaurant_address'] ?? '',
        paymentFeePercent: (j['payment_fee_percent'] as num?)?.toDouble() ?? 2,
        paymentMode: j['payment_mode'] ?? 'test',
      );

  Map<String, dynamic> toJson() => {
        'delivery_fee': deliveryFee,
        'min_order': minOrder,
        'is_open': isOpen,
        'restaurant_phone': restaurantPhone,
        'restaurant_address': restaurantAddress,
        'payment_fee_percent': paymentFeePercent,
        'payment_mode': paymentMode,
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
