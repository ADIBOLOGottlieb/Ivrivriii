import 'package:flutter/material.dart';

import '../theme.dart';

String formatPrice(int amount) {
  final digits = amount.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}$buf FCFA';
}

String _two(int n) => n.toString().padLeft(2, '0');

String formatDateTime(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year} à ${_two(d.hour)}h${_two(d.minute)}';

String formatTime(DateTime d) => '${_two(d.hour)}h${_two(d.minute)}';

String timeAgo(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return "à l'instant";
  if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
  return formatDateTime(d);
}

/// Moyens de paiement proposés au Togo.
const paymentMethods = <String, String>{
  'cash': 'Espèces à la livraison',
  'tmoney': 'T-Money (Togocom)',
  'flooz': 'Flooz (Moov Africa)',
};

// Libellés des anciens moyens de paiement, pour l'historique des commandes.
const _legacyPaymentLabels = <String, String>{
  'orange_money': 'Orange Money',
  'mtn_momo': 'MTN Mobile Money',
  'moov_money': 'Moov Money',
  'wave': 'Wave',
};

String paymentLabel(String method) => paymentMethods[method] ?? _legacyPaymentLabels[method] ?? method;

IconData paymentIcon(String method) =>
    method == 'cash' ? Icons.payments_outlined : Icons.phone_android_rounded;

String statusLabel(String status, {bool delivery = true}) {
  switch (status) {
    case 'pending':
      return 'En attente';
    case 'confirmed':
      return 'Confirmée';
    case 'preparing':
      return 'En préparation';
    case 'ready':
      return delivery ? 'Prête' : 'Prête à récupérer';
    case 'delivering':
      return 'En livraison';
    case 'delivered':
      return delivery ? 'Livrée' : 'Récupérée';
    case 'cancelled':
      return 'Annulée';
  }
  return status;
}

Color statusColor(String status) {
  switch (status) {
    case 'pending':
      return Colors.orange.shade700;
    case 'confirmed':
      return Colors.blue.shade600;
    case 'preparing':
      return Colors.deepPurple.shade400;
    case 'ready':
      return Colors.teal.shade600;
    case 'delivering':
      return Colors.indigo.shade500;
    case 'delivered':
      return AppColors.green;
    case 'cancelled':
      return Colors.grey.shade600;
  }
  return Colors.grey;
}

IconData statusIcon(String status) {
  switch (status) {
    case 'pending':
      return Icons.hourglass_top_rounded;
    case 'confirmed':
      return Icons.thumb_up_alt_rounded;
    case 'preparing':
      return Icons.soup_kitchen_rounded;
    case 'ready':
      return Icons.shopping_bag_rounded;
    case 'delivering':
      return Icons.delivery_dining_rounded;
    case 'delivered':
      return Icons.check_circle_rounded;
    case 'cancelled':
      return Icons.cancel_rounded;
  }
  return Icons.circle;
}

/// Étapes affichées dans le suivi selon le mode de retrait.
List<String> statusSteps(bool delivery) => delivery
    ? ['pending', 'confirmed', 'preparing', 'ready', 'delivering', 'delivered']
    : ['pending', 'confirmed', 'preparing', 'ready', 'delivered'];

/// Prochaine étape proposée à l'administrateur.
String? nextStatus(String status, bool delivery) {
  final steps = statusSteps(delivery);
  final i = steps.indexOf(status);
  if (i < 0 || i == steps.length - 1) return null;
  return steps[i + 1];
}

const categoryIcons = <String, String>{
  'chicken': '🍗',
  'burger': '🍔',
  'grill': '🥩',
  'fries': '🍟',
  'drink': '🥤',
  'dessert': '🍰',
  'pizza': '🍕',
  'salad': '🥗',
  'rice': '🍛',
  'fish': '🐟',
};

String categoryEmoji(String? icon) => categoryIcons[icon] ?? '🍽️';
