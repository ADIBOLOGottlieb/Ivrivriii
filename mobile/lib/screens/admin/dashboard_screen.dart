import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../models_admin.dart' show frenchWeekday;
import '../../providers/auth_provider.dart';
import '../../services/admin_api.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import 'admin_shell.dart';
import 'payments_review_screen.dart';

class DashboardScreen extends StatefulWidget {
  final bool active;
  const DashboardScreen({super.key, this.active = false});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  AdminStats? _stats;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DashboardScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  Future<void> _load() async {
    try {
      final s = await Api.instance.stats();
      if (!mounted) return;
      setState(() {
        _stats = s;
        _error = null;
      });
      AdminShell.of(context)?.setPendingCount(s.pending);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final s = _stats;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const AppLogo(size: 38),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Administration', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                Text(user?.name ?? '',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ],
        ),
      ),
      body: s == null
          ? (_error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: _load,
              child: LayoutBuilder(builder: (context, constraints) {
                // Tablette : tuiles sur 4 colonnes et graphiques côte à côte (téléphone inchangé).
                final wide = constraints.maxWidth >= 700;
                return ListView(
                  padding: EdgeInsets.symmetric(
                    vertical: 20,
                    horizontal: constraints.maxWidth > 1240 ? (constraints.maxWidth - 1200) / 2 : 20,
                  ),
                  children: [
                    ..._alerts(s),
                    _tiles(s, columns: wide ? 4 : 2),
                    const SizedBox(height: 12),
                    if (!wide) ...[_deliveredTotal(s), const SizedBox(height: 20)],
                    _pair(
                      wide,
                      _section('7 derniers jours', _WeekChart(days: s.last7Days)),
                      _section('Pic de commandes', _PeakCard(stats: s)),
                    ),
                    const SizedBox(height: 20),
                    if (wide)
                      _pair(
                        wide,
                        _section('Top ventes', _topProducts(s)),
                        _section('Commandes livrées', _deliveredTotal(s)),
                      )
                    else
                      _section('Top ventes', _topProducts(s)),
                  ],
                );
              }),
            ),
    );
  }

  /// Deux blocs l'un sous l'autre (téléphone) ou côte à côte (tablette).
  Widget _pair(bool wide, Widget a, Widget b) {
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [a, const SizedBox(height: 20), b],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Expanded(child: a), const SizedBox(width: 16), Expanded(child: b)],
    );
  }

  Widget _section(String title, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
          const SizedBox(height: 10),
          child,
        ],
      );

  /// Commandes en attente et paiements à vérifier.
  List<Widget> _alerts(AdminStats s) {
    final scheme = Theme.of(context).colorScheme;
    return [
      if (s.pending > 0)
        Card(
          color: AppColors.yellow,
          child: ListTile(
            leading: const Icon(Icons.notifications_active_rounded, color: AppColors.ink),
            title: Text(
              '${s.pending} commande${s.pending > 1 ? 's' : ''} en attente',
              style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.ink),
            ),
            subtitle: const Text('Touchez pour les traiter', style: TextStyle(color: AppColors.ink)),
            trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.ink),
            onTap: () => AdminShell.of(context)?.goTo(AdminShellState.ordersTab),
          ),
        ),
      if (s.pending > 0) const SizedBox(height: 16),
      // Paiements mobile money à vérifier à la main (compteur mis à jour par AdminShell).
      ValueListenableBuilder<int>(
        valueListenable: paymentReviewCount,
        builder: (context, n, _) => n == 0
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Card(
                  color: scheme.errorContainer,
                  child: ListTile(
                    leading: Icon(Icons.price_check_rounded, color: scheme.onErrorContainer),
                    title: Text(
                      '$n paiement${n > 1 ? 's' : ''} à vérifier',
                      style: TextStyle(fontWeight: FontWeight.w900, color: scheme.onErrorContainer),
                    ),
                    subtitle: Text(
                      'Mobile money en attente ou avec un écart',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                    trailing: Icon(Icons.chevron_right_rounded, color: scheme.onErrorContainer),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const PaymentsReviewScreen()),
                    ),
                  ),
                ),
              ),
      ),
    ];
  }

  Widget _tiles(AdminStats s, {required int columns}) {
    // Comparaison avec le même jour de la semaine dernière (« samedi dernier »).
    final day = frenchWeekday(DateTime.now().weekday);
    final cards = <Widget>[
      _StatCard(
        label: "Chiffre d'affaires du jour",
        value: s.todayRevenue,
        format: formatPrice,
        icon: Icons.payments_rounded,
        color: AppColors.green,
        footer: _ChangePill(percent: s.revenueChangePercent, weekday: day),
      ),
      _StatCard(
        label: 'Commandes du jour',
        value: s.todayOrders,
        icon: Icons.receipt_rounded,
        color: AppColors.red,
        footer: _ChangePill(percent: s.ordersChangePercent, weekday: day),
      ),
      _StatCard(
        label: 'En cours',
        value: s.active,
        icon: Icons.local_fire_department_rounded,
        color: Colors.orange.shade700,
      ),
      _StatCard(
        label: 'Clients inscrits',
        value: s.customers,
        icon: Icons.people_alt_rounded,
        color: Colors.blue.shade600,
      ),
    ];
    return GridView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // Hauteur fixe : la pastille d'évolution peut tenir sur deux lignes.
        mainAxisExtent: 172,
      ),
      children: [
        for (final (i, card) in cards.indexed) FadeSlideIn(delay: FadeSlideIn.stagger(i, stepMs: 70), child: card),
      ],
    );
  }

  Widget _deliveredTotal(AdminStats s) => Card(
        child: ListTile(
          leading: const Icon(Icons.emoji_events_rounded, color: AppColors.yellow, size: 32),
          title: AnimatedCount(
            value: s.deliveredRevenue,
            format: formatPrice,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
          ),
          subtitle: Text('Total des commandes livrées (${s.deliveredOrders}), hors remboursements'),
        ),
      );

  Widget _topProducts(AdminStats s) => Card(
        child: s.topProducts.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(20),
                child: Text('Pas encore de ventes',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              )
            : Column(
                children: [
                  for (var i = 0; i < s.topProducts.length; i++)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: i == 0 ? AppColors.yellow : AppColors.cream,
                        child: Text('${i + 1}',
                            style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.ink)),
                      ),
                      title: Text(s.topProducts[i].name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${s.topProducts[i].quantity} vendus'),
                      trailing: Text(formatPrice(s.topProducts[i].revenue),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                ],
              ),
      );
}

class _StatCard extends StatelessWidget {
  final String label;
  final int value;
  final String Function(int) format;
  final IconData icon;
  final Color color;
  final Widget? footer; // ex. évolution vs la semaine dernière

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.format = _plain,
    this.footer,
  });

  static String _plain(int v) => '$v';

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: color, size: 20),
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: AnimatedCount(
                value: value,
                format: format,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
            if (footer != null) ...[const SizedBox(height: 6), footer!],
          ],
        ),
      ),
    );
  }
}

/// Évolution par rapport au même jour de la semaine dernière : verte (hausse), rouge (baisse), grise (=).
class _ChangePill extends StatelessWidget {
  final double? percent;
  final String weekday; // « samedi »
  const _ChangePill({required this.percent, required this.weekday});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final p = percent;
    final String text;
    final Color color;
    final IconData? icon;
    if (p == null) {
      text = 'Pas de comparaison (semaine dernière vide)';
      color = theme.colorScheme.onSurfaceVariant;
      icon = null;
    } else if (p == 0) {
      text = '= vs $weekday dernier';
      color = theme.colorScheme.onSurfaceVariant;
      icon = Icons.trending_flat_rounded;
    } else if (p > 0) {
      text = '+${formatPercent(p)} % vs $weekday dernier';
      color = dark ? AppColors.darkTertiary : AppColors.green;
      icon = Icons.trending_up_rounded;
    } else {
      text = '−${formatPercent(-p)} % vs $weekday dernier';
      color = dark ? AppColors.darkPrimary : AppColors.darkRed;
      icon = Icons.trending_down_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, height: 1.15),
            ),
          ),
        ],
      ),
    );
  }
}

/// Créneau de 2 h le plus chargé et histogramme des commandes par heure (30 derniers jours).
class _PeakCard extends StatelessWidget {
  final AdminStats stats;
  const _PeakCard({required this.stats});

  static String _h(int h) => '$h h';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hourly = List<int>.generate(24, (i) => i < stats.hourly.length ? stats.hourly[i] : 0);
    final maxCount = hourly.fold<int>(0, (m, v) => v > m ? v : m);
    final start = stats.peakStartHour ?? -1;
    final end = stats.peakEndHour ?? -1;
    final hasPeak = start >= 0 && end > start && maxCount > 0;
    var peakOrders = 0;
    for (var h = start; hasPeak && h < end && h < 24; h++) {
      peakOrders += hourly[h];
    }
    bool inPeak(int h) => hasPeak && h >= start && h < end;
    final strong = theme.brightness == Brightness.dark ? scheme.primary : AppColors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.yellow.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.schedule_rounded, color: AppColors.yellow, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasPeak ? '${_h(start)} – ${_h(end)}' : 'Pas encore de données',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                      Text(
                        hasPeak
                            ? '$peakOrders commande${peakOrders > 1 ? 's' : ''} sur ce créneau (30 derniers jours)'
                            : 'Le pic apparaîtra après les premières commandes',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 70,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var h = 0; h < 24; h++)
                    Expanded(
                      child: Tooltip(
                        message: '${_h(h)} : ${hourly[h]} commande${hourly[h] > 1 ? 's' : ''}',
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: maxCount == 0 ? 0 : hourly[h] / maxCount),
                          duration: const Duration(milliseconds: 800),
                          curve: Curves.easeOutCubic,
                          builder: (_, v, _) => Container(
                            height: 3 + 67 * v,
                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
                            decoration: BoxDecoration(
                              color: inPeak(h) ? strong : scheme.onSurfaceVariant.withValues(alpha: 0.28),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // Repères 0 h, 6 h, 12 h, 18 h alignés sur les barres (6 barres par repère).
            Row(
              children: [
                for (final h in const [0, 6, 12, 18])
                  Expanded(child: Text(_h(h), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Histogramme simple du chiffre d'affaires sur 7 jours (jours sans commande inclus).
class _WeekChart extends StatelessWidget {
  final List<DailyStat> days;
  const _WeekChart({required this.days});

  static const _weekdays = ['Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam', 'Dim'];

  @override
  Widget build(BuildContext context) {
    final byDay = {for (final d in days) d.day: d};
    final now = DateTime.now().toUtc();
    final series = List.generate(7, (i) {
      final d = DateTime.utc(now.year, now.month, now.day).subtract(Duration(days: 6 - i));
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      return (label: _weekdays[d.weekday - 1], stat: byDay[key]);
    });
    final maxRevenue = series.fold<int>(0, (m, e) => (e.stat?.revenue ?? 0) > m ? e.stat!.revenue : m);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: SizedBox(
          height: 170,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final e in series)
                Expanded(
                  child: Tooltip(
                    message: '${e.stat?.orders ?? 0} commandes • ${formatPrice(e.stat?.revenue ?? 0)}',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          e.stat == null ? '' : '${e.stat!.orders}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: maxRevenue == 0 ? 0 : (e.stat?.revenue ?? 0) / maxRevenue),
                          duration: const Duration(milliseconds: 900),
                          curve: Curves.easeOutCubic,
                          builder: (_, v, _) => Container(
                          height: 4 + 110 * v,
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            color: e == series.last ? AppColors.red : AppColors.red.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        ),
                        const SizedBox(height: 6),
                        Text(e.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
