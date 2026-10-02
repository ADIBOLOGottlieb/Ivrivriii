import 'package:flutter/material.dart';

import '../../models.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

class OrderCard extends StatelessWidget {
  final Order order;
  final VoidCallback onTap;
  final bool showCustomer;
  final Widget? trailingAction;

  const OrderCard({
    super.key,
    required this.order,
    required this.onTap,
    this.showCustomer = false,
    this.trailingAction,
  });

  @override
  Widget build(BuildContext context) {
    final summary = order.items.map((i) => '${i.quantity}× ${i.name}').join(', ');
    final badge = _paymentBadge(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('n°${order.id}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                  const SizedBox(width: 8),
                  Icon(
                    order.isDelivery ? Icons.delivery_dining_rounded : Icons.storefront_rounded,
                    size: 18,
                    color: AppColors.muted,
                  ),
                  const Spacer(),
                  StatusChip(status: order.status, delivery: order.isDelivery),
                ],
              ),
              if (showCustomer) ...[
                const SizedBox(height: 6),
                Text('${order.customerName} • ${order.phone}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 6),
              Text(summary,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.muted)),
              if (badge != null) ...[const SizedBox(height: 8), badge],
              if (order.hasDriver || order.awaitingReceipt) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (order.hasDriver && !order.isCancelled)
                      _pill(
                        context,
                        '🛵 ${(order.driverName ?? '').trim().isEmpty ? 'Livreur' : order.driverName!.trim()}',
                        Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    if (order.awaitingReceipt)
                      _pill(context, 'À confirmer', const Color(0xFFE08A00), icon: Icons.where_to_vote_rounded),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(timeAgo(order.createdAt),
                      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5)),
                  const Spacer(),
                  Price(order.total, size: 15),
                ],
              ),
              if (trailingAction != null) ...[const SizedBox(height: 12), trailingAction!],
            ],
          ),
        ),
      ),
    );
  }

  /// Petite pastille (livreur, réception à confirmer), lisible en clair et en sombre.
  Widget _pill(BuildContext context, String label, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  /// Petit badge de paiement mobile money (en attente, non abouti, à rembourser, remboursé).
  Widget? _paymentBadge(BuildContext context) {
    if (!isMobileMoney(order.paymentMethod)) return null;
    final String label;
    final Color color;
    if (order.isRefunded) {
      label = paymentStatusLabel('refunded');
      color = Theme.of(context).colorScheme.tertiary;
    } else if (order.isPaid) {
      if (!order.isCancelled) return null;
      label = 'Payée • remboursement à faire';
      color = const Color(0xFFE08A00);
    } else if (order.isCancelled) {
      return null;
    } else if (order.paymentFailed) {
      label = paymentStatusLabel(order.paymentStatus);
      color = AppColors.darkRed;
    } else {
      label = paymentStatusLabel('pending');
      color = const Color(0xFFE08A00);
    }
    return Row(
      children: [
        Icon(Icons.account_balance_wallet_rounded, size: 15, color: color),
        const SizedBox(width: 5),
        Flexible(
          child: Text(label, style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
