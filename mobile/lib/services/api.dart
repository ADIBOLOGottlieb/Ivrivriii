import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config.dart';
import '../models.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  ApiException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

class Api {
  Api._();
  static final Api instance = Api._();

  String? token;

  /// Appelé quand le serveur répond 401 (session expirée).
  void Function()? onUnauthorized;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$apiBaseUrl/api$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    http.Response res;
    try {
      res = await request().timeout(const Duration(seconds: 15));
    } on SocketException {
      throw ApiException('Impossible de joindre le serveur. Vérifiez votre connexion.');
    } on TimeoutException {
      throw ApiException('Le serveur ne répond pas. Réessayez.');
    } on http.ClientException {
      throw ApiException('Impossible de joindre le serveur. Vérifiez votre connexion.');
    }

    dynamic body;
    if (res.body.isNotEmpty) {
      try {
        body = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        body = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return body;
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    final msg = body is Map && body['error'] is String ? body['error'] as String : 'Erreur (${res.statusCode})';
    throw ApiException(msg, res.statusCode);
  }

  Future<dynamic> get(String path, [Map<String, String>? query]) =>
      _send(() => http.get(_uri(path, query), headers: _headers));
  Future<dynamic> post(String path, [Object? body]) =>
      _send(() => http.post(_uri(path), headers: _headers, body: jsonEncode(body ?? {})));
  Future<dynamic> put(String path, Object body) =>
      _send(() => http.put(_uri(path), headers: _headers, body: jsonEncode(body)));
  Future<dynamic> patch(String path, Object body) =>
      _send(() => http.patch(_uri(path), headers: _headers, body: jsonEncode(body)));
  Future<dynamic> delete(String path) => _send(() => http.delete(_uri(path), headers: _headers));

  // ---------- Auth ----------

  Future<(String, AppUser)> login(String phone, String password) async {
    final r = await post('/auth/login', {'phone': phone, 'password': password});
    return (r['token'] as String, AppUser.fromJson(r['user']));
  }

  Future<(String, AppUser)> register({
    required String name,
    required String phone,
    required String password,
    String? email,
    String? address,
  }) async {
    final r = await post('/auth/register', {
      'name': name,
      'phone': phone,
      'password': password,
      'email': email,
      'address': address,
    });
    return (r['token'] as String, AppUser.fromJson(r['user']));
  }

  Future<AppUser> me() async => AppUser.fromJson(await get('/auth/me'));

  Future<AppUser> updateMe(Map<String, dynamic> data) async => AppUser.fromJson(await put('/auth/me', data));

  // ---------- Catalogue ----------

  Future<AppSettings> settings() async => AppSettings.fromJson(await get('/settings'));

  Future<List<Category>> categories() async =>
      (await get('/categories') as List).map((e) => Category.fromJson(e)).toList();

  Future<List<Product>> products({bool all = false}) async =>
      (await get('/products', all ? {'all': '1'} : null) as List).map((e) => Product.fromJson(e)).toList();

  // ---------- Commandes ----------

  Future<Order> createOrder(Map<String, dynamic> data) async => Order.fromJson(await post('/orders', data));

  Future<List<Order>> myOrders() async => (await get('/orders') as List).map((e) => Order.fromJson(e)).toList();

  Future<Order> order(int id) async => Order.fromJson(await get('/orders/$id'));

  Future<Order> cancelOrder(int id) async => Order.fromJson(await post('/orders/$id/cancel'));

  // ---------- Admin ----------

  Future<AdminStats> stats() async => AdminStats.fromJson(await get('/admin/stats'));

  Future<List<Order>> adminOrders({String? status}) async =>
      (await get('/admin/orders', status == null ? null : {'status': status}) as List)
          .map((e) => Order.fromJson(e))
          .toList();

  Future<Order> setOrderStatus(int id, String status) async =>
      Order.fromJson(await patch('/admin/orders/$id/status', {'status': status}));

  Future<Category> saveCategory(Category c) async => Category.fromJson(
        c.id == 0 ? await post('/admin/categories', c.toJson()) : await put('/admin/categories/${c.id}', c.toJson()),
      );

  Future<void> deleteCategory(int id) => delete('/admin/categories/$id');

  Future<Product> saveProduct(Product p) async => Product.fromJson(
        p.id == 0 ? await post('/admin/products', p.toJson()) : await put('/admin/products/${p.id}', p.toJson()),
      );

  Future<Product> setProductAvailability(int id, bool available) async =>
      Product.fromJson(await patch('/admin/products/$id/availability', {'available': available}));

  Future<void> deleteProduct(int id) => delete('/admin/products/$id');

  Future<String> uploadImage(File file) async {
    final ext = file.path.split('.').last.toLowerCase();
    final subtype = ext == 'png' ? 'png' : (ext == 'webp' ? 'webp' : 'jpeg');
    final req = http.MultipartRequest('POST', _uri('/admin/upload'))
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath('image', file.path, contentType: MediaType('image', subtype)));
    final body = await _send(() async => http.Response.fromStream(await req.send()));
    return body['url'] as String;
  }

  Future<List<CustomerSummary>> users() async =>
      (await get('/admin/users') as List).map((e) => CustomerSummary.fromJson(e)).toList();

  Future<AppSettings> saveSettings(AppSettings s) async => AppSettings.fromJson(await put('/admin/settings', s.toJson()));
}
