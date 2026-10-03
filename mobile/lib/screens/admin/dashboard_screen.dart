import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
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
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (s.pending > 0)
                    Card(
                      color: AppColors.yellow,
                      child: ListTile(
                        leading: const Icon(Icons.notifications_active_rounded),
                        title: Text(
                          '${s.pending} commande${s.pending > 1 ? 's' : ''} en attente',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        subtitle: const Text('Touchez pour les traiter'),
                        trailing: const Icon(Icons.chevron_right_rounded),
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
                              color: Theme.of(context).colorScheme.errorContainer,
                              child: ListTile(
                                leading: Icon(Icons.price_check_rounded,
                                    color: Theme.of(context).colorScheme.onErrorContainer),
                                title: Text(
                                  '$n paiement${n > 1 ? 's' : ''} à vérifier',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: Theme.of(context).colorScheme.onErrorContainer,
                                  ),
                                ),
                                subtitle: Text(
                                  'Mobile money en attente ou avec un écart',
                                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                                ),
                                trailing: Icon(Icons.chevron_right_rounded,
                                    color: Theme.of(context).colorScheme.onErrorContainer),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const PaymentsReviewScreen()),
                                ),
                              ),
                            ),
                          ),
                  ),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.35,
                    children: [
                      for (final (i, card) in <Widget>[
                      _StatCard(
                        label: "Chiffre d'affaires du jour",
                        value: s.todayRevenue,
                        format: formatPrice,
                        icon: Icons.payments_rounded,
                        color: AppColors.green,
                      ),
                      _StatCard(
                        label: 'Commandes du jour',
                        value: s.todayOrders,
                        icon: Icons.receipt_rounded,
                        color: AppColors.red,
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
                      ].indexed)
                        FadeSlideIn(delay: FadeSlideIn.stagger(i, stepMs: 70), child: card),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.emoji_events_rounded, color: AppColors.yellow, size: 32),
                      title: AnimatedCount(
                        value: s.deliveredRevenue,
                        format: formatPrice,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                      ),
                      subtitle: Text('Total des commandes livrées (${s.deliveredOrders}), hors remboursements'),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('7 derniers jours', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                  const SizedBox(height: 10),
                  _WeekChart(days: s.last7Days),
                  const SizedBox(height: 20),
                  const Text('Top ventes', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                  const SizedBox(height: 10),
                  Card(
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
                                        style: const TextStyle(fontWeight: FontWeight.w900)),
                                  ),
                                  title: Text(s.topProducts[i].name,
                                      style: const TextStyle(fontWeight: FontWeight.w700)),
                                  subtitle: Text('${s.topProducts[i].quantity} vendus'),
                                  trailing: Text(formatPrice(s.topProducts[i].revenue),
                                      style: const TextStyle(fontWeight: FontWeight.w700)),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final int value;
  final String Function(int) format;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.format = _plain,
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
