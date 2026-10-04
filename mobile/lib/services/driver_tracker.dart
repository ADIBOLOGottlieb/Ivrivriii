// Suivi en direct côté livreur : tant qu'il a une livraison en cours (avant « Livraison faite »),
// sa position est envoyée au serveur (POST /api/driver/location) pour que le client voie le scooter avancer.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';

import '../models.dart';
import 'driver_api.dart';

/// État du partage de position, affiché dans le bandeau de l'espace livreur.
enum DriverTrackingState {
  /// Pas de livraison en cours : rien n'est partagé.
  idle,

  /// Position envoyée au serveur.
  sharing,

  /// Permission de localisation refusée (on peut la redemander).
  permissionDenied,

  /// Permission refusée définitivement : passer par les réglages de l'application.
  permissionDeniedForever,

  /// Localisation (GPS) du téléphone désactivée.
  serviceDisabled,
}

class DriverTracker extends ChangeNotifier {
  DriverTracker._();
  static final DriverTracker instance = DriverTracker._();

  /// Envoi au plus tard toutes les 10 s…
  static const sendInterval = Duration(seconds: 10);

  /// … ou dès un déplacement de 25 m (le premier des deux).
  static const sendDistanceMeters = 25.0;

  DriverTrackingState _state = DriverTrackingState.idle;
  DriverTrackingState get state => _state;

  /// Vrai si le livreur a au moins une livraison en cours (le suivi est souhaité).
  bool _wanted = false;
  bool get wanted => _wanted;

  StreamSubscription<Position>? _sub;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _starting = false;
  bool _sending = false;

  Position? _last; // dernière position reçue du GPS
  Position? _lastSent; // dernière position envoyée
  DateTime? _lastSentAt;

  /// Dernière position connue du livreur (affichage de son propre marqueur).
  final ValueNotifier<DriverLocation?> position = ValueNotifier(null);

  void _setState(DriverTrackingState s) {
    if (s == _state) return;
    _state = s;
    notifyListeners();
  }

  /// Livraisons en cours du livreur [me] (prises, avant « Livraison faite »).
  static int activeCount(List<Order> mine, int? me) => mine
      .where((o) => o.status == 'delivering' && o.driverDeliveredAt == null && (me == null || o.driverId == me))
      .length;

  /// Synchronise avec la liste « Mes livraisons » : démarre s'il en reste en cours, arrête sinon.
  void syncWith(List<Order> mine, int? me) {
    if (activeCount(mine, me) > 0) {
      start();
    } else {
      stop();
    }
  }

  /// Recharge « Mes livraisons » puis synchronise (après « Prendre », « Livraison faite », « Rendre »).
  Future<void> refresh(int? me) async {
    try {
      syncWith(await fetchDriverOrders(driverScopeMine), me);
    } catch (_) {
      // Réseau indisponible : on garde l'état actuel, la prochaine liste chargée corrigera.
    }
  }

  /// Démarre le suivi (sans effet s'il tourne déjà). [askPermission] : demande la permission si besoin
  /// (une seule fois : après un refus, seul le bouton du bandeau la redemande, via [force]).
  Future<void> start({bool askPermission = true, bool force = false}) async {
    _wanted = true;
    _lifecycle ??= AppLifecycleListener(onResume: _onResume);
    if (_sub != null || _starting) return;
    // Un service au premier plan ne peut être lancé que depuis l'application visible (Android 12+).
    final ls = WidgetsBinding.instance.lifecycleState;
    if (ls != null && ls != AppLifecycleState.resumed) return; // relancé au retour (_onResume)
    _starting = true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _setState(DriverTrackingState.serviceDisabled);
        return;
      }
      var permission = await Geolocator.checkPermission();
      final alreadyRefused = _state == DriverTrackingState.permissionDenied;
      if (permission == LocationPermission.denied && askPermission && (force || !alreadyRefused)) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        _setState(DriverTrackingState.permissionDeniedForever);
        return;
      }
      if (permission != LocationPermission.whileInUse && permission != LocationPermission.always) {
        _setState(DriverTrackingState.permissionDenied);
        return;
      }
      if (!_wanted || _sub != null) return; // arrêté pendant la demande
      _sub = Geolocator.getPositionStream(locationSettings: _settings()).listen(
        _onPosition,
        onError: (Object e) {
          _cancelStream();
          if (e is LocationServiceDisabledException) {
            _setState(DriverTrackingState.serviceDisabled);
          } else if (e is PermissionDeniedException) {
            _setState(DriverTrackingState.permissionDenied);
          }
          // Autre erreur : on relancera au retour dans l'application ou au prochain rafraîchissement.
        },
      );
      _timer ??= Timer.periodic(sendInterval, (_) => _tick());
      _setState(DriverTrackingState.sharing);
    } catch (_) {
      // Plugin indisponible (ex. plateforme non gérée) : pas de suivi.
    } finally {
      _starting = false;
    }
  }

  /// Arrête le suivi (plus de livraison en cours, déconnexion).
  void stop() {
    _wanted = false;
    _cancelStream();
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _last = null;
    _lastSent = null;
    _lastSentAt = null;
    position.value = null;
    _setState(DriverTrackingState.idle);
  }

  /// Bouton du bandeau : redemande la permission, ou ouvre les réglages si nécessaire.
  Future<void> fixPermission() async {
    try {
      switch (_state) {
        case DriverTrackingState.permissionDeniedForever:
          await Geolocator.openAppSettings();
          return; // vérifié au retour dans l'application
        case DriverTrackingState.serviceDisabled:
          await Geolocator.openLocationSettings();
          return;
        default:
          await start(force: true);
      }
    } catch (_) {}
  }

  void _cancelStream() {
    _sub?.cancel();
    _sub = null;
  }

  void _onResume() {
    if (_wanted && _sub == null) start(askPermission: false);
  }

  LocationSettings _settings() {
    if (kIsWeb) return const LocationSettings(accuracy: LocationAccuracy.high);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 5),
          // Service au premier plan : le suivi continue écran verrouillé, avec une notification visible.
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'Livraison en cours',
            notificationText: 'Votre position est partagée avec le client',
            notificationChannelName: 'Suivi de livraison',
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.high,
          activityType: ActivityType.automotiveNavigation,
          pauseLocationUpdatesAutomatically: false,
          // Pas de mode arrière-plan déclaré sur iOS : suivi seulement app ouverte.
          allowBackgroundLocationUpdates: false,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.high);
    }
  }

  void _onPosition(Position p) {
    _last = p;
    position.value = DriverLocation(
      lat: p.latitude,
      lng: p.longitude,
      accuracy: p.accuracy,
      heading: _heading(p),
      updatedAt: DateTime.now(),
    );
    if (_state != DriverTrackingState.sharing) _setState(DriverTrackingState.sharing);
    final sent = _lastSent;
    final at = _lastSentAt;
    final due =
        sent == null ||
        at == null ||
        DateTime.now().difference(at) >= sendInterval ||
        Geolocator.distanceBetween(sent.latitude, sent.longitude, p.latitude, p.longitude) >= sendDistanceMeters;
    if (due) _send(p);
  }

  /// Toutes les 10 s : renvoie la dernière position si rien n'est parti entre-temps (livreur à l'arrêt).
  void _tick() {
    final p = _last;
    final at = _lastSentAt;
    if (p == null) return;
    if (at != null && DateTime.now().difference(at) < sendInterval - const Duration(milliseconds: 500)) return;
    _send(p);
  }

  /// Cap seulement si le livreur roule (à l'arrêt, le cap du GPS n'a pas de sens).
  static double? _heading(Position p) => p.speed > 1 && p.heading >= 0 && p.heading <= 360 ? p.heading : null;

  Future<void> _send(Position p) async {
    if (_sending || !_wanted) return;
    _sending = true;
    _lastSent = p;
    _lastSentAt = DateTime.now();
    try {
      final r = await sendDriverLocation(
        lat: p.latitude,
        lng: p.longitude,
        accuracy: p.accuracy > 0 ? p.accuracy : null,
        heading: _heading(p),
        speed: p.speed >= 0 ? p.speed : null,
      );
      if (!r.tracking) stop(); // plus de livraison en cours côté serveur
    } catch (_) {
      // Réseau : ignoré, on réessaiera au prochain point.
    } finally {
      _sending = false;
    }
  }
}
