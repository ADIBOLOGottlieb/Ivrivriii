import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../models_admin.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import 'admin_layout.dart';

/// Gérant : comptes du personnel (gérant = accès complet, cuisine = commandes et disponibilité des plats).
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  List<StaffMember>? _staff;
  Object? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await fetchStaff();
      if (!mounted) return;
      // Actifs d'abord, gérants avant cuisine, puis par nom.
      list.sort((a, b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        if (a.isKitchen != b.isKitchen) return a.isKitchen ? 1 : -1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      setState(() {
        _staff = list;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Lance une modification ; l'erreur du serveur (ex. « Il faut au moins un gérant actif ») est affichée telle quelle.
  Future<void> _update(StaffMember m, String done, Future<StaffMember> Function() action) async {
    setState(() => _busy.add(m.id));
    try {
      await action();
      if (!mounted) return;
      showMessage(context, done);
      await _load();
    } catch (e) {
      if (mounted) await _showError(e);
    } finally {
      if (mounted) setState(() => _busy.remove(m.id));
    }
  }

  Future<void> _showError(Object e) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.error_outline_rounded, color: Theme.of(ctx).colorScheme.error),
          title: const Text('Modification refusée'),
          content: Text(e.toString()),
          actions: [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  Future<void> _add() async {
    final created = await showDialog<StaffMember>(context: context, builder: (_) => const _StaffFormDialog());
    if (created == null || !mounted) return;
    showMessage(context, '${created.name} ajouté (${staffLevelLabel(created.adminLevel)})');
    _load();
  }

  Future<void> _changeLevel(StaffMember m, {required bool self}) async {
    final level = m.isKitchen ? 'manager' : 'kitchen';
    final ok = await confirmDialog(
      context,
      level == 'manager' ? 'Passer ${m.name} en gérant ?' : 'Passer ${m.name} en cuisine ?',
      (level == 'manager'
              ? 'Accès complet : argent, réglages, personnel, clients.'
              : 'Accès limité aux commandes, à la disponibilité des plats et aux livreurs.') +
          (self
              ? '\n\nC\'est votre propre compte : vous devrez vous reconnecter.'
              : '\n\nLa personne devra se reconnecter.'),
      confirm: 'Changer',
    );
    if (!ok || !mounted) return;
    await _update(m, '${m.name} : ${staffLevelLabel(level)}', () => updateStaff(m.id, adminLevel: level));
  }

  Future<void> _toggleActive(StaffMember m, {required bool self}) async {
    if (m.active) {
      final ok = await confirmDialog(
        context,
        'Désactiver ${m.name} ?',
        self
            ? 'C\'est votre propre compte : vous serez déconnecté et ne pourrez plus vous reconnecter.'
            : 'Cette personne ne pourra plus se connecter à l\'espace du restaurant.',
        confirm: 'Désactiver',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    await _update(
      m,
      m.active ? '${m.name} désactivé' : '${m.name} réactivé',
      () => updateStaff(m.id, active: !m.active),
    );
  }

  Future<void> _resetPassword(StaffMember m, {required bool self}) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _PasswordDialog(name: m.name, self: self),
    );
    if (password == null || !mounted) return;
    await _update(m, 'Mot de passe de ${m.name} modifié', () => updateStaff(m.id, password: password));
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthProvider>().user;
    final staff = _staff;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Personnel'),
        actions: [IconButton(tooltip: 'Actualiser', onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        backgroundColor: AppColors.red,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Ajouter'),
      ),
      body: MaxContentWidth(
        maxWidth: 760,
        child: RefreshIndicator(
          onRefresh: _load,
          child: staff == null
              ? (_error != null
                  ? ListView(children: [ErrorRetry(error: _error!, onRetry: _load)])
                  : const Center(child: CircularProgressIndicator()))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                  children: [
                    const _LevelsHelp(),
                    const SizedBox(height: 12),
                    if (staff.isEmpty)
                      const EmptyState(emoji: '👩‍🍳', title: 'Aucun compte du personnel'),
                    for (final (i, m) in staff.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: FadeSlideIn(
                          key: ValueKey('staff-${m.id}'),
                          delay: FadeSlideIn.stagger(i),
                          child: _StaffTile(
                            member: m,
                            self: me?.id == m.id,
                            busy: _busy.contains(m.id),
                            onLevel: () => _changeLevel(m, self: me?.id == m.id),
                            onToggle: () => _toggleActive(m, self: me?.id == m.id),
                            onPassword: () => _resetPassword(m, self: me?.id == m.id),
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

/// Rappel des deux niveaux d'accès.
class _LevelsHelp extends StatelessWidget {
  const _LevelsHelp();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.35);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: 'Gérant', style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
                const TextSpan(text: ' : accès complet (argent, réglages, personnel, clients).\n'),
                TextSpan(text: 'Cuisine', style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
                const TextSpan(
                    text: ' : commandes, disponibilité des plats, attribution des livreurs. '
                        'Ni chiffre d\'affaires, ni paiements, ni réglages.'),
              ]),
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffTile extends StatelessWidget {
  final StaffMember member;
  final bool self; // compte connecté
  final bool busy;
  final VoidCallback onLevel;
  final VoidCallback onToggle;
  final VoidCallback onPassword;

  const _StaffTile({
    required this.member,
    required this.self,
    required this.busy,
    required this.onLevel,
    required this.onToggle,
    required this.onPassword,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final m = member;
    final muted = scheme.onSurfaceVariant;
    final levelColor = m.isKitchen ? (dark ? Colors.orange.shade300 : Colors.orange.shade800) : (dark ? scheme.primary : AppColors.red);
    final activeColor = dark ? AppColors.darkTertiary : AppColors.green;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: m.active ? AppColors.yellow : scheme.onSurface.withValues(alpha: 0.10),
                  child: Icon(
                    m.isKitchen ? Icons.soup_kitchen_rounded : Icons.admin_panel_settings_rounded,
                    color: m.active ? AppColors.ink : muted,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        self ? '${m.name} (vous)' : m.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: m.active ? scheme.onSurface : muted,
                        ),
                      ),
                      Text(m.phone, style: TextStyle(color: muted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip(staffLevelLabel(m.adminLevel), levelColor),
                _chip(m.active ? 'Actif' : 'Désactivé', m.active ? activeColor : muted),
                _chip('Depuis le ${formatDateTime(m.createdAt).split(' à ').first}', muted),
              ],
            ),
            const SizedBox(height: 2),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onLevel,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: Text(m.isKitchen ? 'Passer gérant' : 'Passer cuisine'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onPassword,
                  icon: const Icon(Icons.key_rounded, size: 18),
                  label: const Text('Mot de passe'),
                ),
                TextButton.icon(
                  onPressed: busy ? null : onToggle,
                  style: TextButton.styleFrom(foregroundColor: m.active ? (dark ? scheme.error : AppColors.darkRed) : activeColor),
                  icon: busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(m.active ? Icons.block_rounded : Icons.check_circle_rounded, size: 18),
                  label: Text(m.active ? 'Désactiver' : 'Activer'),
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
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

String? _validatePassword(String? v) => (v ?? '').length < 6 ? 'Au moins 6 caractères' : null;

/// Création d'un compte du personnel (nom, téléphone, mot de passe, niveau) ; renvoie le compte créé.
class _StaffFormDialog extends StatefulWidget {
  const _StaffFormDialog();

  @override
  State<_StaffFormDialog> createState() => _StaffFormDialogState();
}

class _StaffFormDialogState extends State<_StaffFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  String _level = 'kitchen';
  bool _saving = false;
  bool _obscure = true;
  String? _error; // message du serveur (ex. numéro déjà utilisé)

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
      final m = await createStaff(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        password: _password.text,
        adminLevel: _level,
      );
      if (mounted) Navigator.pop(context, m);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ajouter un membre du personnel'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  helperText: 'Au moins 6 caractères, à transmettre à la personne',
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: _validatePassword,
              ),
              const SizedBox(height: 16),
              Text('Niveau', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'kitchen', label: Text('Cuisine'), icon: Icon(Icons.soup_kitchen_rounded)),
                  ButtonSegment(
                      value: 'manager', label: Text('Gérant'), icon: Icon(Icons.admin_panel_settings_rounded)),
                ],
                selected: {_level},
                onSelectionChanged: (v) => setState(() => _level = v.first),
              ),
              const SizedBox(height: 6),
              Text(
                _level == 'kitchen'
                    ? 'Commandes, disponibilité des plats et livreurs.'
                    : 'Accès complet, y compris l\'argent et les réglages.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w700)),
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

/// Nouveau mot de passe ; renvoie le mot de passe saisi.
class _PasswordDialog extends StatefulWidget {
  final String name;
  final bool self;
  const _PasswordDialog({required this.name, required this.self});

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
      title: const Text('Nouveau mot de passe'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _ctrl,
          autofocus: true,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'Mot de passe de ${widget.name}',
            helperText: widget.self
                ? 'Au moins 6 caractères. Vous devrez vous reconnecter.'
                : 'Au moins 6 caractères. La personne devra se reconnecter.',
            helperMaxLines: 2,
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
