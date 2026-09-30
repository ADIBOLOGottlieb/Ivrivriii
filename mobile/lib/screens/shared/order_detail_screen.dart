import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../utils/polling.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';

/// Détail et suivi d'une commande. En mode [admin], affiche les infos client
/// et les actions de changement de statut.
class OrderDetailScreen extends StatefulWidget {
  final int orderId;
  final Order? initial;
  final bool admin;

  /// Ouvre directement la page de paiement (juste après une commande Flooz / Mixx).
  final bool openPayment;

  const OrderDetailScreen({
    super.key,
    required this.orderId,
    this.initial,
    this.admin = false,
    this.openPayment = false,
  });

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  Order? _order;
  Object? _error;
  bool _busy = false;
  late SmartPoller _poller;
  // Le client revient du navigateur après avoir payé : on rafraîchit aussitôt.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _order = widget.initial;

    // Initialize smart poller with adaptive polling intervals based on order status.
    // Priorities: pending/confirmed (10s) > preparing/ready/delivering (5s) > finished (stop)
    _poller = SmartPoller(
      onPoll: _load,
      getInterval: (status) {
        // Urgent: order in transit or being prepared
        if (['preparing', 'ready', 'delivering'].contains(status)) {
          return const Duration(seconds: 5); // High priority - poll frequently
        }
        // Active: order just placed or confirmed
        if (['pending', 'confirmed'].contains(status)) {
          return const Duration(seconds: 10); // Normal priority
        }
        // Stable: order finished - stop polling entirely
        return const Duration(hours: 1); // Effectively disabled
      },
    );

    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
    if (widget.openPayment && !widget.admin) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pay());
    }
    // Start polling only if order not finished
    if (_order == null || !_order!.isFinished) {
      _poller.startPolling(_order?.status ?? 'pending');
    }
  }

  @override
  void dispose() {
    _poller.stop(); // Clean up smart poller
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await Api.instance.order(widget.orderId);
      if (!mounted) return;
      setState(() {
        _order = o;
        _error = null;
        // Update poller with new status for adaptive interval adjustment
        _poller.updateStatus(o.status);
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

  /// Ouvre la page de paiement sécurisée KADEV PAY dans le navigateur.
  Future<void> _pay() async {
    var o = _order;
    if (o == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (o.payUrl == null) {
        o = await Api.instance.renewPayment(o.id);
        if (!mounted) return;
        setState(() => _order = o);
      }
      final ok = await launchUrl(Uri.parse('$apiBaseUrl${o.payUrl}'), mode: LaunchMode.externalApplication);
      if (!ok && mounted) showMessage(context, "Impossible d'ouvrir la page de paiement", error: true);
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
                  if (isMobileMoney(o.paymentMethod) && o.status != 'cancelled') ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 40),
                      child: _PaymentCard(order: o, admin: widget.admin, busy: _busy, onPay: _pay),
                    ),
                  ],
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
      final awaitingPayment = isMobileMoney(o.paymentMethod) && !o.isPaid;
      if (next != null && o.status != 'cancelled' && !awaitingPayment) {
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
    } else if (o.status == 'pending' && !o.isPaid) {
      buttons.add(OutlinedButton(
        onPressed: _busy ? null : _cancel,
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.darkRed),
        child: const Text('Annuler ma commande'),
      ));
    }
    if (buttons.isEmpty) return null;
    return Container(
      color: Theme.of(context).colorScheme.surface,
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
        subtitle: Text(order.hasLocation ? '${order.phone}\nPosition GPS fournie' : order.phone),
        isThreeLine: order.hasLocation,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (order.hasLocation) ...[
              IconButton.filled(
                tooltip: 'Itinéraire',
                style: IconButton.styleFrom(backgroundColor: AppColors.red),
                icon: const Icon(Icons.directions_rounded),
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://www.google.com/maps/dir/?api=1&destination=${order.deliveryLat},${order.deliveryLng}',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const SizedBox(width: 6),
            ],
            IconButton.filled(
              tooltip: 'Appeler',
              style: IconButton.styleFrom(backgroundColor: AppColors.green),
              icon: const Icon(Icons.call_rounded),
              onPressed: () => launchUrl(Uri(scheme: 'tel', path: order.phone.replaceAll(' ', ''))),
            ),
          ],
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
            if (order.paymentFee > 0) _row('Frais de paiement', order.paymentFee),
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

/// État du paiement mobile money (Flooz / Mixx via KADEV PAY).
class _PaymentCard extends StatelessWidget {
  final Order order;
  final bool admin;
  final bool busy;
  final VoidCallback onPay;
  const _PaymentCard({required this.order, required this.admin, required this.busy, required this.onPay});

  @override
  Widget build(BuildContext context) {
    final paid = order.isPaid;
    final failed = order.paymentStatus == 'failed';
    final color = paid ? AppColors.green : (failed ? AppColors.darkRed : const Color(0xFFE08A00));
    final title = paid ? 'Paiement reçu' : (failed ? 'Paiement échoué' : 'En attente de paiement');
    final String message;
    if (paid) {
      message = 'Réf. ${order.paymentReference ?? '-'}';
    } else if (admin) {
      message = 'La commande pourra être lancée dès que le client aura payé.';
    } else {
      message = 'Payez ${formatPrice(order.total)} par ${paymentLabel(order.paymentMethod)} '
          'pour que le restaurant lance votre commande.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(paid ? Icons.verified_rounded : Icons.account_balance_wallet_rounded, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.35)),
            if (!paid && !admin) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: busy ? null : onPay,
                icon: const Icon(Icons.lock_rounded),
                label: Text(failed ? 'Réessayer le paiement' : 'Payer maintenant'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
