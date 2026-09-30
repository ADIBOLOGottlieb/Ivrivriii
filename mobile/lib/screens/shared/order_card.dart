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
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.schedule_rounded, size: 15, color: Colors.grey.shade500),
                  const SizedBox(width: 4),
                  Text(timeAgo(order.createdAt), style: TextStyle(color: Colors.grey.shade600, fontSize: 12.5)),
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
}
