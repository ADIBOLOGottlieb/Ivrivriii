import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'api.dart';

/// Notifications push (Firebase Cloud Messaging).
///
/// Sans configuration Firebase (pas de google-services.json dans le build), tout est sans effet :
/// aucune erreur, aucune demande de permission.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  /// Id de la commande à ouvrir quand l'utilisateur touche une notification (écouté par main.dart).
  final ValueNotifier<int?> onOpenOrder = ValueNotifier<int?>(null);

  static const String _prefsKey = 'push_token';
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'commandes', // même identifiant que le serveur (android.notification.channel_id)
    'Commandes',
    description: 'Suivi de vos commandes et livraisons',
    importance: Importance.high,
  );

  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  Future<void>? _initFuture;
  bool _available = false;
  bool _registered = false;
  String? _token;

  /// Vrai si Firebase est configuré et initialisé.
  bool get available => _available;

  /// À appeler dans main() sans attendre : ne lève jamais et ne bloque pas le démarrage.
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await Firebase.initializeApp().timeout(const Duration(seconds: 10));
    } catch (e) {
      _log('Firebase non configuré : notifications push désactivées ($e)');
      return;
    }
    try {
      await _initLocalNotifications();
      final messaging = FirebaseMessaging.instance;
      // iOS : bannière même app ouverte (Android : affichée par _showForeground).
      await messaging.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
      FirebaseMessaging.onMessage.listen(_showForeground);
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _openFromData(m.data));
      messaging.onTokenRefresh.listen((t) {
        if (_registered) unawaited(_sendToken(t));
      });
      _available = true;
      // App lancée en touchant une notification (app fermée).
      final initial = await messaging.getInitialMessage();
      if (initial != null) _openFromData(initial.data);
    } catch (e) {
      _log('Initialisation des notifications impossible : $e');
    }
  }

  Future<void> _initLocalNotifications() async {
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (r) => _openFromPayload(r.payload),
      );
      await _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);
      // App lancée en touchant une notification affichée au premier plan.
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch != null && launch.didNotificationLaunchApp) {
        _openFromPayload(launch.notificationResponse?.payload);
      }
    } catch (e) {
      _log('Notifications locales indisponibles : $e');
    }
  }

  /// Après connexion : demande la permission (Android 13+ / iOS) puis envoie le jeton au serveur.
  Future<void> registerForUser() async {
    try {
      await init();
      if (!_available) return;
      _registered = true;
      final settings = await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        _log('Notifications refusées par l\'utilisateur');
      }
      final token = await FirebaseMessaging.instance.getToken().timeout(const Duration(seconds: 20));
      if (token != null) await _sendToken(token);
    } catch (e) {
      _log('Enregistrement des notifications impossible : $e');
    }
  }

  Future<void> _sendToken(String token) async {
    try {
      // Api préfixe déjà « /api ».
      await Api.instance.post('/push/token', {
        'token': token,
        'platform': Platform.isIOS ? 'ios' : 'android',
      });
      _token = token;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, token);
    } catch (e) {
      _log('Envoi du jeton de notification impossible : $e');
    }
  }

  /// À la déconnexion : le serveur oublie l'appareil, puis le jeton local est supprimé.
  /// Lit le jeton de session immédiatement : peut être appelé juste avant de l'effacer.
  Future<void> unregister() async {
    final session = Api.instance.token;
    _registered = false;
    onOpenOrder.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = _token ?? prefs.getString(_prefsKey);
      _token = null;
      await prefs.remove(_prefsKey);
      if (token != null && session != null) {
        // Requête directe : DELETE avec corps JSON, sans réessai ni gestion du 401 de Api.
        await http
            .delete(
              Uri.parse('$apiBaseUrl/api/push/token'),
              headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $session'},
              body: jsonEncode({'token': token}),
            )
            .timeout(const Duration(seconds: 8));
      }
    } catch (e) {
      _log('Suppression du jeton côté serveur impossible : $e');
    }
    try {
      // Nouveau jeton pour le prochain compte connecté sur ce téléphone.
      if (_available) await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      _log('Suppression du jeton local impossible : $e');
    }
  }

  /// App au premier plan : FCM n'affiche rien sur Android, on affiche la notification nous-mêmes.
  Future<void> _showForeground(RemoteMessage message) async {
    final n = message.notification;
    if (n == null || !Platform.isAndroid) return;
    try {
      await _local.show(
        id: message.hashCode & 0x7fffffff,
        title: n.title,
        body: n.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: message.data['order_id'],
      );
    } catch (e) {
      _log('Affichage de la notification impossible : $e');
    }
  }

  void _openFromData(Map<String, dynamic> data) => _openFromPayload(data['order_id']?.toString());

  void _openFromPayload(String? payload) {
    final id = int.tryParse(payload ?? '');
    if (id == null) return;
    // Remise à null d'abord : toucher deux fois la même commande la rouvre.
    onOpenOrder.value = null;
    onOpenOrder.value = id;
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[push] $message');
  }
}
