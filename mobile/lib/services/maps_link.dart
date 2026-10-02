import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Position importée depuis l'app Google Maps (partage, lien copié ou saisie manuelle).
/// Aucune API Google payante : on lit seulement le texte / le lien partagé.
class ImportedLocation {
  final double lat;
  final double lng;

  /// Nom du lieu partagé (« Chez Ama »).
  final String? label;

  /// Adresse partagée par Google Maps, sinon null.
  final String? address;

  /// 'google_maps', 'coordinates', 'plus_code'
  final String source;

  const ImportedLocation({
    required this.lat,
    required this.lng,
    this.label,
    this.address,
    required this.source,
  });

  @override
  String toString() => 'ImportedLocation($lat, $lng, label: $label, address: $address, source: $source)';
}

/// Point de référence pour les plus codes courts : Lomé.
const double lomeLat = 6.1319;
const double lomeLng = 1.2228;

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

bool _isValid(double lat, double lng) =>
    lat.isFinite &&
    lng.isFinite &&
    lat >= -90 &&
    lat <= 90 &&
    lng >= -180 &&
    lng <= 180 &&
    !(lat.abs() < 1e-7 && lng.abs() < 1e-7);

({double lat, double lng})? _pair(String? a, String? b) {
  if (a == null || b == null) return null;
  final lat = double.tryParse(a.replaceAll(',', '.').replaceAll('+', ''));
  final lng = double.tryParse(b.replaceAll(',', '.').replaceAll('+', ''));
  if (lat == null || lng == null || !_isValid(lat, lng)) return null;
  return (lat: lat, lng: lng);
}

// ---------------------------------------------------------------------------
// Coordonnées en texte (décimal et DMS)
// ---------------------------------------------------------------------------

/// Composante DMS : 6°07'55.0"N, 1° 13′ 22.1″ E, 6°07.917'N, N 6°07'55"…
final _dmsRe = RegExp(
  r'''(?:(?<![a-z])([NSEWO])\s*)?([-+]?\d{1,3}(?:[.,]\d+)?)\s*[°º˚]\s*'''
  r'''(?:(\d{1,2}(?:[.,]\d+)?)\s*(?:['′’`]|´)\s*)?'''
  r'''(?:(\d{1,2}(?:[.,]\d+)?)\s*(?:["″”]|''|′′)\s*)?'''
  r'''(?:([NSEWO])(?![a-z]))?''',
  caseSensitive: false,
);

/// Paire décimale : « 6.1319, 1.2228 », « 6,1319 ; 1,2228 », « 6.1319 1.2228 », « 6.13° N, 1.22° E ».
final _decimalRe = RegExp(
  r'(?<![\d.,\w-])([-+]?\d{1,3}[.,]\d+)\s*°?\s*([NS](?![a-z]))?\s*(?:[,;/]\s*|\s+)'
  r'([-+]?\d{1,3}[.,]\d+)\s*°?\s*([EWO](?![a-z]))?(?![\d.])',
  caseSensitive: false,
);

/// Lit des coordonnées dans un texte libre : décimal (point ou virgule décimale) ou DMS.
({double lat, double lng})? parseCoordinateText(String text) {
  try {
    final t = text.trim();
    if (t.isEmpty) return null;
    return _parseDms(t) ?? _parseDecimal(t);
  } catch (_) {
    return null;
  }
}

({double lat, double lng})? _parseDms(String t) {
  double? lat;
  double? lng;
  final unassigned = <double>[];
  for (final m in _dmsRe.allMatches(t)) {
    final deg = double.tryParse(m.group(2)!.replaceAll(',', '.'));
    if (deg == null) continue;
    final min = m.group(3) == null ? 0.0 : double.tryParse(m.group(3)!.replaceAll(',', '.')) ?? 0.0;
    final sec = m.group(4) == null ? 0.0 : double.tryParse(m.group(4)!.replaceAll(',', '.')) ?? 0.0;
    if (min >= 60 || sec >= 60) continue;
    final hemi = (m.group(5) ?? m.group(1))?.toUpperCase();
    var value = deg.abs() + min / 60 + sec / 3600;
    if (deg < 0 || m.group(2)!.startsWith('-') || hemi == 'S' || hemi == 'W' || hemi == 'O') value = -value;
    if ((hemi == 'N' || hemi == 'S') && lat == null) {
      lat = value;
    } else if ((hemi == 'E' || hemi == 'W' || hemi == 'O') && lng == null) {
      lng = value;
    } else if (hemi == null) {
      unassigned.add(value);
    }
    if (lat != null && lng != null) break;
  }
  if (lat == null && unassigned.isNotEmpty) lat = unassigned.removeAt(0);
  if (lng == null && unassigned.isNotEmpty) lng = unassigned.removeAt(0);
  if (lat == null || lng == null || !_isValid(lat, lng)) return null;
  return (lat: lat, lng: lng);
}

({double lat, double lng})? _parseDecimal(String t) {
  for (final m in _decimalRe.allMatches(t)) {
    final p = _pair(m.group(1), m.group(3));
    if (p == null) continue;
    var lat = p.lat;
    var lng = p.lng;
    if (m.group(2)?.toUpperCase() == 'S') lat = -lat.abs();
    final lh = m.group(4)?.toUpperCase();
    if (lh == 'W' || lh == 'O') lng = -lng.abs();
    return (lat: lat, lng: lng);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Open Location Code (plus codes) — d'après la spécification officielle
// https://github.com/google/open-location-code/blob/main/Documentation/Specification/specification.md
// ---------------------------------------------------------------------------

const _olcAlphabet = '23456789CFGHJMPQRVWX';
const _olcSeparatorPosition = 8;
const _olcPairLength = 10;
const _olcMaxDigits = 15;

/// Plus code dans un texte : « 6CJ8+X7 », « 7FG46CJ8+X7 », « 6FX30000+ ».
final _plusCodeRe = RegExp(
  r'(?<![0-9A-Za-z+])([23456789CFGHJMPQRVWX]{2,8}0{0,6}\+[23456789CFGHJMPQRVWX]{0,7})(?![0-9A-Za-z])',
  caseSensitive: false,
);

bool _olcIsValid(String code) {
  if (code.isEmpty) return false;
  final sep = code.indexOf('+');
  if (sep < 0 || sep != code.lastIndexOf('+')) return false;
  if (sep > _olcSeparatorPosition || sep.isOdd || sep == 0) return false;
  final pad = code.indexOf('0');
  if (pad >= 0) {
    if (sep < _olcSeparatorPosition) return false; // pas de remplissage dans un code court
    if (pad == 0) return false;
    final padding = code.substring(pad, sep);
    if (padding.length.isOdd || padding.replaceAll('0', '').isNotEmpty) return false;
    if (code.length > sep + 1) return false;
  }
  final after = code.length - sep - 1;
  if (after == 1) return false;
  for (final c in code.split('')) {
    if (c == '+' || c == '0') continue;
    if (!_olcAlphabet.contains(c)) return false;
  }
  return true;
}

bool _olcIsFull(String code) {
  if (!_olcIsValid(code) || code.indexOf('+') != _olcSeparatorPosition) return false;
  // Première latitude < 180°, première longitude < 360°.
  if (_olcAlphabet.indexOf(code[0]) * 20 >= 180) return false;
  if (_olcAlphabet.indexOf(code[1]) * 20 >= 360) return false;
  return true;
}

/// Centre de la zone d'un code complet (déjà validé).
({double lat, double lng})? _olcDecodeFull(String code) {
  var digits = code.replaceAll('+', '').replaceAll(RegExp(r'0+$'), '');
  if (digits.length > _olcMaxDigits) digits = digits.substring(0, _olcMaxDigits);
  if (digits.length < 2 || digits.length.isOdd && digits.length < _olcPairLength) return null;
  var lat = 0.0;
  var lng = 0.0;
  var place = 20.0;
  final pairs = math.min(digits.length, _olcPairLength);
  for (var i = 0; i < pairs; i += 2) {
    if (i > 0) place /= 20;
    lat += _olcAlphabet.indexOf(digits[i]) * place;
    lng += _olcAlphabet.indexOf(digits[i + 1]) * place;
  }
  var latSize = place;
  var lngSize = place;
  for (var i = _olcPairLength; i < digits.length; i++) {
    latSize /= 5;
    lngSize /= 4;
    final v = _olcAlphabet.indexOf(digits[i]);
    lat += (v ~/ 4) * latSize;
    lng += (v % 4) * lngSize;
  }
  final cLat = math.min(-90 + lat + latSize / 2, 90.0);
  final cLng = math.min(-180 + lng + lngSize / 2, 180.0);
  return (lat: cLat, lng: cLng);
}

double _normalizeLng(double lng) {
  var l = lng;
  while (l < -180) {
    l += 360;
  }
  while (l >= 180) {
    l -= 360;
  }
  return l;
}

/// Encode une position en plus code (10 chiffres) — utilisé pour récupérer les codes courts.
String encodePlusCode(double lat, double lng) {
  var la = lat.clamp(-90.0, 90.0).toDouble();
  if (la >= 90) la = 90 - 1e-9;
  var ln = _normalizeLng(lng);
  // Entiers à la résolution de la 5e paire (1/8000°) pour éviter les erreurs d'arrondi.
  var latInt = ((la + 90) * 8000).floor();
  var lngInt = ((ln + 180) * 8000).floor();
  final out = List<String>.filled(10, '');
  for (var i = 4; i >= 0; i--) {
    out[i * 2] = _olcAlphabet[latInt % 20];
    out[i * 2 + 1] = _olcAlphabet[lngInt % 20];
    latInt ~/= 20;
    lngInt ~/= 20;
  }
  final s = out.join();
  return '${s.substring(0, 8)}+${s.substring(8)}';
}

/// Décode un plus code complet, ou récupère un code court près de [refLat]/[refLng]
/// (algorithme recoverNearest de la spécification). Le texte après le code (« Lomé ») est ignoré.
({double lat, double lng})? decodePlusCode(String code, {double refLat = lomeLat, double refLng = lomeLng}) {
  try {
    final m = _plusCodeRe.firstMatch(code.trim());
    if (m == null) return null;
    final c = m.group(1)!.toUpperCase();
    if (!_olcIsValid(c)) return null;
    ({double lat, double lng})? r;
    if (_olcIsFull(c)) {
      r = _olcDecodeFull(c);
    } else {
      final sep = c.indexOf('+');
      if (sep >= _olcSeparatorPosition || c.contains('0')) return null;
      final paddingLength = _olcSeparatorPosition - sep;
      final resolution = math.pow(20, 2 - paddingLength / 2).toDouble();
      final halfRes = resolution / 2;
      final rLat = refLat.clamp(-90.0, 90.0).toDouble();
      final rLng = _normalizeLng(refLng);
      final prefix = encodePlusCode(rLat, rLng).substring(0, paddingLength);
      final area = _olcDecodeFull(prefix + c);
      if (area == null) return null;
      var lat = area.lat;
      var lng = area.lng;
      if (rLat + halfRes < lat && lat - resolution >= -90) {
        lat -= resolution;
      } else if (rLat - halfRes > lat && lat + resolution <= 90) {
        lat += resolution;
      }
      if (rLng + halfRes < lng) {
        lng -= resolution;
      } else if (rLng - halfRes > lng) {
        lng += resolution;
      }
      r = (lat: lat, lng: _normalizeLng(lng));
    }
    if (r == null || !_isValid(r.lat, r.lng)) return null;
    return r;
  } catch (_) {
    return null;
  }
}

/// Plus code exploitable (complet, ou court d'au moins 4 caractères avant « + ») trouvé dans [text].
({double lat, double lng})? _findPlusCode(String text) {
  for (final m in _plusCodeRe.allMatches(text)) {
    final c = m.group(1)!;
    final sep = c.indexOf('+');
    if (sep < 4 || c.length - sep - 1 < 2 && sep < _olcSeparatorPosition) continue;
    final r = decodePlusCode(c);
    if (r != null) return r;
  }
  return null;
}

// ---------------------------------------------------------------------------
// URL Google Maps
// ---------------------------------------------------------------------------

final _r3d4d = RegExp(r'!3d(-?\d{1,3}(?:\.\d+)?)!4d(-?\d{1,3}(?:\.\d+)?)');
final _rAt = RegExp(r'@(-?\d{1,3}\.\d+),\s*(-?\d{1,3}\.\d+)');
final _rCenter = RegExp(r'(?:center|markers|ll)=(-?\d{1,3}\.\d+),\s*(-?\d{1,3}\.\d+)');
final _rNullNull = RegExp(r'\[null,null,(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)\]');

/// Paramètres d'URL, sans transformer « + » en espace (plus codes).
Map<String, String> _rawQuery(String url) {
  final out = <String, String>{};
  final q = url.indexOf('?');
  if (q < 0) return out;
  var query = url.substring(q + 1);
  final hash = query.indexOf('#');
  if (hash >= 0) query = query.substring(0, hash);
  for (final part in query.split(RegExp('[&;]'))) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final key = (eq < 0 ? part : part.substring(0, eq)).toLowerCase();
    final value = eq < 0 ? '' : _decode(part.substring(eq + 1));
    out.putIfAbsent(key, () => value);
  }
  return out;
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s.replaceAll('%2C', ',').replaceAll('%2c', ',').replaceAll('%2B', '+').replaceAll('%2b', '+');
  }
}

/// Coordonnées ou plus code dans une valeur de paramètre / un segment de chemin.
({double lat, double lng})? _parseValue(String raw) {
  var v = raw.trim();
  if (v.toLowerCase().startsWith('loc:')) v = v.substring(4);
  final coords = parseCoordinateText(v.replaceAll('+', ' '));
  if (coords != null) return coords;
  return _findPlusCode(v);
}

String? _placeNameFromPath(String decodedUrl) {
  final m = RegExp(r'/maps/place/([^/?#@]+)').firstMatch(decodedUrl);
  if (m == null) return null;
  final name = m.group(1)!.replaceAll('+', ' ').trim();
  if (name.isEmpty || _parseValue(m.group(1)!) != null) return null;
  return name.length > 120 ? name.substring(0, 120) : name;
}

/// Extrait la position d'une URL Google Maps (ou geo:) sans réseau.
/// Ordre : !3d!4d (lieu exact) → q/query/destination → ll/center → @lat,lng → chemin.
ImportedLocation? parseCoordinatesFromUrl(String url) {
  try {
    final raw = url.trim();
    if (raw.isEmpty) return null;
    final decoded = _decode(raw);
    final lower = decoded.toLowerCase();
    ({double lat, double lng})? p;

    // Page de consentement Google : l'URL de la carte est dans « continue ».
    if (lower.contains('consent.google.')) {
      final cont = _rawQuery(raw)['continue'];
      if (cont != null && cont.isNotEmpty) return parseCoordinatesFromUrl(cont);
    }

    final m3 = _r3d4d.firstMatch(decoded);
    if (m3 != null) p = _pair(m3.group(1), m3.group(2));

    if (p == null && lower.startsWith('geo:')) {
      final body = decoded.substring(4);
      final end = body.indexOf(RegExp('[?;]'));
      final coords = (end < 0 ? body : body.substring(0, end)).split(',');
      if (coords.length >= 2) p = _pair(coords[0].trim(), coords[1].trim());
    }

    if (p == null) {
      final params = _rawQuery(raw);
      for (final key in const ['q', 'query', 'destination', 'daddr', 'll', 'center', 'sll', 'viewpoint', 'cbll']) {
        final v = params[key];
        if (v == null || v.isEmpty) continue;
        p = _parseValue(v);
        if (p != null) break;
      }
    }

    if (p == null) {
      final at = _rAt.firstMatch(decoded);
      if (at != null) p = _pair(at.group(1), at.group(2));
    }

    if (p == null) {
      final path = RegExp(r'/maps/(?:place|search|dir)/(.+?)(?:[?#@]|$)').firstMatch(decoded);
      if (path != null) {
        for (final seg in path.group(1)!.split('/')) {
          if (seg.isEmpty || seg.startsWith('data=')) continue;
          p = _parseValue(seg);
          if (p != null) break;
        }
      }
    }

    if (p == null) return null;
    return ImportedLocation(lat: p.lat, lng: p.lng, label: _placeNameFromPath(decoded), source: 'google_maps');
  } catch (_) {
    return null;
  }
}

/// Coordonnées trouvées dans une page HTML de Google Maps (après résolution d'un lien court).
ImportedLocation? _parseHtml(String html) {
  final b = html
      .replaceAll(r'=', '=')
      .replaceAll(r'&', '&')
      .replaceAll('&amp;', '&')
      .replaceAll('%2C', ',')
      .replaceAll('%2c', ',');
  ({double lat, double lng})? p;
  for (final re in [_r3d4d, _rCenter, _rAt, _rNullNull]) {
    for (final m in re.allMatches(b)) {
      p = _pair(m.group(1), m.group(2));
      if (p != null) break;
    }
    if (p != null) break;
  }
  if (p == null) {
    // Vue initiale de la page : [[altitude, lng, lat],[0,0,0],…] (centrée sur le lieu).
    final v = RegExp(r'\[\[\d+(?:\.\d+)?,(-?\d{1,3}\.\d+),(-?\d{1,2}\.\d+)\],\[0,0,0\]').firstMatch(b);
    if (v != null) p = _pair(v.group(2), v.group(1));
  }
  if (p == null) {
    for (final m in RegExp(r'''https?://[^\s"'<>\\]*google\.[^\s"'<>\\]*/maps[^\s"'<>\\]*''').allMatches(b)) {
      final loc = parseCoordinatesFromUrl(m.group(0)!);
      if (loc != null) return loc;
    }
    return null;
  }
  return ImportedLocation(lat: p.lat, lng: p.lng, source: 'google_maps');
}

// ---------------------------------------------------------------------------
// Texte partagé
// ---------------------------------------------------------------------------

final _urlRe = RegExp(
  r'''(?:https?://|geo:)[^\s<>"']+|(?<![\w./])(?:maps\.app\.goo\.gl|goo\.gl/maps|maps\.google\.[a-z.]+|(?:www\.)?google\.[a-z.]+/maps)[^\s<>"']*''',
  caseSensitive: false,
);

String _cleanUrl(String u) {
  var s = u.replaceAll(RegExp(r'''[).,;:!?»"']+$'''), '');
  if (!RegExp(r'^(?:https?://|geo:)', caseSensitive: false).hasMatch(s)) s = 'https://$s';
  return s;
}

bool _isMapsUrl(String url) {
  final lower = url.toLowerCase();
  if (lower.startsWith('geo:')) return true;
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  if (host == 'maps.app.goo.gl') return true;
  if (host == 'goo.gl' && path.startsWith('/maps')) return true;
  if (host == 'g.co' && path.startsWith('/kgs')) return true;
  if (host.startsWith('maps.google.')) return true;
  if (RegExp(r'(^|\.)google\.[a-z.]+$').hasMatch(host) && path.startsWith('/maps')) return true;
  if (host.startsWith('consent.google.')) return true;
  return false;
}

const _genericLines = {
  'dropped pin',
  'repère placé',
  'repère posé',
  'repère',
  'position partagée',
  'ma position',
  'my location',
  'pin',
  'épingle',
};

/// Nom du lieu et adresse : lignes non-URL avant le lien.
({String? label, String? address}) _labelAndAddress(String before) {
  final lines = <String>[];
  for (var line in before.split(RegExp(r'[\r\n]+'))) {
    line = line.trim().replaceAll(RegExp(r'\s+'), ' ');
    line = line.replaceAll(RegExp(r'^[-–•·:,\s]+|[-–•·:,\s]+$'), '');
    if (line.isEmpty) continue;
    if (_genericLines.contains(line.toLowerCase())) continue;
    if (line.contains('★') || line.contains('⭐')) continue;
    if (parseCoordinateText(line) != null) continue;
    final pc = _plusCodeRe.firstMatch(line);
    if (pc != null && pc.start == 0) continue;
    if (lines.isNotEmpty && lines.last.toLowerCase() == line.toLowerCase()) continue;
    lines.add(line.length > 200 ? line.substring(0, 200) : line);
  }
  if (lines.isEmpty) return (label: null, address: null);
  if (lines.length == 1) {
    final l = lines.first;
    if (','.allMatches(l).length >= 2) return (label: null, address: l);
    return (label: l, address: null);
  }
  return (label: lines.first, address: lines.skip(1).join(', '));
}

/// Analyse synchrone (sans réseau) : vrai si le texte ressemble à une position / un lien Google Maps.
bool looksLikeLocationText(String text) {
  try {
    final t = text.trim();
    if (t.isEmpty || t.length > 4000) return false;
    for (final m in _urlRe.allMatches(t)) {
      if (_isMapsUrl(_cleanUrl(m.group(0)!))) return true;
    }
    final noUrl = t.replaceAll(_urlRe, ' ');
    return parseCoordinateText(noUrl) != null || _findPlusCode(noUrl) != null;
  } catch (_) {
    return false;
  }
}

/// Extrait la position (résout les liens courts). null si rien d'exploitable. Ne lève jamais d'exception.
Future<ImportedLocation?> parseLocationText(String text) async {
  try {
    return await _parseLocationText(text);
  } catch (_) {
    return null;
  }
}

Future<ImportedLocation?> _parseLocationText(String text) async {
  final t = text.trim();
  if (t.isEmpty || t.length > 4000) return null;
  final urls = _urlRe.allMatches(t).toList();
  final info = _labelAndAddress(urls.isEmpty ? t : t.substring(0, urls.first.start));

  ImportedLocation withInfo(ImportedLocation l) => ImportedLocation(
        lat: l.lat,
        lng: l.lng,
        label: info.label ?? l.label,
        address: info.address,
        source: l.source,
      );

  for (final m in urls) {
    final url = _cleanUrl(m.group(0)!);
    if (!_isMapsUrl(url)) continue;
    var loc = parseCoordinatesFromUrl(url);
    if (loc == null && url.toLowerCase().startsWith('http')) loc = await _resolveAndParse(url);
    if (loc != null) return withInfo(loc);
  }

  // Pas de lien exploitable : coordonnées ou plus code dans le texte.
  final noUrl = t.replaceAll(_urlRe, ' ');
  final c = parseCoordinateText(noUrl);
  if (c != null) return withInfo(ImportedLocation(lat: c.lat, lng: c.lng, source: 'coordinates'));
  final pc = _findPlusCode(noUrl);
  if (pc != null) return withInfo(ImportedLocation(lat: pc.lat, lng: pc.lng, source: 'plus_code'));
  return null;
}

const _mobileUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/126.0.0.0 Mobile Safari/537.36';

/// Suit les redirections d'un lien court (jusqu'à 6 sauts, 10 s par requête) puis analyse
/// l'URL finale, ou le corps HTML si besoin.
Future<ImportedLocation?> _resolveAndParse(String url) async {
  final client = http.Client();
  try {
    var current = Uri.parse(url);
    for (var hop = 0; hop <= 6; hop++) {
      final req = http.Request('GET', current)
        ..followRedirects = false
        ..headers['User-Agent'] = _mobileUserAgent
        ..headers['Accept-Language'] = 'fr-FR,fr;q=0.9';
      final resp = await client.send(req).timeout(const Duration(seconds: 10));
      final location = resp.headers['location'];
      if (resp.statusCode >= 300 && resp.statusCode < 400 && location != null && location.isNotEmpty) {
        unawaited(resp.stream.drain<void>().catchError((_) {}));
        if (hop == 6) return null;
        current = current.resolve(location);
        final loc = parseCoordinatesFromUrl(current.toString());
        if (loc != null) return loc;
        continue;
      }
      if (resp.statusCode >= 400) {
        unawaited(resp.stream.drain<void>().catchError((_) {}));
        return null;
      }
      final body = await resp.stream.bytesToString().timeout(const Duration(seconds: 10));
      final fromUrl = parseCoordinatesFromUrl(current.toString());
      if (fromUrl != null) return fromUrl;
      final fromHtml = _parseHtml(body);
      if (fromHtml == null) return null;
      return ImportedLocation(
        lat: fromHtml.lat,
        lng: fromHtml.lng,
        label: _placeNameFromPath(_decode(current.toString())),
        source: 'google_maps',
      );
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// Ouverture de l'app Google Maps (doit rester en fin de fichier)
// ---------------------------------------------------------------------------

/// Ouvre l'app Google Maps (repli navigateur) centrée sur [lat]/[lng] si fournis, sinon sur Lomé.
Future<bool> openGoogleMapsForPicking({double? lat, double? lng}) async {
  final (double cLat, double cLng) =
      (lat != null && lng != null && _isValid(lat, lng)) ? (lat, lng) : (lomeLat, lomeLng);
  final la = cLat.toStringAsFixed(6);
  final ln = cLng.toStringAsFixed(6);
  final candidates = [
    Uri.parse('https://www.google.com/maps/@?api=1&map_action=map&center=$la,$ln&zoom=17'),
    Uri.parse('geo:$la,$ln?z=17'),
  ];
  for (final uri in candidates) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return true;
    } catch (_) {
      // essai suivant
    }
  }
  return false;
}
