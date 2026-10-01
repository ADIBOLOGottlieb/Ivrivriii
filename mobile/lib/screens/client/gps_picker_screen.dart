import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../services/geo_service.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

class LocationData {
  final double lat;
  final double lng;
  final double? accuracy;
  final String? address;

  LocationData({required this.lat, required this.lng, this.accuracy, this.address});

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'accuracy': accuracy, 'address': address};
}

/// Choix de la position de livraison sur une carte.
/// Fond Google Maps (Map Tiles API) si une clé est fournie, sinon OpenStreetMap.
/// L'épingle reste au centre : le client fait glisser la carte, cherche un lieu ou utilise « Ma position ».
/// Renvoie un [LocationData] (avec l'adresse trouvée) via `Navigator.pop`.
class GpsPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const GpsPickerScreen({this.initialLat, this.initialLng, super.key});

  @override
  State<GpsPickerScreen> createState() => _GpsPickerScreenState();
}

class _GpsPickerScreenState extends State<GpsPickerScreen> {
  static const _lome = LatLng(6.1319, 1.2228);
  static const _userBlue = Color(0xFF1A73E8);
  static const _osmAgent = 'com.ivrivrii.chicken';

  final _geo = GeoService.instance;
  final _map = MapController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  late final AppLifecycleListener _lifecycle;

  // Position choisie (centre de la carte) et position réelle du téléphone.
  late LatLng _center;
  double? _accuracy;
  LatLng? _userPos;
  double? _userAccuracy;
  bool _locating = false;
  bool _moving = false;
  bool _awaitingSettings = false;
  bool _mapReady = false;
  (LatLng, double)? _pendingMove;
  MapCamera? _camera;

  // Fond de carte.
  TileSession? _tileSession;
  late Widget _tiles;
  int _googleTileErrors = 0;
  String? _googleCopyright;

  // Recherche.
  Timer? _searchDebounce;
  int _searchSeq = 0;
  bool _searching = false;
  List<PlaceSuggestion> _suggestions = const [];
  String? _searchInfo;

  // Adresse automatique.
  Timer? _idleTimer;
  int _reverseSeq = 0;
  String? _address;
  bool _resolving = true;
  LatLng? _resolvedFor;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    final hasInitial = widget.initialLat != null && widget.initialLng != null;
    _center = hasInitial ? LatLng(widget.initialLat!, widget.initialLng!) : _lome;
    _tiles = _buildTiles();
    _initGoogleTiles();
    _scheduleIdle();
    // Première ouverture : on tente directement la position du téléphone.
    if (!hasInitial) WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _searchDebounce?.cancel();
    _idleTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    _map.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ Fond de carte

  Future<void> _initGoogleTiles() async {
    if (!_geo.usesGoogle) return;
    try {
      final session = await _geo.tileSession();
      if (!mounted || session == null) return;
      setState(() {
        _tileSession = session;
        _googleTileErrors = 0;
        _tiles = _buildTiles();
      });
      _refreshCopyright();
    } catch (_) {
      // Session impossible : on reste sur OpenStreetMap.
    }
  }

  Widget _buildTiles() {
    final session = _tileSession;
    if (session != null) {
      return TileLayer(
        key: ValueKey('google-${session.session}'),
        urlTemplate: session.urlTemplate,
        maxNativeZoom: 22,
        userAgentPackageName: _osmAgent,
        tileProvider: NetworkTileProvider(headers: GeoService.googleHeaders),
        errorTileCallback: _onGoogleTileError,
      );
    }
    return TileLayer(
      key: const ValueKey('osm'),
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: _osmAgent,
    );
  }

  /// Tuiles Google refusées (clé mal restreinte, quota...) : retour sur OpenStreetMap.
  void _onGoogleTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    if (_tileSession == null) return;
    _googleTileErrors++;
    if (_googleTileErrors < 4) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tileSession == null) return;
      setState(() {
        _tileSession = null;
        _googleCopyright = null;
        _tiles = _buildTiles();
      });
      _geo.clearTileSession();
    });
  }

  Future<void> _refreshCopyright() async {
    final session = _tileSession;
    final camera = _camera;
    if (session == null || camera == null) return;
    final b = camera.visibleBounds;
    try {
      final text = await _geo.viewportCopyright(
        session: session,
        zoom: camera.zoom.clamp(0, 22).round(),
        north: b.north,
        south: b.south,
        east: b.east,
        west: b.west,
      );
      if (!mounted || text == null || text == _googleCopyright) return;
      setState(() => _googleCopyright = text);
    } catch (_) {
      // On garde « © Google ».
    }
  }

  // ------------------------------------------------------------------ Carte

  void _moveMap(LatLng point, double zoom) {
    if (_mapReady) {
      _map.move(point, zoom);
    } else {
      _pendingMove = (point, zoom);
    }
  }

  void _onMapReady() {
    _mapReady = true;
    _camera = _map.camera;
    final pending = _pendingMove;
    _pendingMove = null;
    if (pending != null) _map.move(pending.$1, pending.$2);
    _refreshCopyright();
  }

  void _onPositionChanged(MapCamera camera, bool hasGesture) {
    _camera = camera;
    final last = _resolvedFor;
    final farFromResolved = last == null || _metersBetween(camera.center, last) > 5;
    setState(() {
      _center = camera.center;
      if (hasGesture) {
        _accuracy = null; // Placée à la main : la précision GPS ne s'applique plus.
        _moving = true;
      }
      if (farFromResolved) {
        _address = null;
        _resolving = true;
      }
    });
    _scheduleIdle();
  }

  void _onMapEvent(MapEvent event) {
    if (event is MapEventMoveEnd || event is MapEventFlingAnimationEnd || event is MapEventDoubleTapZoomEnd) {
      if (_moving) setState(() => _moving = false);
    }
  }

  static double _metersBetween(LatLng a, LatLng b) =>
      Geolocator.distanceBetween(a.latitude, a.longitude, b.latitude, b.longitude);

  // ------------------------------------------------------------------ Adresse automatique

  /// Appelé ~600 ms après le dernier mouvement de la carte.
  void _scheduleIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _resolveAddress();
      _refreshCopyright();
    });
  }

  Future<void> _resolveAddress() async {
    final point = _center;
    final last = _resolvedFor;
    if (last != null && _metersBetween(point, last) <= 5) {
      if (_resolving) setState(() => _resolving = false);
      return;
    }
    final seq = ++_reverseSeq;
    if (!_resolving) setState(() => _resolving = true);
    try {
      final address = await _geo.reverse(point.latitude, point.longitude);
      if (!mounted || seq != _reverseSeq) return;
      setState(() {
        _address = address;
        _resolvedFor = point;
        _resolving = false;
      });
    } catch (_) {
      if (!mounted || seq != _reverseSeq) return;
      setState(() {
        _address = null;
        _resolving = false;
      });
    }
  }

  // ------------------------------------------------------------------ Recherche

  void _onSearchChanged(String text) {
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    if (text.trim().length < 2) {
      setState(() {
        _suggestions = const [];
        _searching = false;
        _searchInfo = null;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 400), () => _runSearch(text, seq));
  }

  Future<void> _runSearch(String text, int seq) async {
    try {
      final results = await _geo.suggestions(text);
      if (!mounted || seq != _searchSeq) return; // Réponse périmée.
      setState(() {
        _suggestions = results;
        _searching = false;
        _searchInfo = results.isEmpty ? 'Aucun lieu trouvé. Essayez un autre nom ou déplacez la carte.' : null;
      });
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _suggestions = const [];
        _searching = false;
        _searchInfo = 'Recherche indisponible pour le moment. Déplacez la carte à la main.';
      });
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchSeq++;
    _search.clear();
    setState(() {
      _suggestions = const [];
      _searching = false;
      _searchInfo = null;
    });
  }

  Future<void> _selectSuggestion(PlaceSuggestion s) async {
    FocusScope.of(context).unfocus();
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    _search.text = s.title;
    setState(() {
      _suggestions = const [];
      _searchInfo = null;
      _searching = !s.hasCoordinates;
    });
    try {
      final place = await _geo.placeDetails(s);
      if (!mounted || seq != _searchSeq) return;
      final point = LatLng(place.lat, place.lng);
      _reverseSeq++; // Ignore un géocodage inverse en cours.
      setState(() {
        _searching = false;
        _center = point;
        _accuracy = null;
        _address = place.address;
        _resolvedFor = place.address != null ? point : null;
        _resolving = place.address == null;
      });
      _moveMap(point, 17);
      _scheduleIdle();
    } catch (_) {
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _searchInfo = 'Impossible d\'ouvrir ce lieu. Réessayez ou déplacez la carte.';
      });
    }
  }

  void _dismissSearch() {
    if (_searchFocus.hasFocus) _searchFocus.unfocus();
    if (_suggestions.isNotEmpty || _searchInfo != null) {
      setState(() {
        _suggestions = const [];
        _searchInfo = null;
      });
    }
  }

  // ------------------------------------------------------------------ Localisation

  void _onResume() {
    // Retour des réglages Android : on relance la localisation si on l'attendait.
    if (!_awaitingSettings || !mounted) return;
    _awaitingSettings = false;
    _locate();
  }

  Future<void> _locate() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) await _askEnableLocationService();
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        if (mounted) await _askOpenAppSettings();
        return;
      }
      if (permission == LocationPermission.denied) {
        if (mounted) {
          showMessage(context, 'Autorisez la localisation pour trouver votre position, ou placez l\'épingle à la main.',
              error: true);
        }
        return;
      }

      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {
        // GPS lent (intérieur...) : dernière position connue en secours.
        pos = await Geolocator.getLastKnownPosition();
      }
      if (!mounted) return;
      if (pos == null) {
        showMessage(context, 'Position introuvable pour le moment. Placez l\'épingle à la main.', error: true);
        return;
      }
      final position = pos;
      final point = LatLng(position.latitude, position.longitude);
      setState(() {
        _userPos = point;
        _userAccuracy = position.accuracy;
        _center = point;
        _accuracy = position.accuracy;
      });
      _moveMap(point, 17);
      _scheduleIdle();
    } catch (_) {
      if (mounted) {
        showMessage(context, 'Position introuvable pour le moment. Placez l\'épingle à la main.', error: true);
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _askEnableLocationService() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.location_off_rounded, color: AppColors.red),
        title: const Text('Activer la localisation'),
        content: const Text(
          'La localisation (GPS) de votre téléphone est désactivée. '
          'Activez-la pour placer automatiquement l\'épingle sur votre position. '
          'Vous pouvez aussi chercher votre quartier ou déplacer la carte à la main.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Plus tard')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Activer')),
        ],
      ),
    );
    if (ok != true) return;
    _awaitingSettings = true;
    final opened = await Geolocator.openLocationSettings();
    if (!opened) _awaitingSettings = false;
  }

  Future<void> _askOpenAppSettings() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.location_disabled_rounded, color: AppColors.red),
        title: const Text('Localisation refusée'),
        content: const Text(
          'Ivrivrii Chicken n\'a pas l\'autorisation d\'utiliser votre position. '
          'Ouvrez les réglages de l\'application, puis « Autorisations » > « Position » pour l\'autoriser. '
          'Vous pouvez aussi placer l\'épingle à la main.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Plus tard')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ouvrir les réglages')),
        ],
      ),
    );
    if (ok != true) return;
    _awaitingSettings = true;
    final opened = await Geolocator.openAppSettings();
    if (!opened) _awaitingSettings = false;
  }

  // ------------------------------------------------------------------ Interface

  void _confirm() {
    final last = _resolvedFor;
    final addressIsCurrent = last != null && _metersBetween(_center, last) <= 5;
    Navigator.pop(
      context,
      LocationData(
        lat: _center.latitude,
        lng: _center.longitude,
        accuracy: _accuracy,
        address: addressIsCurrent ? _address : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final userPos = _userPos;
    final userAccuracy = _userAccuracy;
    return Scaffold(
      appBar: AppBar(title: const Text('Ma position de livraison')),
      // Le clavier passe par-dessus le panneau du bas au lieu d'écraser la carte.
      resizeToAvoidBottomInset: false,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Listener(
                  onPointerDown: (_) => _dismissSearch(),
                  onPointerUp: (_) {
                    if (_moving) setState(() => _moving = false);
                  },
                  child: FlutterMap(
                    mapController: _map,
                    options: MapOptions(
                      initialCenter: _center,
                      initialZoom: 16,
                      minZoom: 5,
                      maxZoom: 19,
                      onMapReady: _onMapReady,
                      onPositionChanged: _onPositionChanged,
                      onMapEvent: _onMapEvent,
                    ),
                    children: [
                      _tiles,
                      if (userPos != null && userAccuracy != null && userAccuracy > 0)
                        CircleLayer(
                          circles: [
                            CircleMarker(
                              point: userPos,
                              radius: userAccuracy,
                              useRadiusInMeter: true,
                              color: _userBlue.withValues(alpha: 0.15),
                              borderColor: _userBlue.withValues(alpha: 0.5),
                              borderStrokeWidth: 1,
                            ),
                          ],
                        ),
                      if (userPos != null)
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: userPos,
                              width: 20,
                              height: 20,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _userBlue,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 3),
                                  boxShadow: [
                                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      if (_tileSession == null)
                        const RichAttributionWidget(
                          alignment: AttributionAlignment.bottomLeft,
                          attributions: [TextSourceAttribution('OpenStreetMap')],
                        ),
                    ],
                  ),
                ),
                // Épingle fixe au centre ; la pointe désigne exactement la position choisie.
                IgnorePointer(
                  child: Center(
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 150),
                      offset: Offset(0, _moving ? -0.62 : -0.5),
                      child: const Icon(Icons.location_on_rounded, size: 52, color: AppColors.red),
                    ),
                  ),
                ),
                if (_tileSession != null)
                  Positioned(
                    left: 8,
                    right: 88,
                    bottom: 6,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: _GoogleAttribution(copyright: _googleCopyright),
                    ),
                  ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: _buildSearch(scheme),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton(
                    heroTag: 'locate',
                    onPressed: _locating ? null : _locate,
                    backgroundColor: scheme.surface,
                    foregroundColor: AppColors.red,
                    tooltip: 'Ma position',
                    child: _locating
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Icon(Icons.my_location_rounded),
                  ),
                ),
              ],
            ),
          ),
          _buildBottomPanel(scheme),
        ],
      ),
    );
  }

  Widget _buildSearch(ColorScheme scheme) {
    final showList = _suggestions.isNotEmpty || _searchInfo != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(14),
          color: scheme.surface,
          child: TextField(
            controller: _search,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) {
              if (_suggestions.isNotEmpty) _selectSuggestion(_suggestions.first);
            },
            style: TextStyle(color: scheme.onSurface, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Rechercher un quartier, une rue, un lieu…',
              hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
              prefixIcon: const Icon(Icons.search_rounded, color: AppColors.red),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : (_search.text.isNotEmpty
                      ? IconButton(
                          tooltip: 'Effacer',
                          icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
                          onPressed: _clearSearch,
                        )
                      : null),
            ),
          ),
        ),
        if (showList) ...[
          const SizedBox(height: 6),
          Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(14),
            color: scheme.surface,
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: _suggestions.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        _searchInfo ?? '',
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, _) => Divider(height: 1, color: scheme.outlineVariant),
                      itemBuilder: (context, i) {
                        final s = _suggestions[i];
                        final subtitle = s.subtitle;
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.place_outlined, color: scheme.onSurfaceVariant),
                          title: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
                          ),
                          subtitle: subtitle == null
                              ? null
                              : Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                          onTap: () => _selectSuggestion(s),
                        );
                      },
                    ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBottomPanel(ColorScheme scheme) {
    final coords = '${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}';
    final accuracy = _accuracy;
    final accuracyText = accuracy != null ? 'Précision GPS ±${accuracy.round()} m' : null;
    final address = _address;

    final List<Widget> details;
    if (_resolving && address == null) {
      details = [
        Row(
          children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('Recherche de l\'adresse…', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          ],
        ),
      ];
    } else if (address != null) {
      details = [
        Text(
          address,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13.5, color: scheme.onSurface),
        ),
        if (accuracyText != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(accuracyText, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ),
      ];
    } else {
      details = [
        Text('Adresse introuvable pour ce point', style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            accuracyText != null ? '$coords  •  $accuracyText' : coords,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ),
      ];
    }

    return Material(
      elevation: 12,
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.place_rounded, color: AppColors.red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Position choisie',
                          style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
                        ),
                        const SizedBox(height: 4),
                        ...details,
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _confirm,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Confirmer cette position'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Attribution obligatoire des tuiles Google : marque « Google » + copyright des données.
class _GoogleAttribution extends StatelessWidget {
  final String? copyright;

  const _GoogleAttribution({this.copyright});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = copyright ?? '© Google';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Google',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
