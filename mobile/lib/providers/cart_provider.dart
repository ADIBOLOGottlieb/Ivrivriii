import 'package:flutter/foundation.dart';

import '../models.dart';

class CartLine {
  final Product product;
  int quantity;
  CartLine(this.product, this.quantity);

  int get total => product.price * quantity;
}

class CartProvider extends ChangeNotifier {
  final Map<int, CartLine> _lines = {};

  List<CartLine> get lines => _lines.values.toList();
  bool get isEmpty => _lines.isEmpty;
  int get count => _lines.values.fold(0, (s, l) => s + l.quantity);
  int get subtotal => _lines.values.fold(0, (s, l) => s + l.total);

  int quantityOf(int productId) => _lines[productId]?.quantity ?? 0;

  void add(Product p, [int qty = 1]) {
    final line = _lines[p.id];
    if (line == null) {
      _lines[p.id] = CartLine(p, qty);
    } else {
      line.quantity = (line.quantity + qty).clamp(1, 50);
    }
    notifyListeners();
  }

  void setQuantity(int productId, int qty) {
    if (qty <= 0) {
      _lines.remove(productId);
    } else if (_lines[productId] != null) {
      _lines[productId]!.quantity = qty.clamp(1, 50);
    }
    notifyListeners();
  }

  void remove(int productId) {
    _lines.remove(productId);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }

  List<Map<String, dynamic>> toOrderItems() =>
      _lines.values.map((l) => {'product_id': l.product.id, 'quantity': l.quantity}).toList();
}
