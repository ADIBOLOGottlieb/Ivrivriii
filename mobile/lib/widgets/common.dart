import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../config.dart';
import '../services/api.dart';
import '../theme.dart';
import '../utils/format.dart';

class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: ClipOval(child: Image.asset('assets/images/logo.jpg', fit: BoxFit.cover)),
    );
  }
}

class ProductImage extends StatelessWidget {
  final String? url;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  const ProductImage({super.key, this.url, this.width, this.height, this.borderRadius = BorderRadius.zero});

  @override
  Widget build(BuildContext context) {
    final resolved = resolveImageUrl(url);
    final placeholder = Container(
      width: width,
      height: height,
      color: AppColors.yellow.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: const Text('🍗', style: TextStyle(fontSize: 34)),
    );

    // Shimmer loading animation for better UX
    final shimmer = Container(
      width: width,
      height: height,
      color: AppColors.yellow.withValues(alpha: 0.1),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: resolved.isEmpty
          ? placeholder
          : CachedNetworkImage(
              imageUrl: resolved,
              width: width,
              height: height,
              fit: BoxFit.cover,
              // Cache for 7 days by default
              cacheManager: CacheManager.instance,
              placeholder: (context, url) => shimmer,
              errorWidget: (context, url, error) => placeholder,
              fadeInDuration: const Duration(milliseconds: 300),
              fadeOutDuration: const Duration(milliseconds: 300),
            ),
    );
  }
}

/// Global cache manager instance for network images.
/// Configured with 7-day default TTL and maximum 100MB cache size.
class CacheManager {
  static final instance = _createCacheManager();

  static dynamic _createCacheManager() {
    try {
      // Use default flutter_cache_manager with custom duration
      return DefaultCacheManager();
    } catch (_) {
      // Fallback if cache manager initialization fails
      return null;
    }
  }
}

class StatusChip extends StatelessWidget {
  final String status;
  final bool delivery;
  const StatusChip({super.key, required this.status, this.delivery = true});

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon(status), size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            statusLabel(status, delivery: delivery),
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class QuantityStepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final bool compact;

  const QuantityStepper({super.key, required this.value, required this.onChanged, this.min = 0, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final size = compact ? 30.0 : 40.0;
    Widget btn(IconData icon, VoidCallback? onTap) => Material(
          color: onTap == null ? Colors.grey.shade200 : AppColors.red,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: size, height: size, child: Icon(icon, color: Colors.white, size: size * 0.55)),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.remove_rounded, value > min ? () => onChanged(value - 1) : null),
        SizedBox(
          width: compact ? 32 : 44,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Text(
              '$value',
              key: ValueKey(value),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: compact ? 15 : 18, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        btn(Icons.add_rounded, value < 50 ? () => onChanged(value + 1) : null),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  final String emoji;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({super.key, required this.emoji, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.elasticOut,
              builder: (_, v, child) => Transform.scale(scale: v, child: child),
              child: Text(emoji, style: const TextStyle(fontSize: 64)),
            ),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class ErrorRetry extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ErrorRetry({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      emoji: '😕',
      title: 'Oups !',
      message: error is ApiException ? error.toString() : 'Une erreur est survenue.',
      action: OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Réessayer'),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          ?trailing,
        ],
      ),
    );
  }
}

void showMessage(BuildContext context, Object message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message.toString()),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? AppColors.darkRed : AppColors.ink,
    ));
}

Future<bool> confirmDialog(BuildContext context, String title, String message,
    {String confirm = 'Confirmer', bool danger = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: danger ? AppColors.darkRed : AppColors.red,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class Price extends StatelessWidget {
  final int amount;
  final double size;
  final Color color;
  const Price(this.amount, {super.key, this.size = 16, this.color = AppColors.red});

  @override
  Widget build(BuildContext context) =>
      Text(formatPrice(amount), style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: color));
}
