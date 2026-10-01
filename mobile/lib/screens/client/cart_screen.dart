import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/cart_provider.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shared/order_detail_screen.dart';
import 'checkout_screen.dart';
import 'client_shell.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  AppSettings? _settings;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  /// Réglages du restaurant (frais de livraison, % mobile money) pour l'estimation.
  Future<void> _loadSettings() async {
    try {
      final s = await Api.instance.settings();
      if (mounted) setState(() => _settings = s);
    } catch (_) {
      // Sans réglages, on n'affiche que le sous-total.
    }
  }

  Future<void> _checkout() async {
    // Réglages à jour (cache de 5 min) pour la prochaine estimation.
    _loadSettings();
    final order = await Navigator.push<Order>(
      context,
      MaterialPageRoute(builder: (_) => const CheckoutScreen()),
    );
    if (order == null || !mounted) return;

    // Onglet « Commandes » (la liste se recharge), puis détail de la commande.
    ClientShell.of(context)?.goTo(ClientShellState.ordersTab);
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OrderDetailScreen(
          orderId: order.id,
          initial: order,
          // Flooz / Mixx : l'écran de paiement s'ouvre aussitôt.
          openPayment: isMobileMoney(order.paymentMethod),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon panier'),
        actions: [
          if (!cart.isEmpty)
            TextButton(
              onPressed: () async {
                if (await confirmDialog(context, 'Vider le panier ?', 'Tous les articles seront retirés.',
                    confirm: 'Vider', danger: true)) {
                  cart.clear();
                }
              },
              child: const Text('Vider'),
            ),
        ],
      ),
      body: cart.isEmpty
          ? EmptyState(
              emoji: '🛍️',
              title: 'Votre panier est vide',
              message: 'Parcourez notre menu et laissez-vous tenter !',
              action: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
                onPressed: () => ClientShell.of(context)?.goTo(ClientShellState.menuTab),
                child: const Text('Voir le menu'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: cart.lines.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final line = cart.lines[i];
                return FadeSlideIn(
                  key: ValueKey('cart-${line.product.id}'),
                  delay: FadeSlideIn.stagger(i),
                  child: Dismissible(
                    key: ValueKey(line.product.id),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) => cart.remove(line.product.id),
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      decoration: BoxDecoration(color: AppColors.darkRed, borderRadius: BorderRadius.circular(18)),
                      child: const Icon(Icons.delete_rounded, color: Colors.white),
                    ),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            ProductImage(
                              url: line.product.imageUrl,
                              width: 70,
                              height: 70,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(line.product.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 4),
                                  Text(formatPrice(line.product.price),
                                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
                                  const SizedBox(height: 6),
                                  AnimatedCount(
                                    value: line.total,
                                    format: formatPrice,
                                    style: const TextStyle(
                                        fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.red),
                                  ),
                                ],
                              ),
                            ),
                            QuantityStepper(
                              compact: true,
                              value: line.quantity,
                              onChanged: (v) => cart.setQuantity(line.product.id, v),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      bottomNavigationBar: cart.isEmpty
          ? null
          : Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Summary(subtotal: cart.subtotal, count: cart.count, settings: _settings),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _checkout,
                      child: const Text('Passer la commande'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Récapitulatif estimé : mêmes formules que le serveur (le montant exact est confirmé à la commande).
class _Summary extends StatelessWidget {
  final int subtotal;
  final int count;
  final AppSettings? settings;
  const _Summary({required this.subtotal, required this.count, required this.settings});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = settings;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    Widget row(String label, Widget value, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            children: [
              Expanded(child: Text(label, style: style ?? muted)),
              const SizedBox(width: 8),
              value,
            ],
          ),
        );

    final children = <Widget>[
      row(
        'Sous-total ($count article${count > 1 ? 's' : ''})',
        AnimatedCount(
          value: subtotal,
          format: formatPrice,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: scheme.onSurface),
        ),
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    ];
    if (s != null) {
      final delivery = s.deliveryFee;
      // Même formule que le serveur : frais calculés sur sous-total + livraison.
      final fee = paymentFeeFor(subtotal + delivery, 'flooz', s.paymentFeePercent);
      children.addAll([
        row('Livraison (si livraison)', Text(formatPrice(delivery), style: muted)),
        row('Frais mobile money (${formatPercent(s.paymentFeePercent)} %)', Text(formatPrice(fee), style: muted)),
        const SizedBox(height: 2),
        row(
          'Total estimé (mobile money)',
          Text(formatPrice(subtotal + delivery + fee),
              style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.red)),
          style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface, fontSize: 13.5),
        ),
        const SizedBox(height: 2),
        Text(
          "Estimation avec livraison et paiement Flooz / Mixx. En espèces ou à emporter, ces frais "
          "ne s'appliquent pas. Le total exact est confirmé à la commande.",
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11.5, height: 1.3),
        ),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
