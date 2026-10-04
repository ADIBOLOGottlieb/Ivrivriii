import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';

// ---------------------------------------------------------------- Textes (purs, testés)

const _weekdays = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

String _two(int n) => n.toString().padLeft(2, '0');

/// « 10:00 ».
String formatHourMinute(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// « aujourd'hui à 10:00 », « demain à 10:00 », « lundi à 10:00 » (dans la semaine),
/// sinon « le 12/10 à 10:00 ».
String describeOpeningTime(DateTime at, DateTime now) {
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final days = (day.difference(today).inHours / 24).round(); // arrondi : changement d'heure
  final time = formatHourMinute(at);
  if (days <= 0) return "aujourd'hui à $time";
  if (days == 1) return 'demain à $time';
  if (days < 7) return '${_weekdays[at.weekday - 1]} à $time';
  return 'le ${_two(at.day)}/${_two(at.month)} à $time';
}

/// Bandeau quand le restaurant est fermé : « Fermé — ouvre lundi à 10:00 ».
String closedBannerText(AppSettings s, {DateTime? now}) {
  final at = s.nextOpeningAt;
  if (at == null) return 'Fermé pour le moment';
  return 'Fermé — ouvre ${describeOpeningTime(at, now ?? DateTime.now())}';
}

/// Message quand une commande est refusée parce que le restaurant est fermé.
String closedOrderMessage(AppSettings s, {DateTime? now}) {
  final at = s.nextOpeningAt;
  if (at == null) return 'Le restaurant est fermé pour le moment : impossible de commander.';
  return 'Le restaurant est fermé : vous pourrez commander ${describeOpeningTime(at, now ?? DateTime.now())}.';
}

/// Rappel « Ferme à 22:00 » quand le restaurant ferme dans moins de 30 min, sinon null.
String? closingSoonText(AppSettings s, {DateTime? now}) {
  final at = s.nextClosingAt;
  if (!s.isOpen || at == null) return null;
  final left = at.difference(now ?? DateTime.now());
  if (left.isNegative || left > const Duration(minutes: 30)) return null;
  return 'Ferme à ${formatHourMinute(at)}';
}

/// Les réglages ne sont plus à jour : l'ouverture ou la fermeture prévue est passée.
bool openingStateExpired(AppSettings s, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final at = s.isOpen ? s.nextClosingAt : s.nextOpeningAt;
  return at != null && !t.isBefore(at);
}

// ---------------------------------------------------------------- Bandeau

/// Bandeau « Fermé — ouvre lundi à 10:00 » ou rappel « Ferme à 22:00 » (moins de 30 min).
/// Rien quand le restaurant est ouvert normalement. Se met à jour chaque minute ;
/// [onExpired] est appelé (une fois) quand l'heure d'ouverture / fermeture prévue est passée,
/// pour recharger les réglages.
class OpeningHoursBanner extends StatefulWidget {
  const OpeningHoursBanner({super.key, required this.settings, this.onExpired, this.margin = EdgeInsets.zero});

  final AppSettings settings;
  final VoidCallback? onExpired;
  final EdgeInsetsGeometry margin;

  @override
  State<OpeningHoursBanner> createState() => _OpeningHoursBannerState();
}

class _OpeningHoursBannerState extends State<OpeningHoursBanner> {
  Timer? _timer;
  AppSettings? _notified; // réglages pour lesquels onExpired a déjà été appelé
  DateTime? _lastNotified; // au plus un rechargement toutes les 2 min (horloge du téléphone décalée)

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final s = widget.settings;
    final now = DateTime.now();
    final recent = _lastNotified != null && now.difference(_lastNotified!) < const Duration(minutes: 2);
    if (widget.onExpired != null && !identical(_notified, s) && !recent && openingStateExpired(s, now: now)) {
      _notified = s;
      _lastNotified = now;
      widget.onExpired!();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final scheme = Theme.of(context).colorScheme;
    final String text;
    final IconData icon;
    final Color background;
    final Color foreground;
    if (!s.isOpen) {
      text = closedBannerText(s);
      icon = Icons.storefront_outlined;
      background = scheme.errorContainer;
      foreground = scheme.onErrorContainer;
    } else {
      final soon = closingSoonText(s);
      if (soon == null) return const SizedBox.shrink();
      text = soon;
      icon = Icons.schedule_rounded;
      background = scheme.secondaryContainer;
      foreground = scheme.onSecondaryContainer;
    }
    return Padding(
      padding: widget.margin,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Icon(icon, color: foreground, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text, style: TextStyle(color: foreground, fontWeight: FontWeight.w700, height: 1.3)),
            ),
          ],
        ),
      ),
    );
  }
}
