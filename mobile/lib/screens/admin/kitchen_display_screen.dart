import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../models.dart';
import '../../services/admin_api.dart' show fetchOrdersPage;
import '../../services/api.dart';
import '../../services/order_alert.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../utils/polling.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';

/// Colonnes de l'écran cuisine.
enum _Column { todo, preparing, ready }

extension on _Column {
  String get title => switch (this) {
        _Column.todo => 'À préparer',
        _Column.preparing => 'En préparation',
        _Column.ready => 'Prête',
      };

  Color get color => switch (this) {
        _Column.todo => Colors.blue.shade600,
        _Column.preparing => Colors.deepPurple.shade400,
        _Column.ready => Colors.teal.shade600,
      };

  IconData get icon => switch (this) {
        _Column.todo => Icons.receipt_long_rounded,
        _Column.preparing => Icons.soup_kitchen_rounded,
        _Column.ready => Icons.shopping_bag_rounded,
      };
}

/// Écran cuisine (plein écran, lisible de loin) : À préparer → En préparation → Prête.
/// Rafraîchi toutes les 5 s ; l'écran reste allumé tant qu'il est ouvert.
class KitchenDisplayScreen extends StatefulWidget {
  const KitchenDisplayScreen({super.key});

  @override
  State<KitchenDisplayScreen> createState() => _KitchenDisplayScreenState();
}

class _KitchenDisplayScreenState extends State<KitchenDisplayScreen> {
  static const _limit = 200;

  List<Order>? _orders;
  Object? _error;
  bool _offline = false; // dernier rafraîchissement en échec (données affichées possiblement anciennes)
  bool _primed = false;
  final Set<int> _updating = {};
  late final SmartPoller _poller;
  Timer? _clock; // temps écoulé à jour même sans nouvelle donnée

  @override
  void initState() {
    super.initState();
    OrderAlert.instance.init();
    WakelockPlus.enable().catchError((_) {});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _poller = SmartPoller(
      onPoll: _load,
      getInterval: (_) => const Duration(seconds: 5),
      canPoll: () => isRouteOnTop(context),
    );
    _poller.startPolling('on');
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _poller.stop();
    _clock?.cancel();
    WakelockPlus.disable().catchError((_) {});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final active = await fetchOrdersPage(admin: true, status: 'active', limit: _limit);
      if (!mounted) return;
      OrderAlert.instance.checkOrders(active, prime: !_primed);
      _primed = true;
      setState(() {
        _orders = active;
        _error = null;
        _offline = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (_orders == null) _error = e;
        _offline = true;
      });
    }
  }

  /// Colonne d'une commande (null : pas affichée en cuisine, ex. en livraison).
  static _Column? _columnOf(Order o) => switch (o.status) {
        'pending' || 'confirmed' => _Column.todo,
        'preparing' => _Column.preparing,
        'ready' => _Column.ready,
        _ => null,
      };

  /// Mobile money pas encore payé : affichée grisée, sans bouton.
  static bool _awaitingPayment(Order o) => isMobileMoney(o.paymentMethod) && !o.isPaid;

  List<Order> _ordersIn(_Column c) {
    final list = (_orders ?? const <Order>[]).where((o) => _columnOf(o) == c).toList();
    // Plus anciennes d'abord ; les commandes en attente de paiement à la fin.
    list.sort((a, b) {
      final pa = _awaitingPayment(a) ? 1 : 0, pb = _awaitingPayment(b) ? 1 : 0;
      if (pa != pb) return pa - pb;
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  /// Prochain statut proposé par le gros bouton (null : aucune action en cuisine).
  static (String, String)? _nextAction(Order o) {
    if (_awaitingPayment(o)) return null;
    return switch (o.status) {
      'pending' || 'confirmed' => ('preparing', 'Commencer'),
      'preparing' => ('ready', 'Prête'),
      'ready' when !o.isDelivery => ('delivered', 'Remise'),
      _ => null,
    };
  }

  Future<void> _advance(Order o, String status) async {
    if (_updating.contains(o.id)) return;
    HapticFeedback.mediumImpact();
    setState(() => _updating.add(o.id));
    try {
      final updated = await Api.instance.setOrderStatus(o.id, status);
      if (!mounted) return;
      setState(() {
        _orders = [for (final x in _orders ?? <Order>[]) x.id == updated.id ? updated : x];
      });
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
      await _load();
    } finally {
      if (mounted) setState(() => _updating.remove(o.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final orders = _orders;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Écran cuisine', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          if (_offline && orders != null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Tooltip(
                message: 'Connexion perdue : nouvel essai toutes les 5 s',
                child: Icon(Icons.cloud_off_rounded, color: Colors.orange),
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: OrderAlert.instance.muted,
            builder: (_, muted, _) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
                  const SizedBox(width: 4),
                  const Text('Son', style: TextStyle(fontWeight: FontWeight.w700)),
                  Switch(
                    value: !muted,
                    onChanged: (on) => OrderAlert.instance.setMuted(!on),
                  ),
                ],
              ),
            ),
          ),
          IconButton(tooltip: 'Actualiser', onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: Column(
        children: [
          const OrderAlertBanner(),
          Expanded(
            child: orders == null
                ? (_error != null
                    ? ErrorRetry(error: _error!, onRetry: _load)
                    : const Center(child: CircularProgressIndicator()))
                : LayoutBuilder(
                    builder: (context, c) => c.maxWidth >= 760 ? _columnsLayout() : _tabsLayout(),
                  ),
          ),
        ],
      ),
    );
  }

  /// Tablette / grand écran : 3 colonnes côte à côte.
  Widget _columnsLayout() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in _Column.values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: _columnPanel(c),
              ),
            ),
        ],
      ),
    );
  }

  Widget _columnPanel(_Column c) {
    final scheme = Theme.of(context).colorScheme;
    final list = _ordersIn(c);
    return Container(
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.color.withValues(alpha: 0.5), width: 2),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: c.color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Icon(c.icon, color: Colors.white, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(c.title,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
                ),
                _countBadge(list.length, Colors.white, c.color),
              ],
            ),
          ),
          Expanded(child: _cardsList(c, list)),
        ],
      ),
    );
  }

  Widget _countBadge(int n, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text('$n', style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w900)),
      );

  /// Téléphone : un onglet par colonne.
  Widget _tabsLayout() {
    return DefaultTabController(
      length: _Column.values.length,
      child: Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: TabBar(
              labelStyle: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
              tabs: [
                for (final c in _Column.values)
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(child: Text(c.title, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 6),
                        _countBadge(_ordersIn(c).length, c.color, Colors.white),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [for (final c in _Column.values) _cardsList(c, _ordersIn(c))],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardsList(_Column c, List<Order> list) {
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            switch (c) {
              _Column.todo => 'Rien à préparer',
              _Column.preparing => 'Aucune commande en préparation',
              _Column.ready => 'Aucune commande prête',
            },
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(10),
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => FadeSlideIn(
          key: ValueKey('kds-${list[i].id}-${list[i].status}'),
          child: _KitchenCard(
            order: list[i],
            accent: c.color,
            awaitingPayment: _awaitingPayment(list[i]),
            action: _nextAction(list[i]),
            busy: _updating.contains(list[i].id),
            onAdvance: (status) => _advance(list[i], status),
          ),
        ),
      ),
    );
  }
}

class _KitchenCard extends StatelessWidget {
  final Order order;
  final Color accent;
  final bool awaitingPayment;
  final (String, String)? action;
  final bool busy;
  final ValueChanged<String> onAdvance;

  const _KitchenCard({
    required this.order,
    required this.accent,
    required this.awaitingPayment,
    required this.action,
    required this.busy,
    required this.onAdvance,
  });

  /// Temps écoulé depuis la commande : orange au-delà de 15 min, rouge au-delà de 25 min.
  static Color _elapsedColor(int minutes, ColorScheme scheme) {
    if (minutes >= 25) return const Color(0xFFE53935);
    if (minutes >= 15) return const Color(0xFFFB8C00);
    return scheme.onSurfaceVariant;
  }

  static String _elapsed(int minutes) {
    if (minutes < 1) return "à l'instant";
    if (minutes < 60) return '$minutes min';
    return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final minutes = DateTime.now().difference(order.createdAt).inMinutes;
    final elapsedColor = _elapsedColor(minutes, scheme);
    final isLate = minutes >= 15 && order.status != 'ready';
    final note = (order.note ?? '').trim();
    final customer = order.customerName.trim();
    final waitingDriver = order.status == 'ready' && order.isDelivery;

    final card = Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: isLate ? elapsedColor : accent.withValues(alpha: 0.35), width: isLate ? 3 : 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('n°${order.id}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, height: 1)),
                const Spacer(),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.timer_outlined, color: elapsedColor, size: 24),
                    const SizedBox(width: 4),
                    Text(_elapsed(minutes),
                        style: TextStyle(color: elapsedColor, fontSize: 22, fontWeight: FontWeight.w900)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(orderModeLabel(order),
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: scheme.onSurface)),
                ),
                if (customer.isNotEmpty && customer != 'Comptoir')
                  Text(customer, style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant)),
              ],
            ),
            const Divider(height: 20),
            for (final item in order.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 52,
                      child: Text('${item.quantity}×',
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: scheme.primary)),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                          // Pack : la cuisine voit chaque plat à préparer, un par ligne.
                          if (item.details != null && item.details!.isNotEmpty)
                            for (final part in item.details!.split(RegExp(r', (?=\d+× )')))
                              Padding(
                                padding: const EdgeInsets.only(top: 2, left: 4),
                                child: Text('• $part',
                                    style: TextStyle(
                                        fontSize: 18, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.yellow.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.sticky_note_2_rounded, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(note, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (awaitingPayment)
              _infoBar(context, Icons.hourglass_top_rounded, paymentStatusLabel(order.paymentStatus))
            else if (waitingDriver)
              _infoBar(
                context,
                Icons.delivery_dining_rounded,
                order.hasDriver
                    ? 'En attente du livreur · ${(order.driverName ?? '').trim().isEmpty ? 'livreur' : order.driverName!.trim()}'
                    : 'En attente du livreur',
              )
            else if (action != null)
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                  ),
                  onPressed: busy ? null : () => onAdvance(action!.$1),
                  icon: busy
                      ? const SizedBox(
                          width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                      : Icon(statusIcon(action!.$1), size: 28),
                  label: Text(action!.$2),
                ),
              ),
          ],
        ),
      ),
    );
    // Paiement mobile money en attente : carte grisée.
    return awaitingPayment ? Opacity(opacity: 0.5, child: card) : card;
  }

  Widget _infoBar(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 24, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
