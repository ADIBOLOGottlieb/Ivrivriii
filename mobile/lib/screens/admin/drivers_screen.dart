import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../services/delivery_api.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

/// Admin : gestion des livreurs (ajout, activation, mot de passe).
class DriversScreen extends StatefulWidget {
  const DriversScreen({super.key});

  @override
  State<DriversScreen> createState() => _DriversScreenState();
}

class _DriversScreenState extends State<DriversScreen> {
  List<Driver>? _drivers;
  Object? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await fetchDrivers();
      if (!mounted) return;
      // Actifs d'abord, puis par nom.
      list.sort((a, b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      setState(() {
        _drivers = list;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _add() async {
    final created = await showDialog<Driver>(context: context, builder: (_) => const _DriverFormDialog());
    if (created == null || !mounted) return;
    showMessage(context, 'Livreur ${created.name} ajouté');
    _load();
  }

  Future<void> _toggle(Driver d) async {
    if (d.active) {
      final ok = await confirmDialog(
        context,
        'Désactiver ${d.name} ?',
        d.activeDeliveries > 0
            ? "Il a ${d.activeDeliveries} livraison(s) en cours. Il ne pourra plus se connecter ni prendre "
                'de livraison : pensez à réattribuer ses commandes.'
            : 'Il ne pourra plus se connecter ni prendre de livraison.',
        confirm: 'Désactiver',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy.add(d.id));
    try {
      await updateDriver(d.id, active: !d.active);
      if (!mounted) return;
      showMessage(context, d.active ? '${d.name} désactivé' : '${d.name} réactivé');
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(d.id));
    }
  }

  Future<void> _resetPassword(Driver d) async {
    final password = await showDialog<String>(context: context, builder: (_) => _PasswordDialog(name: d.name));
    if (password == null || !mounted) return;
    setState(() => _busy.add(d.id));
    try {
      await updateDriver(d.id, password: password);
      if (mounted) showMessage(context, 'Mot de passe de ${d.name} modifié');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(d.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final drivers = _drivers;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Livreurs'),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: AppColors.red,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Ajouter un livreur'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: drivers == null
            ? (_error != null
                ? ListView(children: [ErrorRetry(error: _error!, onRetry: _load)])
                : const Center(child: CircularProgressIndicator()))
            : drivers.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 60),
                    EmptyState(
                      emoji: '🛵',
                      title: 'Aucun livreur',
                      message: 'Ajoutez vos livreurs : ils se connectent à l\'application avec leur '
                          'téléphone et le mot de passe que vous leur donnez.',
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                    itemCount: drivers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _DriverTile(
                      driver: drivers[i],
                      busy: _busy.contains(drivers[i].id),
                      onToggle: () => _toggle(drivers[i]),
                      onResetPassword: () => _resetPassword(drivers[i]),
                    ),
                  ),
      ),
    );
  }
}

class _DriverTile extends StatelessWidget {
  final Driver driver;
  final bool busy;
  final VoidCallback onToggle;
  final VoidCallback onResetPassword;
  const _DriverTile({
    required this.driver,
    required this.busy,
    required this.onToggle,
    required this.onResetPassword,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final d = driver;
    final muted = scheme.onSurfaceVariant;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: d.active ? AppColors.yellow : scheme.onSurface.withValues(alpha: 0.10),
                  child: Text(
                    d.name.isEmpty ? '?' : d.name[0].toUpperCase(),
                    style: TextStyle(fontWeight: FontWeight.w900, color: d.active ? Colors.black87 : muted),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: d.active ? scheme.onSurface : muted,
                          )),
                      Text(d.phone, style: TextStyle(color: muted)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Appeler',
                  icon: const Icon(Icons.call_rounded, color: AppColors.green),
                  onPressed: () => launchUrl(Uri(scheme: 'tel', path: d.phone.replaceAll(' ', ''))),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip(d.active ? 'Actif' : 'Désactivé', d.active ? AppColors.green : muted),
                _chip(
                  '${d.activeDeliveries} en cours',
                  d.activeDeliveries > 0 ? Colors.indigo.shade400 : muted,
                ),
                _chip('${d.deliveredCount} livrée${d.deliveredCount > 1 ? 's' : ''}', muted),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onResetPassword,
                  icon: const Icon(Icons.key_rounded, size: 18),
                  label: const Text('Mot de passe'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onToggle,
                  style: TextButton.styleFrom(foregroundColor: d.active ? AppColors.darkRed : AppColors.green),
                  icon: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(d.active ? Icons.block_rounded : Icons.check_circle_rounded, size: 18),
                  label: Text(d.active ? 'Désactiver' : 'Activer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

String? _validatePassword(String? v) =>
    (v ?? '').length < 6 ? 'Au moins 6 caractères' : null;

/// Ajout d'un livreur (nom, téléphone, mot de passe) ; renvoie le livreur créé.
class _DriverFormDialog extends StatefulWidget {
  const _DriverFormDialog();

  @override
  State<_DriverFormDialog> createState() => _DriverFormDialogState();
}

class _DriverFormDialogState extends State<_DriverFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _saving = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final d = await createDriver(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        password: _password.text,
      );
      if (mounted) Navigator.pop(context, d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ajouter un livreur'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nom'),
                validator: (v) => (v ?? '').trim().length < 2 ? 'Nom requis' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Téléphone', helperText: 'Sert à se connecter'),
                validator: (v) => (v ?? '').replaceAll(RegExp(r'\D'), '').length < 8 ? 'Numéro invalide' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Mot de passe',
                  helperText: 'Au moins 6 caractères, à transmettre au livreur',
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: _validatePassword,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Ajouter'),
        ),
      ],
    );
  }
}

/// Nouveau mot de passe d'un livreur ; renvoie le mot de passe saisi.
class _PasswordDialog extends StatefulWidget {
  final String name;
  const _PasswordDialog({required this.name});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _ctrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) Navigator.pop(context, _ctrl.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Réinitialiser le mot de passe'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _ctrl,
          autofocus: true,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'Nouveau mot de passe de ${widget.name}',
            helperText: 'Au moins 6 caractères',
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          validator: _validatePassword,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: _submit,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
