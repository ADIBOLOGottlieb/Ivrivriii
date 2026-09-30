import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config.dart';
import '../models.dart';

/// Custom exception for API errors with detailed information
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final bool isRetryable;
  final dynamic originalError;

  ApiException(
    this.message, [
    this.statusCode,
    this.isRetryable = false,
    this.originalError,
  ]);

  /// Returns true if this error is due to network issues (5xx, timeout, socket errors)
  bool get isNetworkError => isRetryable;

  /// Returns true if the error is due to client issues (4xx)
  bool get isClientError => statusCode != null && statusCode! >= 400 && statusCode! < 500;

  /// Returns true if the error is a server error (5xx)
  bool get isServerError => statusCode != null && statusCode! >= 500;

  @override
  String toString() => message;
}

/// Circuit breaker pattern to prevent cascading failures
class CircuitBreaker {
  static const int failureThreshold = 5;
  static const Duration resetTimeout = Duration(minutes: 1);

  int _failureCount = 0;
  DateTime? _lastFailureTime;
  bool _isOpen = false;

  bool get isOpen => _isOpen;

  /// Record a failure and update circuit state
  void recordFailure() {
    _failureCount++;
    _lastFailureTime = DateTime.now();

    if (_failureCount >= failureThreshold) {
      _isOpen = true;
      debugPrint('[CircuitBreaker] Circuit opened after $_failureCount failures');
    }
  }

  /// Record a success and reset the circuit
  void recordSuccess() {
    _failureCount = 0;
    _isOpen = false;
  }

  /// Check if the circuit should be reset
  bool shouldReset() {
    if (!_isOpen) return false;

    final timeSinceLastFailure = DateTime.now().difference(_lastFailureTime ?? DateTime.now());
    if (timeSinceLastFailure > resetTimeout) {
      _isOpen = false;
      _failureCount = 0;
      debugPrint('[CircuitBreaker] Circuit reset after timeout');
      return true;
    }
    return false;
  }
}

/// Cache entry with TTL (Time To Live)
class CacheEntry<T> {
  final T data;
  final DateTime timestamp;
  final Duration ttl;

  CacheEntry(this.data, this.ttl) : timestamp = DateTime.now();

  bool get isExpired => DateTime.now().difference(timestamp) > ttl;
}

/// Simple cache with TTL support
class ApiCache {
  final Map<String, CacheEntry> _cache = {};

  /// Cache a value with TTL
  void set<T>(String key, T value, Duration ttl) {
    _cache[key] = CacheEntry(value, ttl);
    debugPrint('[Cache] Cached $key (TTL: ${ttl.inSeconds}s)');
  }

  /// Retrieve a cached value if it hasn't expired
  T? get<T>(String key) {
    final entry = _cache[key];
    if (entry == null) {
      debugPrint('[Cache] Cache miss: $key');
      return null;
    }

    if (entry.isExpired) {
      debugPrint('[Cache] Cache expired: $key');
      _cache.remove(key);
      return null;
    }

    debugPrint('[Cache] Cache hit: $key');
    return entry.data as T;
  }

  /// Clear the entire cache
  void clear() {
    _cache.clear();
    debugPrint('[Cache] Cache cleared');
  }

  /// Clear a specific cache entry
  void remove(String key) {
    _cache.remove(key);
  }
}

class Api {
  Api._();
  static final Api instance = Api._();

  String? token;
  late final CircuitBreaker _circuitBreaker = CircuitBreaker();
  late final ApiCache _cache = ApiCache();

  // Retry configuration
  static const int _maxRetries = 3;
  static const int _baseDelayMs = 200;
  static const int _maxDelayMs = 500;
  static const Duration _requestTimeout = Duration(seconds: 15);

  /// Called when the server responds with 401 (expired session)
  void Function()? onUnauthorized;

  /// Called to log API events for debugging
  void Function(String message)? onLog;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$apiBaseUrl/api$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  /// Log API events for debugging
  void _log(String message) {
    debugPrint('[API] $message');
    onLog?.call(message);
  }

  /// Determine if an error is retryable
  bool _isRetryable(dynamic error, int? statusCode) {
    // Retry on socket errors (no internet)
    if (error is SocketException) return true;

    // Retry on timeout errors
    if (error is TimeoutException) return true;

    // Retry on 5xx errors (server errors)
    if (statusCode != null && statusCode >= 500) return true;

    // Retry on 429 (rate limit)
    if (statusCode == 429) return true;

    // Don't retry on 4xx errors except 429
    if (statusCode != null && statusCode >= 400 && statusCode < 500) return false;

    return false;
  }

  /// Calculate exponential backoff delay with jitter
  Duration _calculateBackoff(int attemptNumber) {
    // Exponential backoff: 200ms * 2^attempt, capped at 500ms
    final delay = (_baseDelayMs * (1 << attemptNumber)).clamp(0, _maxDelayMs);
    // Add jitter (±20%)
    final jitter = (delay * 0.2 * (2 * (DateTime.now().millisecondsSinceEpoch % 100) / 100 - 1)).toInt();
    return Duration(milliseconds: delay + jitter);
  }

  /// Send HTTP request with retry logic and error handling
  Future<dynamic> _send(Future<http.Response> Function() request) async {
    // Check circuit breaker
    if (_circuitBreaker.isOpen) {
      if (!_circuitBreaker.shouldReset()) {
        _log('Circuit breaker is open - rejecting request');
        throw ApiException(
          'Le service est temporairement indisponible. Réessayez dans quelques instants.',
          503,
          false,
        );
      }
    }

    http.Response res;
    dynamic lastError;
    int? lastStatusCode;

    // Retry loop
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        _log('Request attempt ${attempt + 1}/$_maxRetries');

        // Send request with timeout
        res = await request().timeout(_requestTimeout);

        // Parse response body
        dynamic body;
        if (res.body.isNotEmpty) {
          try {
            body = jsonDecode(utf8.decode(res.bodyBytes));
          } catch (e) {
            _log('Failed to parse response body: $e');
            body = null;
          }
        }

        // Handle success
        if (res.statusCode >= 200 && res.statusCode < 300) {
          _circuitBreaker.recordSuccess();
          _log('Request successful (${res.statusCode})');
          return body;
        }

        // Handle 401 - Unauthorized
        if (res.statusCode == 401 && token != null) {
          _log('Received 401 - triggering logout');
          onUnauthorized?.call();
          _circuitBreaker.recordFailure();
          final msg = body is Map && body['error'] is String
              ? body['error'] as String
              : 'Session expirée. Veuillez vous reconnecter.';
          throw ApiException(msg, res.statusCode, false);
        }

        // Check if error is retryable
        lastStatusCode = res.statusCode;
        lastError = ApiException(
          body is Map && body['error'] is String
              ? body['error'] as String
              : 'Erreur (${res.statusCode})',
          res.statusCode,
          _isRetryable(null, res.statusCode),
        );

        if (!_isRetryable(null, res.statusCode)) {
          _circuitBreaker.recordFailure();
          throw lastError;
        }

        // This is a retryable error - log and retry
        _log('Retryable error (${res.statusCode}) - will retry');

        if (attempt < _maxRetries - 1) {
          final backoff = _calculateBackoff(attempt);
          _log('Waiting ${backoff.inMilliseconds}ms before retry...');
          await Future.delayed(backoff);
        }
      } on SocketException catch (e) {
        _log('SocketException: $e');
        lastError = ApiException(
          'Impossible de joindre le serveur. Vérifiez votre connexion.',
          null,
          true,
          e,
        );

        if (attempt < _maxRetries - 1) {
          final backoff = _calculateBackoff(attempt);
          _log('Waiting ${backoff.inMilliseconds}ms before retry...');
          await Future.delayed(backoff);
        } else {
          _circuitBreaker.recordFailure();
          throw lastError;
        }
      } on TimeoutException catch (e) {
        _log('TimeoutException: $e');
        lastError = ApiException(
          'Le serveur ne répond pas. Vérifiez votre connexion.',
          null,
          true,
          e,
        );

        if (attempt < _maxRetries - 1) {
          final backoff = _calculateBackoff(attempt);
          _log('Waiting ${backoff.inMilliseconds}ms before retry...');
          await Future.delayed(backoff);
        } else {
          _circuitBreaker.recordFailure();
          throw lastError;
        }
      } on http.ClientException catch (e) {
        _log('ClientException: $e');
        lastError = ApiException(
          'Impossible de joindre le serveur. Vérifiez votre connexion.',
          null,
          true,
          e,
        );

        if (attempt < _maxRetries - 1) {
          final backoff = _calculateBackoff(attempt);
          _log('Waiting ${backoff.inMilliseconds}ms before retry...');
          await Future.delayed(backoff);
        } else {
          _circuitBreaker.recordFailure();
          throw lastError;
        }
      }
    }

    // All retries exhausted
    _circuitBreaker.recordFailure();
    _log('All retry attempts exhausted');
    throw lastError ??
        ApiException(
          'Erreur réseau - impossible de joindre le serveur.',
          lastStatusCode,
          true,
        );
  }

  /// GET request with optional caching
  Future<dynamic> get(String path, [Map<String, String>? query]) =>
      _send(() => http.get(_uri(path, query), headers: _headers));

  /// POST request (not cached)
  Future<dynamic> post(String path, [Object? body]) =>
      _send(() => http.post(_uri(path), headers: _headers, body: jsonEncode(body ?? {})));

  /// PUT request (invalidates cache)
  Future<dynamic> put(String path, Object body) async {
    _cache.remove(path);
    return _send(() => http.put(_uri(path), headers: _headers, body: jsonEncode(body)));
  }

  /// PATCH request (invalidates cache)
  Future<dynamic> patch(String path, Object body) async {
    _cache.remove(path);
    return _send(() => http.patch(_uri(path), headers: _headers, body: jsonEncode(body)));
  }

  /// DELETE request (invalidates cache)
  Future<dynamic> delete(String path) async {
    _cache.remove(path);
    return _send(() => http.delete(_uri(path), headers: _headers));
  }

  /// Cache a value for critical data
  void cacheValue<T>(String key, T value, Duration ttl) => _cache.set(key, value, ttl);

  /// Retrieve a cached value
  T? getCachedValue<T>(String key) => _cache.get<T>(key);

  /// Clear cache
  void clearCache() => _cache.clear();

  // ---------- Auth ----------

  /// Login user with credentials
  Future<(String, AppUser)> login(String phone, String password) async {
    _log('Logging in user: $phone');
    _cache.remove('/auth/me');
    final r = await post('/auth/login', {'phone': phone, 'password': password});
    return (r['token'] as String, AppUser.fromJson(r['user']));
  }

  /// Register new user
  Future<(String, AppUser)> register({
    required String name,
    required String phone,
    required String password,
    String? email,
    String? address,
  }) async {
    _log('Registering new user: $phone');
    final r = await post('/auth/register', {
      'name': name,
      'phone': phone,
      'password': password,
      'email': email,
      'address': address,
    });
    return (r['token'] as String, AppUser.fromJson(r['user']));
  }

  /// Get current user info
  Future<AppUser> me() async {
    _log('Fetching current user info');
    return AppUser.fromJson(await get('/auth/me'));
  }

  /// Update user profile
  Future<AppUser> updateMe(Map<String, dynamic> data) async {
    _log('Updating user profile');
    _cache.remove('/auth/me');
    return AppUser.fromJson(await put('/auth/me', data));
  }

  // ---------- Catalogue ----------

  /// Fetch app settings (cached 5 minutes)
  Future<AppSettings> settings() async {
    _log('Fetching app settings');
    final cached = getCachedValue<AppSettings>('/settings');
    if (cached != null) return cached;

    final result = AppSettings.fromJson(await get('/settings'));
    cacheValue('/settings', result, const Duration(minutes: 5));
    return result;
  }

  /// Fetch product categories (cached 5 minutes)
  Future<List<Category>> categories() async {
    _log('Fetching categories');
    final cached = getCachedValue<List<Category>>('/categories');
    if (cached != null) return cached;

    final result = (await get('/categories') as List).map((e) => Category.fromJson(e)).toList();
    cacheValue('/categories', result, const Duration(minutes: 5));
    return result;
  }

  /// Fetch products (cached 5 minutes)
  Future<List<Product>> products({bool all = false}) async {
    final endpoint = all ? '/products-all' : '/products';
    _log('Fetching products (all=$all)');
    final cached = getCachedValue<List<Product>>(endpoint);
    if (cached != null) return cached;

    final result = (await get('/products', all ? {'all': '1'} : null) as List)
        .map((e) => Product.fromJson(e))
        .toList();
    cacheValue(endpoint, result, const Duration(minutes: 5));
    return result;
  }

  // ---------- Commandes ----------

  /// Create a new order
  Future<Order> createOrder(Map<String, dynamic> data) async {
    _log('Creating new order');
    _cache.remove('/orders');
    return Order.fromJson(await post('/orders', data));
  }

  /// Fetch user's orders
  Future<List<Order>> myOrders() async {
    _log('Fetching user orders');
    return (await get('/orders') as List).map((e) => Order.fromJson(e)).toList();
  }

  /// Fetch specific order
  Future<Order> order(int id) async {
    _log('Fetching order $id');
    return Order.fromJson(await get('/orders/$id'));
  }

  /// Cancel an order
  Future<Order> cancelOrder(int id) async {
    _log('Cancelling order $id');
    _cache.remove('/orders');
    return Order.fromJson(await post('/orders/$id/cancel'));
  }

  // ---------- Admin ----------

  /// Fetch admin statistics (not cached - always fresh)
  Future<AdminStats> stats() async {
    _log('Fetching admin stats');
    return AdminStats.fromJson(await get('/admin/stats'));
  }

  /// Fetch admin orders with optional status filter
  Future<List<Order>> adminOrders({String? status}) async {
    _log('Fetching admin orders (status=$status)');
    _cache.remove('/admin/orders');
    return (await get('/admin/orders', status == null ? null : {'status': status}) as List)
        .map((e) => Order.fromJson(e))
        .toList();
  }

  /// Update order status
  Future<Order> setOrderStatus(int id, String status) async {
    _log('Setting order $id status to $status');
    _cache.remove('/admin/orders');
    return Order.fromJson(await patch('/admin/orders/$id/status', {'status': status}));
  }

  /// Save category (create or update)
  Future<Category> saveCategory(Category c) async {
    _log('Saving category: ${c.name}');
    _cache.remove('/categories');
    return Category.fromJson(
      c.id == 0
          ? await post('/admin/categories', c.toJson())
          : await put('/admin/categories/${c.id}', c.toJson()),
    );
  }

  /// Delete category
  Future<void> deleteCategory(int id) async {
    _log('Deleting category $id');
    _cache.remove('/categories');
    return delete('/admin/categories/$id');
  }

  /// Save product (create or update)
  Future<Product> saveProduct(Product p) async {
    _log('Saving product: ${p.name}');
    _cache.remove('/products');
    _cache.remove('/products-all');
    return Product.fromJson(
      p.id == 0
          ? await post('/admin/products', p.toJson())
          : await put('/admin/products/${p.id}', p.toJson()),
    );
  }

  /// Update product availability
  Future<Product> setProductAvailability(int id, bool available) async {
    _log('Setting product $id availability to $available');
    _cache.remove('/products');
    _cache.remove('/products-all');
    return Product.fromJson(await patch('/admin/products/$id/availability', {'available': available}));
  }

  /// Delete product
  Future<void> deleteProduct(int id) async {
    _log('Deleting product $id');
    _cache.remove('/products');
    _cache.remove('/products-all');
    return delete('/admin/products/$id');
  }

  /// Upload image file
  Future<String> uploadImage(File file) async {
    _log('Uploading image: ${file.path}');

    if (_circuitBreaker.isOpen) {
      throw ApiException(
        'Le service est temporairement indisponible. Réessayez dans quelques instants.',
        503,
        false,
      );
    }

    final ext = file.path.split('.').last.toLowerCase();
    final subtype = ext == 'png' ? 'png' : (ext == 'webp' ? 'webp' : 'jpeg');

    try {
      final req = http.MultipartRequest('POST', _uri('/admin/upload'))
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(
          await http.MultipartFile.fromPath(
            'image',
            file.path,
            contentType: MediaType('image', subtype),
          ),
        );

      final streamedResponse = await req.send().timeout(_requestTimeout);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        dynamic body;
        if (response.body.isNotEmpty) {
          body = jsonDecode(utf8.decode(response.bodyBytes));
        }
        _circuitBreaker.recordSuccess();
        return body['url'] as String;
      }

      _circuitBreaker.recordFailure();
      throw ApiException(
        'Erreur lors du téléchargement (${response.statusCode})',
        response.statusCode,
        false,
      );
    } on TimeoutException catch (e) {
      _circuitBreaker.recordFailure();
      throw ApiException(
        'Le téléchargement a expiré. Vérifiez votre connexion.',
        null,
        true,
        e,
      );
    }
  }

  /// Fetch list of users (customers)
  Future<List<CustomerSummary>> users() async {
    _log('Fetching user list');
    return (await get('/admin/users') as List).map((e) => CustomerSummary.fromJson(e)).toList();
  }

  /// Save app settings
  Future<AppSettings> saveSettings(AppSettings s) async {
    _log('Saving app settings');
    _cache.remove('/settings');
    return AppSettings.fromJson(await put('/admin/settings', s.toJson()));
  }
}
