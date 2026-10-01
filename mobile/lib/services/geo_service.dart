import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

/// Une suggestion de lieu affichée pendant la recherche.
/// Google : [placeId] renseigné (coordonnées via [GeoService.placeDetails]).
/// Nominatim : [lat]/[lng] déjà connus.
class PlaceSuggestion {
  final String title;
  final String? subtitle;
  final String? placeId;
  final double? lat;
  final double? lng;

  const PlaceSuggestion({required this.title, this.subtitle, this.placeId, this.lat, this.lng});

  bool get hasCoordinates => lat != null && lng != null;
}

/// Un lieu résolu : coordonnées + adresse lisible.
class GeoPlace {
  final double lat;
  final double lng;
  final String? address;

  const GeoPlace({required this.lat, required this.lng, this.address});
}

/// Session de tuiles Google (Map Tiles API).
class TileSession {
  final String session;
  final DateTime expiry;

  const TileSession(this.session, this.expiry);

  String get urlTemplate =>
      'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}?session=$session&key=$googleMapsApiKey';
}

/// Appels réseau de la carte : Google Maps Platform si une clé est fournie,
/// sinon OpenStreetMap / Nominatim. Les erreurs sont levées ; l'écran les gère discrètement.
class GeoService {
  GeoService._();
  static final GeoService instance = GeoService._();

  static const _timeout = Duration(seconds: 10);
  static const _nominatimAgent = 'IvrivriiChicken/1.0 (contact: restaurant)';
  static const _prefsSession = 'gmaps_tile_session';
  static const _prefsExpiry = 'gmaps_tile_session_expiry';
  static const _prefsKeyTag = 'gmaps_tile_session_key';

  final http.Client _client = http.Client();
  DateTime _lastNominatim = DateTime.fromMillisecondsSinceEpoch(0);
  String? _sessionToken;

  bool get usesGoogle => hasGoogleMapsKey;

  /// En-têtes communs aux appels Google (clé restreinte aux applications Android).
  static Map<String, String> get googleHeaders {
    final headers = <String, String>{'X-Android-Package': androidPackageName};
    final cert = googleAndroidCertSha1.replaceAll(':', '').trim().toUpperCase();
    if (cert.isNotEmpty) headers['X-Android-Cert'] = cert;
    return headers;
  }

  // ---------------------------------------------------------------- Tuiles

  /// Session de tuiles Google, mise en cache jusqu'à son expiration. `null` sans clé.
  Future<TileSession?> tileSession() async {
    if (!hasGoogleMapsKey) return null;
    final keyTag = googleMapsApiKey.length > 6 ? googleMapsApiKey.substring(googleMapsApiKey.length - 6) : googleMapsApiKey;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_prefsSession);
      final expiry = prefs.getInt(_prefsExpiry);
      if (cached != null &&
          expiry != null &&
          prefs.getString(_prefsKeyTag) == keyTag &&
          DateTime.fromMillisecondsSinceEpoch(expiry).isAfter(DateTime.now().add(const Duration(hours: 1)))) {
        return TileSession(cached, DateTime.fromMillisecondsSinceEpoch(expiry));
      }
    } catch (_) {
      // Préférences indisponibles : on crée simplement une nouvelle session.
    }

    final res = await _client
        .post(
          Uri.parse('https://tile.googleapis.com/v1/createSession?key=$googleMapsApiKey'),
          headers: {...googleHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({'mapType': 'roadmap', 'language': 'fr', 'region': 'TG'}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) throw GeoException('createSession ${res.statusCode}');
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final session = data['session'] as String?;
    if (session == null || session.isEmpty) throw GeoException('session vide');
    // `expiry` : secondes depuis l'époque Unix (chaîne). Par défaut : 12 h.
    final seconds = int.tryParse('${data['expiry'] ?? ''}');
    final expiry = seconds != null
        ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
        : DateTime.now().add(const Duration(hours: 12));
    try {
      await prefs?.setString(_prefsSession, session);
      await prefs?.setInt(_prefsExpiry, expiry.millisecondsSinceEpoch);
      await prefs?.setString(_prefsKeyTag, keyTag);
    } catch (_) {}
    return TileSession(session, expiry);
  }

  /// Oublie la session en cache (ex. tuiles refusées).
  Future<void> clearTileSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsSession);
      await prefs.remove(_prefsExpiry);
    } catch (_) {}
  }

  /// Texte de copyright Google pour la zone affichée (obligatoire sous la carte).
  Future<String?> viewportCopyright({
    required TileSession session,
    required int zoom,
    required double north,
    required double south,
    required double east,
    required double west,
  }) async {
    final uri = Uri.https('tile.googleapis.com', '/tile/v1/viewport', {
      'session': session.session,
      'key': googleMapsApiKey,
      'zoom': '$zoom',
      'north': north.toStringAsFixed(6),
      'south': south.toStringAsFixed(6),
      'east': east.toStringAsFixed(6),
      'west': west.toStringAsFixed(6),
    });
    final res = await _client.get(uri, headers: googleHeaders).timeout(_timeout);
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body);
    if (data is! Map) return null;
    final text = data['copyright'];
    return text is String && text.trim().isNotEmpty ? text.trim() : null;
  }

  // ---------------------------------------------------------------- Recherche

  /// Suggestions pendant la frappe. Google Places (New) si clé, sinon Nominatim
  /// (et Nominatim en secours si Google échoue).
  Future<List<PlaceSuggestion>> suggestions(String input) async {
    final q = input.trim();
    if (q.length < 2) return const [];
    if (hasGoogleMapsKey) {
      try {
        return await _googleAutocomplete(q);
      } catch (_) {
        // Clé mal configurée ou quota : on bascule sur OpenStreetMap.
      }
    }
    return _nominatimSearch(q);
  }

  Future<List<PlaceSuggestion>> _googleAutocomplete(String input) async {
    _sessionToken ??= _newSessionToken();
    final res = await _client
        .post(
          Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
          headers: {
            ...googleHeaders,
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': googleMapsApiKey,
          },
          body: jsonEncode({
            'input': input,
            'languageCode': 'fr',
            'regionCode': 'tg',
            'includedRegionCodes': ['tg'],
            'locationBias': {
              'circle': {
                'center': {'latitude': 6.1319, 'longitude': 1.2228},
                'radius': 30000,
              },
            },
            'sessionToken': _sessionToken,
          }),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) throw GeoException('autocomplete ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    final list = data is Map ? data['suggestions'] : null;
    if (list is! List) return const [];
    final out = <PlaceSuggestion>[];
    for (final s in list) {
      if (s is! Map) continue;
      final p = s['placePrediction'];
      if (p is! Map) continue;
      final placeId = p['placeId'];
      if (placeId is! String) continue;
      final fmt = p['structuredFormat'];
      final main = fmt is Map ? _text(fmt['mainText']) : null;
      final secondary = fmt is Map ? _text(fmt['secondaryText']) : null;
      final full = _text(p['text']);
      out.add(PlaceSuggestion(
        title: main ?? full ?? placeId,
        subtitle: secondary ?? (main != null ? full : null),
        placeId: placeId,
      ));
    }
    return out;
  }

  /// Coordonnées d'une suggestion (Google : appel Place Details ; Nominatim : immédiat).
  Future<GeoPlace> placeDetails(PlaceSuggestion s) async {
    if (s.hasCoordinates) {
      return GeoPlace(
        lat: s.lat!,
        lng: s.lng!,
        address: s.subtitle != null ? '${s.title}, ${s.subtitle}' : s.title,
      );
    }
    final placeId = s.placeId;
    if (placeId == null) throw GeoException('lieu inconnu');
    final params = <String, String>{'languageCode': 'fr', 'regionCode': 'tg'};
    final token = _sessionToken;
    if (token != null) params['sessionToken'] = token;
    final uri = Uri.https('places.googleapis.com', '/v1/places/$placeId', params);
    final res = await _client.get(uri, headers: {
      ...googleHeaders,
      'X-Goog-Api-Key': googleMapsApiKey,
      'X-Goog-FieldMask': 'location,formattedAddress,displayName',
    }).timeout(_timeout);
    // La session d'autocomplétion se termine avec Place Details.
    _sessionToken = null;
    if (res.statusCode != 200) throw GeoException('place ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map) throw GeoException('réponse invalide');
    final loc = data['location'];
    final lat = loc is Map ? _toDouble(loc['latitude']) : null;
    final lng = loc is Map ? _toDouble(loc['longitude']) : null;
    if (lat == null || lng == null) throw GeoException('coordonnées absentes');
    final name = _text(data['displayName']);
    final formatted = data['formattedAddress'] is String ? data['formattedAddress'] as String : null;
    String? address = formatted;
    if (name != null && (formatted == null || !formatted.startsWith(name))) {
      address = formatted == null ? name : '$name, $formatted';
    }
    return GeoPlace(lat: lat, lng: lng, address: address);
  }

  Future<List<PlaceSuggestion>> _nominatimSearch(String q) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'countrycodes': 'tg',
      'accept-language': 'fr',
      'limit': '6',
      'q': q,
    });
    final res = await _nominatimGet(uri);
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! List) return const [];
    final out = <PlaceSuggestion>[];
    for (final e in data) {
      if (e is! Map) continue;
      final lat = _toDouble(e['lat']);
      final lng = _toDouble(e['lon']);
      final display = e['display_name'] is String ? e['display_name'] as String : null;
      if (lat == null || lng == null || display == null) continue;
      final name = e['name'] is String && (e['name'] as String).isNotEmpty ? e['name'] as String : null;
      String title = name ?? display.split(',').first.trim();
      String? subtitle = display;
      if (display.startsWith(title)) {
        final rest = display.substring(title.length).replaceFirst(RegExp(r'^\s*,\s*'), '').trim();
        subtitle = rest.isEmpty ? null : rest;
      }
      out.add(PlaceSuggestion(title: title, subtitle: subtitle, lat: lat, lng: lng));
    }
    return out;
  }

  // ---------------------------------------------------------------- Géocodage inverse

  /// Adresse lisible d'un point. `null` si introuvable.
  Future<String?> reverse(double lat, double lng) async {
    if (hasGoogleMapsKey) {
      try {
        return await _googleReverse(lat, lng);
      } catch (_) {
        // Secours OpenStreetMap ci-dessous.
      }
    }
    return _nominatimReverse(lat, lng);
  }

  Future<String?> _googleReverse(double lat, double lng) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'latlng': '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}',
      'language': 'fr',
      'region': 'tg',
      'key': googleMapsApiKey,
    });
    final res = await _client.get(uri, headers: googleHeaders).timeout(_timeout);
    if (res.statusCode != 200) throw GeoException('geocode ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map) throw GeoException('réponse invalide');
    final status = data['status'];
    if (status == 'ZERO_RESULTS') return null;
    if (status != 'OK') throw GeoException('geocode $status');
    final results = data['results'];
    if (results is! List || results.isEmpty) return null;
    // On évite les « plus codes » (ex. 4644+7Q Lomé) quand une vraie adresse existe.
    Map? best;
    for (final r in results) {
      if (r is! Map) continue;
      final types = r['types'];
      if (types is List && types.contains('plus_code')) continue;
      best = r;
      break;
    }
    best ??= results.first is Map ? results.first as Map : null;
    final address = best?['formatted_address'];
    return address is String && address.trim().isNotEmpty ? address.trim() : null;
  }

  Future<String?> _nominatimReverse(double lat, double lng) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'lat': lat.toStringAsFixed(6),
      'lon': lng.toStringAsFixed(6),
      'accept-language': 'fr',
      'zoom': '18',
    });
    final res = await _nominatimGet(uri);
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (data is! Map || data['error'] != null) return null;
    final display = data['display_name'];
    return display is String && display.trim().isNotEmpty ? display.trim() : null;
  }

  // ---------------------------------------------------------------- Outils

  /// GET Nominatim : User-Agent dédié et au plus 1 requête par seconde (règle d'usage OSM).
  Future<http.Response> _nominatimGet(Uri uri) async {
    final wait = _lastNominatim.add(const Duration(milliseconds: 1100)).difference(DateTime.now());
    // Réserve le créneau avant d'attendre, pour que les appels concurrents se suivent.
    _lastNominatim = DateTime.now().add(wait.isNegative ? Duration.zero : wait);
    if (!wait.isNegative) await Future<void>.delayed(wait);
    final res = await _client.get(uri, headers: {
      'User-Agent': _nominatimAgent,
      'Accept-Language': 'fr',
    }).timeout(_timeout);
    if (res.statusCode != 200) throw GeoException('nominatim ${res.statusCode}');
    return res;
  }

  static String? _text(dynamic v) {
    if (v is Map && v['text'] is String) {
      final t = (v['text'] as String).trim();
      return t.isEmpty ? null : t;
    }
    return null;
  }

  static double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// Jeton de session Places (UUID v4).
  static String _newSessionToken() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

class GeoException implements Exception {
  final String message;
  GeoException(this.message);

  @override
  String toString() => message;
}
