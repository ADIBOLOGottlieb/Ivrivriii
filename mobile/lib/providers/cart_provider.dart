import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../utils/format.dart' show maxQuantityPerItem;

class CartLine {
  final Product product;
  int quantity;
  CartLine(this.product, this.quantity);

  int get total => product.price * quantity;
}

/// Panier du client. Gardé sur le téléphone (shared_preferences), un panier par compte :
/// il survit à la fermeture de l'app et n'est jamais montré à un autre compte.
class CartProvider extends ChangeNotifier {
  static const _keyPrefix = 'cart_v1_';

  final Map<int, CartLine> _lines = {};

  /// Compte auquel le panier est rattaché (null : déconnecté, rien n'est enregistré).
  int? _userId;

  List<CartLine> get lines => _lines.values.toList();
  bool get isEmpty => _lines.isEmpty;
  int get count => _lines.values.fold(0, (s, l) => s + l.quantity);
  int get subtotal => _lines.values.fold(0, (s, l) => s + l.total);

  int quantityOf(int productId) => _lines[productId]?.quantity ?? 0;

  void add(Product p, [int qty = 1]) {
    if (qty <= 0) return;
    final line = _lines[p.id];
    if (line == null) {
      _lines[p.id] = CartLine(p, qty.clamp(1, maxQuantityPerItem));
    } else {
      line.quantity = (line.quantity + qty).clamp(1, maxQuantityPerItem);
    }
    _changed();
  }

  void setQuantity(int productId, int qty) {
    if (qty <= 0) {
      _lines.remove(productId);
    } else if (_lines[productId] != null) {
      _lines[productId]!.quantity = qty.clamp(1, maxQuantityPerItem);
    }
    _changed();
  }

  void remove(int productId) {
    _lines.remove(productId);
    _changed();
  }

  /// Vide le panier (et sa copie enregistrée pour le compte courant).
  void clear() {
    _lines.clear();
    _changed();
  }

  List<Map<String, dynamic>> toOrderItems() =>
      _lines.values.map((l) => {'product_id': l.product.id, 'quantity': l.quantity}).toList();

  // ---------- Compte & persistance ----------

  /// Rattache le panier au compte [userId] et recharge son panier enregistré.
  /// Sans effet si le panier est déjà celui de ce compte.
  Future<void> attachUser(int userId) async {
    if (_userId == userId) return;
    _userId = userId;
    _lines.clear();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_keyPrefix$userId');
      if (_userId != userId || raw == null) return; // compte changé entre-temps
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final e in list) {
        if (e is! Map) continue;
        final p = Product.fromJson(Map<String, dynamic>.from(e));
        final q = e['quantity'];
        final qty = q is int ? q : int.tryParse('$q') ?? 0;
        if (p.id <= 0 || qty <= 0) continue;
        // Ce qui a été ajouté pendant le chargement est prioritaire.
        _lines.putIfAbsent(p.id, () => CartLine(p, qty.clamp(1, maxQuantityPerItem)));
      }
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('[Cart] Panier enregistré illisible : $e');
    }
  }

  /// Déconnexion : vide le panier, supprime sa copie enregistrée et détache le compte.
  void reset() {
    clear();
    _userId = null;
  }

  /// Revalide le panier avec le catalogue client complet qui vient d'être chargé :
  /// prix mis à jour, produits supprimés ou indisponibles retirés.
  /// Renvoie un message à afficher au client, ou null si rien n'a changé.
  String? syncWithCatalog(List<Product> catalog) {
    if (_lines.isEmpty) return null;
    final byId = {for (final p in catalog) p.id: p};
    final removed = <String>[];
    var repriced = 0;
    var changed = false;
    for (final id in _lines.keys.toList()) {
      final line = _lines[id]!;
      final fresh = byId[id];
      if (fresh == null || !fresh.available) {
        removed.add(line.product.name);
        _lines.remove(id);
        changed = true;
        continue;
      }
      if (fresh.price != line.product.price) repriced++;
      if (fresh.price != line.product.price ||
          fresh.name != line.product.name ||
          fresh.imageUrl != line.product.imageUrl) {
        _lines[id] = CartLine(fresh, line.quantity);
        changed = true;
      }
    }
    if (!changed) return null;
    _changed();

    final parts = <String>[];
    if (removed.length == 1) {
      parts.add('« ${removed.first} » n\'est plus disponible : retiré du panier.');
    } else if (removed.length > 1) {
      parts.add('${removed.length} articles ne sont plus disponibles : retirés du panier.');
    }
    if (repriced == 1) {
      parts.add('Le prix d\'un article du panier a changé.');
    } else if (repriced > 1) {
      parts.add('Le prix de $repriced articles du panier a changé.');
    }
    return parts.isEmpty ? null : parts.join(' ');
  }

  void _changed() {
    notifyListeners();
    unawaited(_save());
  }

  /// Enregistre le panier du compte courant (supprime la copie s'il est vide).
  Future<void> _save() async {
    final userId = _userId;
    if (userId == null) return;
    final data = _lines.values
        .map((l) => {...l.product.toJson(), 'id': l.product.id, 'quantity': l.quantity})
        .toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (data.isEmpty) {
        await prefs.remove('$_keyPrefix$userId');
      } else {
        await prefs.setString('$_keyPrefix$userId', jsonEncode(data));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Cart] Enregistrement impossible : $e');
    }
  }
}
