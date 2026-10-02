import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/driver_api.dart';
import '../../services/order_events.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'driver_actions.dart';

/// Profil du livreur : identité, statistiques du jour, thème, déconnexion.
class DriverProfileScreen extends StatefulWidget {
  final bool active;
  const DriverProfileScreen({super.key, this.active = false});

  @override
  State<DriverProfileScreen> createState() => _DriverProfileScreenState();
}

class _DriverProfileScreenState extends State<DriverProfileScreen> {
  DriverStats? _stats;
  Object? _error;

  @override
  void initState() {
    super.initState();
    ordersChanged.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(DriverProfileScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  @override
  void dispose() {
    ordersChanged.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await fetchDriverStats();
      if (mounted) {
        setState(() {
          _stats = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = context.watch<AuthProvider>().user;
    final theme = context.watch<ThemeProvider>();
    final stats = _stats;

    return Scaffold(
      appBar: AppBar(title: const Text('Mon profil')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: AppColors.red.withValues(alpha: 0.15),
                      child: const Icon(Icons.delivery_dining_rounded, size: 34, color: AppColors.red),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user?.name ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                          const SizedBox(height: 2),
                          Text(formatPhoneDisplay(user?.phone ?? ''),
                              style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant)),
                          const SizedBox(height: 2),
                          const Text('Livreur', style: TextStyle(color: AppColors.red, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 12, 4, 8),
              child: Text('Aujourd\'hui', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            if (stats == null && _error != null)
              Text('Statistiques indisponibles : $_error', style: TextStyle(color: cs.error))
            else
              Row(
                children: [
                  Expanded(
                    child: _StatTile(
                      icon: Icons.check_circle_rounded,
                      color: AppColors.green,
                      value: stats == null ? '…' : '${stats.todayCount}',
                      label: 'Livraisons',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _StatTile(
                      icon: Icons.payments_rounded,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppColors.yellow
                          : const Color(0xFF9A6A00),
                      value: stats == null ? '…' : formatPrice(stats.todayCash),
                      label: 'Espèces encaissées',
                    ),
                  ),
                ],
              ),
            if (stats != null && stats.activeCount > 0) ...[
              const SizedBox(height: 10),
              Text(
                '${stats.activeCount} livraison${stats.activeCount > 1 ? 's' : ''} en cours',
                style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
              ),
            ],
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 20, 4, 8),
              child: Text('Apparence', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: [
                    for (final m in const [ThemeMode.light, ThemeMode.system, ThemeMode.dark])
                      ButtonSegment(
                        value: m,
                        icon: Icon(switch (m) {
                          ThemeMode.light => Icons.light_mode_rounded,
                          ThemeMode.dark => Icons.dark_mode_rounded,
                          ThemeMode.system => Icons.brightness_auto_rounded,
                        }),
                        label: Text(ThemeProvider.label(m)),
                      ),
                  ],
                  selected: {theme.themeMode},
                  onSelectionChanged: (s) => theme.setThemeMode(s.first),
                ),
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.darkRed,
                minimumSize: const Size.fromHeight(54),
              ),
              onPressed: () async {
                if (await confirmDialog(context, 'Déconnexion', 'Voulez-vous vous déconnecter ?',
                    confirm: 'Se déconnecter')) {
                  if (!context.mounted) return;
                  context.read<AuthProvider>().logout();
                }
              },
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Se déconnecter'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  const _StatTile({required this.icon, required this.color, required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            ),
            Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
