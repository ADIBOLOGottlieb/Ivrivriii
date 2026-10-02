import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/geo_service.dart';
import '../theme.dart';

/// Tracé d'un itinéraire : trait rouge épais avec contour clair (lisible sur tous les fonds).
/// [fallback] : ligne droite en pointillés quand l'itinéraire est indisponible.
Polyline routePolyline(List<LatLng> points, {bool fallback = false}) {
  if (fallback) {
    return Polyline(
      points: points,
      strokeWidth: 3.5,
      color: AppColors.red.withValues(alpha: 0.75),
      borderStrokeWidth: 1.5,
      borderColor: Colors.white.withValues(alpha: 0.85),
      pattern: StrokePattern.dashed(segments: const [10, 8]),
    );
  }
  return Polyline(
    points: points,
    strokeWidth: 5,
    color: AppColors.red,
    borderStrokeWidth: 2.5,
    borderColor: Colors.white.withValues(alpha: 0.9),
  );
}

/// Marqueur du restaurant (pastille avec vitrine rouge).
Marker restaurantMarker(LatLng point) => Marker(
      point: point,
      width: 38,
      height: 38,
      child: const RestaurantPin(),
    );

/// Marqueur du point de livraison (épingle dont la pointe désigne le point).
Marker deliveryMarker(LatLng point) => Marker(
      point: point,
      width: 40,
      height: 40,
      alignment: Alignment.topCenter,
      child: const Icon(Icons.location_on_rounded, size: 40, color: AppColors.darkRed),
    );

class RestaurantPin extends StatelessWidget {
  const RestaurantPin({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.red, width: 2.5),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 4)],
      ),
      child: const Center(child: Icon(Icons.storefront_rounded, size: 20, color: AppColors.red)),
    );
  }
}

/// Lien Google Maps « itinéraire » de [from] à [to].
Uri googleMapsDirectionsUri(LatLng from, LatLng to) => Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=${from.latitude.toStringAsFixed(6)},${from.longitude.toStringAsFixed(6)}'
      '&destination=${to.latitude.toStringAsFixed(6)},${to.longitude.toStringAsFixed(6)}'
      '&travelmode=driving',
    );

/// Petite carte d'itinéraire (restaurant → livraison) à placer dans une page qui défile :
/// un doigt fait défiler la page, deux doigts déplacent / zooment la carte.
class RouteMap extends StatefulWidget {
  final LatLng from;
  final LatLng to;
  final double height;
  final String? fromLabel;
  final String? toLabel;

  const RouteMap({
    required this.from,
    required this.to,
    this.height = 220,
    this.fromLabel,
    this.toLabel,
    super.key,
  });

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  final _geo = GeoService.instance;
  final _map = MapController();
  bool _mapReady = false;

  RouteResult? _route;
  bool _loading = true;
  int _seq = 0;

  TileSession? _tileSession;
  int _googleTileErrors = 0;
  String? _googleCopyright;

  @override
  void initState() {
    super.initState();
    _initTiles();
    _loadRoute();
  }

  @override
  void didUpdateWidget(RouteMap old) {
    super.didUpdateWidget(old);
    if (old.from != widget.from || old.to != widget.to) {
      _route = null;
      _loadRoute();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    }
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  Future<void> _initTiles() async {
    if (!_geo.usesGoogle) return;
    try {
      final session = await _geo.tileSession();
      if (!mounted || session == null) return;
      setState(() => _tileSession = session);
      _refreshCopyright();
    } catch (_) {
      // On reste sur OpenStreetMap.
    }
  }

  void _onGoogleTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    if (_tileSession == null) return;
    _googleTileErrors++;
    if (_googleTileErrors < 4) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tileSession == null) return;
      setState(() {
        _tileSession = null;
        _googleCopyright = null;
      });
      _geo.clearTileSession();
    });
  }

  Future<void> _refreshCopyright() async {
    final session = _tileSession;
    if (session == null || !_mapReady) return;
    final camera = _map.camera;
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
      if (mounted && text != null && text != _googleCopyright) setState(() => _googleCopyright = text);
    } catch (_) {}
  }

  Future<void> _loadRoute() async {
    final seq = ++_seq;
    _loading = true;
    final r = await _geo.route(widget.from, widget.to);
    if (!mounted || seq != _seq) return;
    setState(() {
      _route = r;
      _loading = false;
    });
    _fit();
  }

  void _retry() {
    setState(() => _loading = true);
    _loadRoute();
  }

  List<LatLng> get _fitPoints => [widget.from, widget.to, ...?_route?.points];

  CameraFit get _cameraFit => CameraFit.coordinates(
        coordinates: _fitPoints,
        padding: const EdgeInsets.fromLTRB(36, 44, 36, 28),
        maxZoom: 17,
      );

  void _fit() {
    if (!_mapReady) return;
    _map.fitCamera(_cameraFit);
    _refreshCopyright();
  }

  void _onMapReady() {
    _mapReady = true;
    _fit();
  }

  Future<void> _openGoogleMaps() async {
    var ok = false;
    try {
      ok = await launchUrl(googleMapsDirectionsUri(widget.from, widget.to), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Impossible d\'ouvrir Google Maps')));
    }
  }

  Widget _tiles() {
    final session = _tileSession;
    if (session != null) {
      return TileLayer(
        key: ValueKey('google-${session.session}'),
        urlTemplate: session.urlTemplate,
        maxNativeZoom: 22,
        userAgentPackageName: GeoService.tileUserAgentPackage,
        tileProvider: NetworkTileProvider(headers: GeoService.googleHeaders),
        errorTileCallback: _onGoogleTileError,
      );
    }
    return TileLayer(
      key: const ValueKey('osm'),
      urlTemplate: GeoService.osmTileUrl,
      maxNativeZoom: 19,
      userAgentPackageName: GeoService.tileUserAgentPackage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final route = _route;
    final failed = !_loading && route == null;
    final line = route != null ? routePolyline(route.points) : routePolyline([widget.from, widget.to], fallback: true);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: widget.height,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCameraFit: _cameraFit,
                    minZoom: 5,
                    maxZoom: 19,
                    backgroundColor: scheme.surfaceContainerHighest,
                    // Pas de glisser à un doigt : la page reste défilable.
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.pinchZoom | InteractiveFlag.pinchMove | InteractiveFlag.doubleTapZoom,
                    ),
                    onMapReady: _onMapReady,
                  ),
                  children: [
                    _tiles(),
                    if (!_loading || route != null) PolylineLayer(polylines: [line]),
                    MarkerLayer(markers: [restaurantMarker(widget.from), deliveryMarker(widget.to)]),
                    if (_tileSession == null)
                      SimpleAttributionWidget(
                        source: const Text('OpenStreetMap', style: TextStyle(fontSize: 10.5)),
                        backgroundColor: Colors.white.withValues(alpha: 0.8),
                      ),
                  ],
                ),
                if (_tileSession != null)
                  Positioned(
                    left: 6,
                    bottom: 4,
                    right: 60,
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                          child: Text(
                            'Google  ${_googleCopyright ?? '© Google'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: scheme.onSurface),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Material(
                    color: scheme.surface,
                    elevation: 2,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      tooltip: 'Recentrer',
                      onPressed: _fit,
                      color: scheme.onSurface,
                      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.center_focus_strong_rounded, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(failed ? Icons.route_outlined : Icons.route_rounded,
                size: 20, color: failed ? scheme.onSurfaceVariant : AppColors.red),
            const SizedBox(width: 8),
            Expanded(
              child: _loading && route == null
                  ? Row(
                      children: [
                        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text('Calcul de l\'itinéraire…',
                            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                      ],
                    )
                  : Text(
                      route != null ? route.summary : 'Itinéraire indisponible',
                      style: TextStyle(
                        fontSize: route != null ? 15 : 13,
                        fontWeight: route != null ? FontWeight.w800 : FontWeight.w500,
                        color: route != null ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
            ),
            if (failed)
              TextButton(onPressed: _retry, child: const Text('Réessayer')),
          ],
        ),
        if (widget.fromLabel != null || widget.toLabel != null) ...[
          const SizedBox(height: 6),
          if (widget.fromLabel != null)
            _LegendRow(icon: Icons.storefront_rounded, text: widget.fromLabel!),
          if (widget.toLabel != null)
            _LegendRow(icon: Icons.location_on_rounded, text: widget.toLabel!),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _openGoogleMaps,
          icon: const Icon(Icons.directions_rounded),
          label: const Text('Ouvrir dans Google Maps'),
        ),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _LegendRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
