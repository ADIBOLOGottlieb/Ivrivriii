import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';

/// Performance-optimized cache manager for app data.
/// Handles TTL-based expiration, offline fallback, and batch invalidation.
class CacheManager {
  static final CacheManager _instance = CacheManager._();
  factory CacheManager() => _instance;
  CacheManager._();

  late SharedPreferences _prefs;
  final Map<String, DateTime> _expiry = {};

  /// Initialize the cache manager (call once at app startup).
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _loadExpiry();
  }

  /// Cache settings with 1 hour TTL (restaurant info changes infrequently).
  Future<void> setSettings(String key, dynamic data, {Duration ttl = const Duration(hours: 1)}) =>
      _set('settings_$key', data, ttl);

  /// Get cached settings (returns null if expired).
  dynamic getSettings(String key) => _get('settings_$key');

  /// Cache categories with 12 hours TTL.
  Future<void> setCategories(String key, dynamic data, {Duration ttl = const Duration(hours: 12)}) =>
      _set('categories_$key', data, ttl);

  dynamic getCategories(String key) => _get('categories_$key');

  /// Cache products with 6 hours TTL.
  Future<void> setProducts(String key, dynamic data, {Duration ttl = const Duration(hours: 6)}) =>
      _set('products_$key', data, ttl);

  dynamic getProducts(String key) => _get('products_$key');

  /// Cache order list with 5 minute TTL (frequently changes).
  Future<void> setOrders(String key, dynamic data, {Duration ttl = const Duration(minutes: 5)}) =>
      _set('orders_$key', data, ttl);

  dynamic getOrders(String key) => _get('orders_$key');

  /// Cache single order with 2 minute TTL.
  Future<void> setOrder(int id, dynamic data, {Duration ttl = const Duration(minutes: 2)}) =>
      _set('order_$id', data, ttl);

  dynamic getOrder(int id) => _get('order_$id');

  /// Internal cache set with TTL tracking.
  Future<void> _set(String key, dynamic data, Duration ttl) async {
    try {
      if (data is String) {
        await _prefs.setString(key, data);
      } else {
        await _prefs.setString(key, jsonEncode(data));
      }
      // Track expiry time
      _expiry[key] = DateTime.now().add(ttl);
      _saveExpiry();
    } catch (e) {
      // Silently fail on cache write errors
      debugPrint('Cache write failed for $key: $e');
    }
  }

  /// Internal cache get (respects TTL).
  dynamic _get(String key) {
    try {
      final expiry = _expiry[key];
      if (expiry != null && DateTime.now().isAfter(expiry)) {
        // Expired - remove and return null
        _prefs.remove(key);
        _expiry.remove(key);
        _saveExpiry();
        return null;
      }

      final cached = _prefs.getString(key);
      if (cached == null) return null;

      // Try parsing as JSON, fallback to string
      try {
        return jsonDecode(cached);
      } catch (_) {
        return cached;
      }
    } catch (e) {
      debugPrint('Cache read failed for $key: $e');
      return null;
    }
  }

  /// Clear all cache for a specific category.
  Future<void> clearCategory(String category) async {
    final keys = _prefs.getKeys().where((k) => k.startsWith('${category}_')).toList();
    for (final key in keys) {
      await _prefs.remove(key);
      _expiry.remove(key);
    }
    _saveExpiry();
  }

  /// Clear all cache.
  Future<void> clearAll() async {
    await _prefs.clear();
    _expiry.clear();
  }

  /// Save expiry map to persistent storage.
  void _saveExpiry() {
    try {
      final expiry = _expiry.map((k, v) => MapEntry(k, v.toIso8601String()));
      _prefs.setString('_expiry_map', jsonEncode(expiry));
    } catch (_) {
      // Silently fail
    }
  }

  /// Load expiry map from persistent storage.
  void _loadExpiry() {
    try {
      final stored = _prefs.getString('_expiry_map');
      if (stored != null) {
        final map = jsonDecode(stored) as Map<String, dynamic>;
        _expiry.clear();
        map.forEach((k, v) {
          _expiry[k] = DateTime.parse(v as String);
        });
      }
    } catch (_) {
      // Silently fail
    }
  }
}
