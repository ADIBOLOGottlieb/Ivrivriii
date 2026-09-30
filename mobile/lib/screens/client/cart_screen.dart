import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/cart_provider.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shared/order_detail_screen.dart';
import 'checkout_screen.dart';
import 'client_shell.dart';

class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
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
                                    style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text('Sous-total (${cart.count} article${cart.count > 1 ? 's' : ''})',
                            style: const TextStyle(color: AppColors.muted)),
                        const Spacer(),
                        AnimatedCount(
                          value: cart.subtotal,
                          format: formatPrice,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.ink),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: () async {
                        final order = await Navigator.push<Order>(
                          context,
                          MaterialPageRoute(builder: (_) => const CheckoutScreen()),
                        );
                        if (order == null || !context.mounted) return;
                        ClientShell.of(context)?.goTo(ClientShellState.ordersTab);
                        // Délai pour que la transition du tab soit terminée
                        await Future.delayed(const Duration(milliseconds: 300));
                        if (!context.mounted) return;
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: order.id, initial: order)),
                        );
                      },
                      child: const Text('Passer la commande'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
