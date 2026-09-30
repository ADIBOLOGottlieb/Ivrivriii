import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../theme.dart';
import '../../widgets/common.dart';

class LocationData {
  final double lat;
  final double lng;
  final double? accuracy;

  LocationData({required this.lat, required this.lng, this.accuracy});

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'accuracy': accuracy};
}

/// Choix de la position de livraison sur une carte OpenStreetMap (aucune clé API requise).
/// L'épingle reste au centre : le client fait glisser la carte ou utilise « Ma position ».
/// Renvoie un [LocationData] via `Navigator.pop`.
class GpsPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const GpsPickerScreen({this.initialLat, this.initialLng, super.key});

  @override
  State<GpsPickerScreen> createState() => _GpsPickerScreenState();
}

class _GpsPickerScreenState extends State<GpsPickerScreen> {
  static const _lome = LatLng(6.1319, 1.2228);

  final _map = MapController();
  late LatLng _center;
  double? _accuracy;
  bool _locating = false;
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    final hasInitial = widget.initialLat != null && widget.initialLng != null;
    _center = hasInitial ? LatLng(widget.initialLat!, widget.initialLng!) : _lome;
    // Première ouverture : on tente directement la position du téléphone.
    if (!hasInitial) WidgetsBinding.instance.addPostFrameCallback((_) => _locate(silent: true));
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  Future<void> _locate({bool silent = false}) async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!silent && mounted) showMessage(context, 'Activez la localisation (GPS) de votre téléphone', error: true);
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) {
        if (!silent && mounted) {
          showMessage(context, 'Localisation refusée : autorisez-la dans les réglages, ou placez l\'épingle à la main',
              error: true);
        }
        return;
      }
      if (permission == LocationPermission.denied) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
      if (!mounted) return;
      setState(() {
        _center = LatLng(pos.latitude, pos.longitude);
        _accuracy = pos.accuracy;
      });
      _map.move(_center, 17);
    } catch (_) {
      if (!silent && mounted) {
        showMessage(context, 'Position introuvable pour le moment. Placez l\'épingle à la main.', error: true);
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _onMove(MapCamera camera, bool hasGesture) {
    if (!hasGesture) return;
    setState(() {
      _center = camera.center;
      _accuracy = null; // Placée à la main : la précision GPS ne s'applique plus.
      _moving = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Ma position de livraison')),
      body: Stack(
        children: [
          Listener(
            onPointerUp: (_) => setState(() => _moving = false),
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: _center,
                initialZoom: 16,
                minZoom: 5,
                maxZoom: 19,
                onPositionChanged: _onMove,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.ivrivrii.chicken',
                ),
                const RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  attributions: [TextSourceAttribution('© OpenStreetMap')],
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
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(14),
              color: scheme.surface,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.touch_app_rounded, color: AppColors.red),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Faites glisser la carte pour placer l\'épingle sur votre porte.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 190,
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
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
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
                        children: [
                          const Icon(Icons.place_rounded, color: AppColors.red),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Position choisie', style: TextStyle(fontWeight: FontWeight.w700)),
                                Text(
                                  '${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}'
                                  '${_accuracy != null ? '  •  ±${_accuracy!.round()} m' : ''}',
                                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(
                          context,
                          LocationData(lat: _center.latitude, lng: _center.longitude, accuracy: _accuracy),
                        ),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Confirmer cette position'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
