// Sonnerie des nouvelles commandes (écran cuisine, liste des commandes admin) :
// son fort en boucle jusqu'à ce que quelqu'un touche « J'ai vu ».

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

class OrderAlert {
  OrderAlert._();
  static final OrderAlert instance = OrderAlert._();

  static const _asset = 'sounds/new_order.wav'; // relatif à assets/ (AssetSource)
  static const _mutedKey = 'kitchen_sound_muted';

  /// Vrai tant que la sonnerie n'a pas été acquittée (« J'ai vu »).
  final ValueNotifier<bool> ringing = ValueNotifier(false);

  /// Commandes qui ont déclenché la sonnerie en cours (numéros affichés dans le bandeau).
  final ValueNotifier<List<int>> newOrderIds = ValueNotifier(const []);

  /// Sourdine (mémorisée sur l'appareil). Le bandeau s'affiche quand même.
  final ValueNotifier<bool> muted = ValueNotifier(false);

  AudioPlayer? _player;
  bool _prefsLoaded = false;

  /// Commandes « à préparer » déjà vues (pas de nouvelle sonnerie pour elles).
  final Set<int> _seen = {};

  /// Ventes au comptoir saisies sur cet appareil : jamais de sonnerie.
  final Set<int> _local = {};

  /// Charge la préférence de sourdine (à appeler à l'ouverture des écrans concernés).
  Future<void> init() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      muted.value = prefs.getBool(_mutedKey) ?? false;
    } catch (_) {
      // Préférence illisible : son actif.
    }
  }

  Future<void> setMuted(bool value) async {
    muted.value = value;
    if (value) {
      await _stopSound();
    } else if (ringing.value) {
      await _playSound();
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_mutedKey, value);
    } catch (_) {
      // Non bloquant.
    }
  }

  /// Vente saisie à la caisse de cet appareil : elle ne fait pas sonner.
  void markLocalOrder(int orderId) {
    _local.add(orderId);
    _seen.add(orderId);
  }

  /// Commande à préparer : en attente ou confirmée, et réglée en espèces ou déjà payée
  /// (une commande mobile money non payée ne sonne qu'une fois le paiement reçu).
  static bool isToPrepare(Order o) =>
      (o.status == 'pending' || o.status == 'confirmed') && (o.paymentMethod == 'cash' || o.isPaid);

  /// Compare la liste des commandes en cours avec celles déjà vues.
  /// [prime] (premier chargement d'un écran) : mémorise sans sonner.
  /// Renvoie les nouvelles commandes à préparer (et lance la sonnerie s'il y en a).
  List<Order> checkOrders(List<Order> active, {bool prime = false}) {
    final fresh = <Order>[];
    for (final o in active) {
      if (!isToPrepare(o)) continue;
      if (_seen.add(o.id) && !prime && !_local.contains(o.id)) fresh.add(o);
    }
    if (fresh.isNotEmpty) ring(fresh.map((o) => o.id));
    return fresh;
  }

  /// Lance (ou prolonge) la sonnerie pour ces commandes.
  void ring(Iterable<int> orderIds) {
    final ids = {...newOrderIds.value, ...orderIds}.toList()..sort();
    newOrderIds.value = ids;
    if (ringing.value) return;
    ringing.value = true;
    HapticFeedback.heavyImpact();
    if (!muted.value) _playSound();
  }

  /// « J'ai vu » : arrête la sonnerie.
  Future<void> acknowledge() async {
    ringing.value = false;
    newOrderIds.value = const [];
    await _stopSound();
  }

  Future<void> _playSound() async {
    try {
      final player = _player ??= AudioPlayer(playerId: 'order_alert');
      // Flux « alarme » : la sonnerie reste audible même si le volume multimédia est bas.
      await player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          usageType: AndroidUsageType.alarm,
          contentType: AndroidContentType.sonification,
          audioFocus: AndroidAudioFocus.gainTransient,
        ),
        iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
      ));
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(1);
      if (!ringing.value || muted.value) return; // acquitté pendant la préparation
      await player.play(AssetSource(_asset));
    } catch (e) {
      debugPrint('Sonnerie indisponible : $e');
    }
  }

  Future<void> _stopSound() async {
    try {
      await _player?.stop();
    } catch (_) {
      // Rien à arrêter.
    }
  }
}

/// Gros bandeau rouge « Nouvelle commande ! » avec le bouton « J'ai vu ».
/// Invisible quand aucune sonnerie n'est en cours.
class OrderAlertBanner extends StatelessWidget {
  const OrderAlertBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final alert = OrderAlert.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: alert.ringing,
      builder: (context, ringing, _) => AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: !ringing
            ? const SizedBox(width: double.infinity)
            : Material(
                color: const Color(0xFFC62828),
                elevation: 6,
                child: SafeArea(
                  bottom: false,
                  child: InkWell(
                    onTap: alert.acknowledge,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                      child: Row(
                        children: [
                          const _BlinkingBell(),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ValueListenableBuilder<List<int>>(
                              valueListenable: alert.newOrderIds,
                              builder: (_, ids, _) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    ids.length > 1 ? '${ids.length} nouvelles commandes !' : 'Nouvelle commande !',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
                                  ),
                                  if (ids.isNotEmpty)
                                    Text(
                                      ids.map((id) => 'n°$id').join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFFC62828),
                              minimumSize: const Size(0, 56),
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                            ),
                            onPressed: alert.acknowledge,
                            icon: const Icon(Icons.check_rounded, size: 26),
                            label: const Text("J'ai vu"),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _BlinkingBell extends StatefulWidget {
  const _BlinkingBell();

  @override
  State<_BlinkingBell> createState() => _BlinkingBellState();
}

class _BlinkingBellState extends State<_BlinkingBell> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        turns: Tween(begin: -0.04, end: 0.04).animate(_c),
        child: const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 36),
      );
}
