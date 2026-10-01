import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../models_admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_api.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import '../client/profile_screen.dart';
import 'collections_screen.dart';
import 'payments_review_screen.dart';

class AdminMoreScreen extends StatelessWidget {
  const AdminMoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    void open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

    return Scaffold(
      appBar: AppBar(title: const Text('Plus')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.storefront_rounded, color: AppColors.red),
                  title: const Text('Paramètres du restaurant'),
                  subtitle: const Text('Ouverture, frais de livraison, contact'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => open(const SettingsScreen()),
                ),
                ListTile(
                  leading: const Icon(Icons.people_alt_rounded, color: AppColors.red),
                  title: const Text('Clients'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => open(const CustomersScreen()),
                ),
                if (user != null)
                  ListTile(
                    leading: const Icon(Icons.manage_accounts_rounded, color: AppColors.red),
                    title: const Text('Mon compte administrateur'),
                    subtitle: Text(user.phone),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => open(EditProfileScreen(user: user)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.price_check_rounded, color: AppColors.red),
                  title: const Text('Paiements à vérifier'),
                  subtitle: const Text('Mobile money en attente ou avec un écart'),
                  trailing: ValueListenableBuilder<int>(
                    valueListenable: paymentReviewCount,
                    builder: (_, n, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (n > 0) Badge(label: Text('$n'), backgroundColor: AppColors.red),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                  ),
                  onTap: () => open(const PaymentsReviewScreen()),
                ),
                ListTile(
                  leading: const Icon(Icons.account_balance_wallet_rounded, color: AppColors.red),
                  title: const Text('Encaissements'),
                  subtitle: const Text('Totaux, frais, reversements, export CSV'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => open(const CollectionsScreen()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.darkRed),
            onPressed: () async {
              if (await confirmDialog(context, 'Déconnexion', 'Voulez-vous vous déconnecter ?',
                  confirm: 'Se déconnecter')) {
                if (context.mounted) context.read<AuthProvider>().logout();
              }
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Se déconnecter'),
          ),
          const SizedBox(height: 32),
          const Center(child: AppLogo(size: 80)),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fee = TextEditingController();
  final _min = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _cancelMinutes = TextEditingController();
  late final Future<MerchantInfo> _merchant = fetchMerchant();
  AppSettings? _current; // réglages chargés : conserve les champs non modifiés ici
  bool _isOpen = true;
  bool _loaded = false;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_fee, _min, _phone, _address, _cancelMinutes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await Api.instance.settings();
      if (!mounted) return;
      setState(() {
        _fee.text = '${s.deliveryFee}';
        _min.text = '${s.minOrder}';
        _phone.text = s.restaurantPhone;
        _address.text = s.restaurantAddress;
        _isOpen = s.isOpen;
        _cancelMinutes.text = '${s.momoUnpaidCancelMinutes}';
        _current = s;
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await Api.instance.saveSettings(AppSettings(
        deliveryFee: int.parse(_fee.text.trim()),
        minOrder: int.parse(_min.text.trim()),
        isOpen: _isOpen,
        restaurantPhone: _phone.text.trim(),
        restaurantAddress: _address.text.trim(),
        // Champs non modifiés ici : on renvoie les valeurs chargées pour ne pas les écraser
        // par les valeurs par défaut de AppSettings (ex. frais de paiement 2 %).
        paymentFeePercent: _current?.paymentFeePercent ?? 2,
        paymentMode: _current?.paymentMode ?? 'test',
        paymentProvider: _current?.paymentProvider ?? 'simulation',
        maxQuantityPerItem: _current?.maxQuantityPerItem ?? 999,
        momoUnpaidCancelMinutes: int.parse(_cancelMinutes.text.trim()),
      ));
      if (!mounted) return;
      showMessage(context, 'Paramètres enregistrés');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _amount(String? v) => int.tryParse(v?.trim() ?? '') == null ? 'Montant invalide' : null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: !_loaded
          ? (_error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : const Center(child: CircularProgressIndicator()))
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Card(
                    color: _isOpen
                        ? AppColors.green.withValues(alpha: 0.12)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: SwitchListTile(
                      value: _isOpen,
                      activeTrackColor: AppColors.green,
                      onChanged: (v) => setState(() => _isOpen = v),
                      title: Text(_isOpen ? 'Restaurant ouvert' : 'Restaurant fermé',
                          style: const TextStyle(fontWeight: FontWeight.w900)),
                      subtitle: Text(_isOpen
                          ? 'Les clients peuvent commander'
                          : 'Les nouvelles commandes sont bloquées'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _fee,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Frais de livraison', suffixText: 'FCFA'),
                    validator: _amount,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _min,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Montant minimum de commande', suffixText: 'FCFA'),
                    validator: _amount,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Téléphone du restaurant'),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _address,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Adresse du restaurant'),
                  ),
                  const SizedBox(height: 24),
                  const Text('Paiement mobile money', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _cancelMinutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Annulation auto des commandes mobile money non payées',
                      helperText: 'Délai en minutes, entre 5 et 1440 (24 h)',
                      helperMaxLines: 2,
                      suffixText: 'min',
                    ),
                    validator: (v) {
                      final n = int.tryParse(v?.trim() ?? '');
                      if (n == null || n < 5 || n > 1440) return 'Entre 5 et 1440 minutes';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  _MerchantCard(future: _merchant),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Text('Enregistrer'),
                  ),
                ],
              ),
            ),
    );
  }
}

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  late Future<List<CustomerSummary>> _future = Api.instance.users();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Clients')),
      body: FutureBuilder<List<CustomerSummary>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ErrorRetry(
              error: snap.error!,
              onRetry: () => setState(() => _future = Api.instance.users()),
            );
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final q = _query.toLowerCase();
          final users = snap.data!
              .where((c) => !c.user.isAdmin)
              .where((c) => q.isEmpty || c.user.name.toLowerCase().contains(q) || c.user.phone.contains(q))
              .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Rechercher un client...',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ),
              Expanded(
                child: users.isEmpty
                    ? const EmptyState(emoji: '👥', title: 'Aucun client')
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        itemCount: users.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final c = users[i];
                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.yellow,
                                child: Text(
                                  c.user.name.isEmpty ? '?' : c.user.name[0].toUpperCase(),
                                  style: const TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                              title: Text(c.user.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                              subtitle: Text(
                                '${c.user.phone}\n${c.ordersCount} commande${c.ordersCount > 1 ? 's' : ''} • '
                                '${formatPrice(c.totalSpent)}',
                              ),
                              isThreeLine: true,
                              trailing: IconButton(
                                icon: const Icon(Icons.call_rounded, color: AppColors.green),
                                onPressed: () =>
                                    launchUrl(Uri(scheme: 'tel', path: c.user.phone.replaceAll(' ', ''))),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Compte marchand mobile money, en lecture seule (numéros masqués côté serveur).
class _MerchantCard extends StatelessWidget {
  final Future<MerchantInfo> future;
  const _MerchantCard({required this.future});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<MerchantInfo>(
          future: future,
          builder: (context, snap) {
            final header = Row(
              children: [
                const Icon(Icons.store_mall_directory_rounded, color: AppColors.red),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Compte marchand',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: cs.onSurface)),
                ),
                Icon(Icons.lock_outline_rounded, size: 18, color: cs.onSurfaceVariant),
              ],
            );
            if (snap.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  const SizedBox(height: 10),
                  Text('Informations indisponibles : ${snap.error}', style: TextStyle(color: cs.error)),
                ],
              );
            }
            final m = snap.data;
            if (m == null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  const SizedBox(height: 16),
                  const Center(child: CircularProgressIndicator()),
                ],
              );
            }
            Widget row(String label, String? value) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
                      ),
                      Expanded(
                        child: Text(
                          (value ?? '').isEmpty ? 'Non configuré' : value!,
                          style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface),
                        ),
                      ),
                    ],
                  ),
                );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 4),
                row('Prestataire', providerLabel(m.provider)),
                row('Nom affiché', m.displayName),
                row('Flooz', m.flooz),
                row('Mixx', m.mixx),
                if (m.settlement.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Reversement', style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(m.settlement, style: TextStyle(color: cs.onSurface)),
                ],
                const SizedBox(height: 10),
                Text(
                  'Ces informations se modifient côté serveur (variables d\'environnement), pas depuis l\'application.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
