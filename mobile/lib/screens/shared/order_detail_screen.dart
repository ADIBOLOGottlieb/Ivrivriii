import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';

/// Détail et suivi d'une commande. En mode [admin], affiche les infos client
/// et les actions de changement de statut.
class OrderDetailScreen extends StatefulWidget {
  final int orderId;
  final Order? initial;
  final bool admin;

  const OrderDetailScreen({super.key, required this.orderId, this.initial, this.admin = false});

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Order? _order;
  Object? _error;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _order = widget.initial;
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_order != null && !_order!.isFinished) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await Api.instance.order(widget.orderId);
      if (!mounted) return;
      setState(() {
        _order = o;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(Future<Order> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      final o = await action();
      if (!mounted) return;
      setState(() => _order = o);
      showMessage(context, success);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final ok = await confirmDialog(
      context,
      'Annuler la commande ?',
      widget.admin ? 'Le client verra sa commande comme annulée.' : 'Cette action est définitive.',
      confirm: 'Annuler la commande',
      danger: true,
    );
    if (!ok) return;
    await _run(
      () => widget.admin
          ? Api.instance.setOrderStatus(widget.orderId, 'cancelled')
          : Api.instance.cancelOrder(widget.orderId),
      'Commande annulée',
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    return Scaffold(
      appBar: AppBar(title: Text('Commande n°${widget.orderId}')),
      body: o == null
          ? (_error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  FadeSlideIn(child: _StatusHeader(order: o)),
                  const SizedBox(height: 16),
                  if (o.status != 'cancelled')
                    FadeSlideIn(delay: const Duration(milliseconds: 80), child: _Timeline(order: o)),
                  if (widget.admin) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(delay: const Duration(milliseconds: 140), child: _CustomerCard(order: o)),
                  ],
                  const SizedBox(height: 16),
                  FadeSlideIn(delay: const Duration(milliseconds: 200), child: _ItemsCard(order: o)),
                  const SizedBox(height: 16),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 260),
                    child: Card(
                    child: Column(
                      children: [
                        ListTile(
                          leading: Icon(o.isDelivery ? Icons.delivery_dining_rounded : Icons.storefront_rounded,
                              color: AppColors.red),
                          title: Text(o.isDelivery ? 'Livraison' : 'À emporter'),
                          subtitle: o.isDelivery && o.address != null ? Text(o.address!) : null,
                        ),
                        ListTile(
                          leading: Icon(paymentIcon(o.paymentMethod), color: AppColors.red),
                          title: Text(paymentLabel(o.paymentMethod)),
                        ),
                        if (o.note != null)
                          ListTile(
                            leading: const Icon(Icons.sticky_note_2_rounded, color: AppColors.red),
                            title: Text(o.note!),
                          ),
                      ],
                    ),
                  ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
      bottomNavigationBar: o == null ? null : _actions(o),
    );
  }

  Widget? _actions(Order o) {
    final buttons = <Widget>[];
    if (widget.admin) {
      final next = nextStatus(o.status, o.isDelivery);
      if (next != null && o.status != 'cancelled') {
        buttons.add(FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() => Api.instance.setOrderStatus(o.id, next),
                  'Statut : ${statusLabel(next, delivery: o.isDelivery)}'),
          icon: Icon(statusIcon(next)),
          label: Text('Passer à « ${statusLabel(next, delivery: o.isDelivery)} »'),
        ));
      }
      if (!o.isFinished) {
        buttons.add(TextButton(
          onPressed: _busy ? null : _cancel,
          style: TextButton.styleFrom(foregroundColor: AppColors.darkRed),
          child: const Text('Annuler la commande'),
        ));
      }
    } else if (o.status == 'pending') {
      buttons.add(OutlinedButton(
        onPressed: _busy ? null : _cancel,
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.darkRed),
        child: const Text('Annuler ma commande'),
      ));
    }
    if (buttons.isEmpty) return null;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: buttons),
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  final Order order;
  const _StatusHeader({required this.order});

  String get _message {
    switch (order.status) {
      case 'pending':
        return 'Le restaurant va bientôt confirmer votre commande.';
      case 'confirmed':
        return 'Votre commande est confirmée et va passer en cuisine.';
      case 'preparing':
        return 'Nos chefs préparent votre commande avec amour 🍗';
      case 'ready':
        return order.isDelivery ? 'Votre commande attend le livreur.' : 'Votre commande vous attend au restaurant !';
      case 'delivering':
        return 'Le livreur est en route vers vous 🛵';
      case 'delivered':
        return 'Bon appétit ! Merci de votre confiance.';
      case 'cancelled':
        return 'Cette commande a été annulée.';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final color = statusColor(order.status);
    // Le bandeau change de couleur en douceur à chaque changement de statut.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.white.withValues(alpha: 0.2),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, anim) => RotationTransition(
                turns: Tween(begin: 0.75, end: 1.0).animate(anim),
                child: ScaleTransition(scale: anim, child: child),
              ),
              child: Icon(statusIcon(order.status), key: ValueKey(order.status), color: Colors.white, size: 30),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
              child: Column(
              key: ValueKey(order.status),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusLabel(order.status, delivery: order.isDelivery),
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(_message, style: const TextStyle(color: Colors.white, height: 1.3)),
                const SizedBox(height: 6),
                Text('Passée le ${formatDateTime(order.createdAt)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  final Order order;
  const _Timeline({required this.order});

  @override
  Widget build(BuildContext context) {
    final steps = statusSteps(order.isDelivery);
    final current = steps.indexOf(order.status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            for (var i = 0; i < steps.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutBack,
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i <= current ? AppColors.red : Colors.grey.shade200,
                          boxShadow: i == current
                              ? [BoxShadow(color: AppColors.red.withValues(alpha: 0.4), blurRadius: 10)]
                              : null,
                        ),
                        child: Icon(
                          i < current ? Icons.check_rounded : statusIcon(steps[i]),
                          size: 15,
                          color: i <= current ? Colors.white : Colors.grey.shade500,
                        ),
                      ),
                      if (i < steps.length - 1)
                        Container(
                          width: 3,
                          height: 22,
                          margin: const EdgeInsets.symmetric(vertical: 2),
                          alignment: Alignment.topCenter,
                          color: Colors.grey.shade200,
                          // La ligne se « remplit » jusqu'à l'étape en cours.
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeOut,
                            width: 3,
                            height: i < current ? 22 : 0,
                            color: AppColors.red,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 14,
                          fontWeight: i == current ? FontWeight.w800 : FontWeight.w500,
                          color: i <= current ? AppColors.ink : AppColors.muted,
                        ),
                        child: Text(statusLabel(steps[i], delivery: order.isDelivery)),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _CustomerCard extends StatelessWidget {
  final Order order;
  const _CustomerCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: AppColors.yellow,
          child: Icon(Icons.person_rounded, color: AppColors.ink),
        ),
        title: Text(order.customerName, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(order.phone),
        trailing: IconButton.filled(
          style: IconButton.styleFrom(backgroundColor: AppColors.green),
          icon: const Icon(Icons.call_rounded),
          onPressed: () => launchUrl(Uri(scheme: 'tel', path: order.phone.replaceAll(' ', ''))),
        ),
      ),
    );
  }
}

class _ItemsCard extends StatelessWidget {
  final Order order;
  const _ItemsCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Articles', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 12),
            for (final i in order.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${i.quantity}×',
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.red)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(i.name)),
                    Text(formatPrice(i.total)),
                  ],
                ),
              ),
            const Divider(height: 20),
            _row('Sous-total', order.subtotal),
            if (order.isDelivery) _row('Livraison', order.deliveryFee),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Total', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                const Spacer(),
                Price(order.total, size: 17),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, int amount) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Text(label, style: const TextStyle(color: AppColors.muted)),
          const Spacer(),
          Text(formatPrice(amount)),
        ]),
      );
}
