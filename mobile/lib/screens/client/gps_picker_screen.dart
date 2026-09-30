import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

class LocationData {
  final double lat;
  final double lng;
  final double? accuracy;

  LocationData({required this.lat, required this.lng, this.accuracy});

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'accuracy': accuracy};
}

/// Écran pour sélectionner la localisation GPS. Retourne [LocationData] via Navigator.pop.
class GpsPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const GpsPickerScreen({this.initialLat, this.initialLng, super.key});

  @override
  State<GpsPickerScreen> createState() => _GpsPickerScreenState();
}

class _GpsPickerScreenState extends State<GpsPickerScreen> {
  late GoogleMapController _mapController;
  double? _lat;
  double? _lng;
  double? _accuracy;
  String? _error;
  bool _loading = false;
  bool _permGranted = false;
  final Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _lat = widget.initialLat ?? 6.1319; // Lomé, Togo (par défaut)
    _lng = widget.initialLng ?? 1.2228;
    _updateMarker();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final status = await Geolocator.checkPermission();
    setState(() => _permGranted = status == LocationPermission.whileInUse || status == LocationPermission.always);
  }

  Future<void> _getCurrentLocation() async {
    if (!_permGranted) {
      final status = await Geolocator.requestPermission();
      if (status.isDenied || status.isPermanentlyDenied) {
        if (mounted) showMessage(context, 'Permission de localisation refusée', error: true);
        return;
      }
    }
    setState(() => _loading = true);
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)),
      );
      if (!mounted) return;
      setState(() {
        _lat = pos.latitude;
        _lng = pos.longitude;
        _accuracy = pos.accuracy;
        _error = null;
        _updateMarker();
      });
      _mapController.animateCamera(CameraUpdate.newLatLng(LatLng(_lat!, _lng!)));
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Impossible de récupérer votre position : $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _updateMarker() {
    _markers.clear();
    if (_lat != null && _lng != null) {
      _markers.add(
        Marker(
          markerId: const MarkerId('location'),
          position: LatLng(_lat!, _lng!),
          infoWindow: const InfoWindow(title: 'Votre localisation'),
        ),
      );
    }
  }

  void _onMapTap(LatLng pos) {
    setState(() {
      _lat = pos.latitude;
      _lng = pos.longitude;
      _updateMarker();
    });
  }

  void _submit() {
    if (_lat == null || _lng == null) return;
    Navigator.pop(context, LocationData(lat: _lat!, lng: _lng!, accuracy: _accuracy));
  }

  @override
  Widget build(BuildContext context) {
    if (_lat == null || _lng == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sélectionner ma localisation'),
        elevation: 0,
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: LatLng(_lat!, _lng!), zoom: 15),
            onMapCreated: (c) => _mapController = c,
            onTap: _onMapTap,
            markers: _markers,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
          ),
          if (_error != null)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Material(
                color: Colors.red.shade100,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                ),
              ),
            ),
          Positioned(
            top: 16,
            right: 16,
            child: Column(
              children: [
                FloatingActionButton.small(
                  onPressed: _loading ? null : _getCurrentLocation,
                  backgroundColor: AppColors.red,
                  child: _loading
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                      : const Icon(Icons.my_location_rounded, color: Colors.white),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Position sélectionnée', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.location_on_rounded, color: AppColors.red, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('${_lat!.toStringAsFixed(4)}, ${_lng!.toStringAsFixed(4)}',
                                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                                ),
                              ],
                            ),
                            if (_accuracy != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  const Icon(Icons.info_outline_rounded, color: AppColors.muted, size: 16),
                                  const SizedBox(width: 8),
                                  Text('Précision : ±${_accuracy!.toStringAsFixed(0)} m',
                                      style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _submit, child: const Text('Confirmer cette localisation')),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }
}
