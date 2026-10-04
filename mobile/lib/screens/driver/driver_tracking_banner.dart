import 'package:flutter/material.dart';

import '../../services/driver_tracker.dart';
import '../../theme.dart';

/// Bandeau de l'espace livreur : « Position partagée avec le client » (point vert),
/// ou explication + bouton quand la localisation est refusée ou coupée. Caché sans livraison en cours.
class DriverTrackingBanner extends StatelessWidget {
  const DriverTrackingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final tracker = DriverTracker.instance;
    return ListenableBuilder(
      listenable: tracker,
      builder: (context, _) {
        final state = tracker.state;
        final visible = tracker.wanted && state != DriverTrackingState.idle;
        return AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: Alignment.bottomCenter,
          child: visible ? _content(context, tracker, state) : const SizedBox(width: double.infinity),
        );
      },
    );
  }

  Widget _content(BuildContext context, DriverTracker tracker, DriverTrackingState state) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (state == DriverTrackingState.sharing) {
      final green = dark ? cs.tertiary : AppColors.green;
      return Material(
        color: green.withValues(alpha: dark ? 0.16 : 0.10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _PulsingDot(color: green),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Position partagée avec le client',
                  style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface),
                ),
              ),
              Icon(Icons.my_location_rounded, size: 18, color: green),
            ],
          ),
        ),
      );
    }

    final (String text, String action) = switch (state) {
      DriverTrackingState.serviceDisabled => (
        'Localisation du téléphone désactivée : le client ne voit pas votre position.',
        'Activer',
      ),
      DriverTrackingState.permissionDeniedForever => (
        'Localisation refusée : autorisez-la dans les réglages pour que le client vous suive.',
        'Réglages',
      ),
      _ => ('Localisation refusée : le client ne voit pas votre position.', 'Autoriser'),
    };
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.location_off_rounded, color: cs.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onErrorContainer),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.red,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 38),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: tracker.fixPermission,
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}

/// Point vert qui « respire » : le partage est actif.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 8 + 10 * _c.value,
              height: 8 + 10 * _c.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
              ),
            ),
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            ),
          ],
        ),
      ),
    );
  }
}
