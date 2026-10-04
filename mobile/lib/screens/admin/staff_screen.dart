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

/// Personnel : propriétaire (unique, intouchable), gérants (accès complet) et cuisine (commandes et
/// disponibilité des plats). Les actions affichées dépendent du compte connecté, pour ne jamais proposer
/// une opération que le serveur refuserait.
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

/// Droits du compte connecté sur un membre du personnel (miroir des règles du serveur).
class _StaffRights {
  final bool rename;
  final bool password;
  final bool level;
  final bool toggle;
  final bool delete;

  const _StaffRights({
    this.rename = false,
    this.password = false,
    this.level = false,
    this.toggle = false,
    this.delete = false,
  });

  bool get any => rename || password || level || toggle || delete;

  factory _StaffRights.of(AppUser? me, StaffMember m) {
    if (me == null || !me.isAdmin || me.isKitchen) return const _StaffRights();
    final self = me.id == m.id;
    // Son propre compte : nom et mot de passe seulement (ni niveau, ni activation, ni suppression).
    if (self) return const _StaffRights(rename: true, password: true);
    // Le propriétaire n'est modifiable par personne d'autre.
    if (m.isOwner) return const _StaffRights();
    // Propriétaire : tout sur les gérants et la cuisine. Gérant : comptes cuisine seulement.
    if (me.isOwner || m.isKitchen) {
      return _StaffRights(rename: true, password: true, level: me.isOwner, toggle: true, delete: true);
    }
    return const _StaffRights();
  }
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

  static int _rank(StaffMember m) => m.isOwner ? 0 : (m.isKitchen ? 2 : 1);

  Future<void> _load() async {
    try {
      final list = await fetchStaff();
      if (!mounted) return;
      // Propriétaire en tête, puis actifs, gérants avant cuisine, puis par nom.
      list.sort((a, b) {
        if (a.isOwner != b.isOwner) return a.isOwner ? -1 : 1;
        if (a.active != b.active) return a.active ? -1 : 1;
        final r = _rank(a).compareTo(_rank(b));
        if (r != 0) return r;
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

  /// Lance une opération ; l'erreur du serveur est affichée telle quelle, puis la liste est rechargée.
  Future<void> _run(StaffMember m, String done, Future<void> Function() action) async {
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

  Future<void> _add({required bool owner}) async {
    final created = await showDialog<StaffMember>(
      context: context,
      builder: (_) => _StaffFormDialog(canCreateManager: owner),
    );
    if (created == null || !mounted) return;
    showMessage(context, '${created.name} ajouté (${staffLevelLabel(created.adminLevel)})');
    _load();
  }

  Future<void> _changeLevel(StaffMember m) async {
    final level = m.isKitchen ? 'manager' : 'kitchen';
    final ok = await confirmDialog(
      context,
      level == 'manager' ? 'Passer ${m.name} en gérant ?' : 'Passer ${m.name} en cuisine ?',
      '${level == 'manager' ? 'Accès complet : argent, réglages, personnel cuisine, clients.' : 'Accès limité aux commandes, à la disponibilité des plats et aux livreurs.'}'
      '\n\nLa personne devra se reconnecter.',
      confirm: 'Changer',
    );
    if (!ok || !mounted) return;
    await _run(m, '${m.name} : ${staffLevelLabel(level)}', () => updateStaff(m.id, adminLevel: level));
  }

  Future<void> _toggleActive(StaffMember m) async {
    if (m.active) {
      final ok = await confirmDialog(
        context,
        'Désactiver ${m.name} ?',
        'Cette personne ne pourra plus se connecter à l\'espace du restaurant.',
        confirm: 'Désactiver',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    await _run(
      m,
      m.active ? '${m.name} désactivé' : '${m.name} réactivé',
      () => updateStaff(m.id, active: !m.active),
    );
  }

  Future<void> _rename(StaffMember m, {required bool self}) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: m.name, self: self),
    );
    if (name == null || name == m.name || !mounted) return;
    final auth = context.read<AuthProvider>();
    await _run(m, 'Nom modifié : $name', () async {
      await updateStaff(m.id, name: name);
      // Son propre nom : rafraîchir le compte connecté.
      if (self) await auth.refreshUser();
    });
  }

  Future<void> _resetPassword(StaffMember m, {required bool self}) async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => _PasswordDialog(name: m.name, self: self),
    );
    if (password == null || !mounted) return;
    await _run(m, 'Mot de passe de ${m.name} modifié', () => updateStaff(m.id, password: password));
  }

  Future<void> _delete(StaffMember m) async {
    final ok = await confirmDialog(
      context,
      'Supprimer le compte ?',
      'Supprimer définitivement le compte de ${m.name} ? Ses commandes sont conservées.',
      confirm: 'Supprimer',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _run(m, 'Compte de ${m.name} supprimé', () => deleteStaff(m.id));
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthProvider>().user;
    final canCreate = me != null && me.isAdmin && !me.isKitchen;
    final owner = me?.isOwner ?? false;
    final staff = _staff;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Personnel'),
        actions: [IconButton(tooltip: 'Actualiser', onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => _add(owner: owner),
              backgroundColor: AppColors.red,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Ajouter'),
            )
          : null,
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
                    _LevelsHelp(owner: owner),
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
                            rights: _StaffRights.of(me, m),
                            busy: _busy.contains(m.id),
                            onRename: () => _rename(m, self: me?.id == m.id),
                            onLevel: () => _changeLevel(m),
                            onToggle: () => _toggleActive(m),
                            onPassword: () => _resetPassword(m, self: me?.id == m.id),
                            onDelete: () => _delete(m),
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

/// Rappel des niveaux d'accès.
class _LevelsHelp extends StatelessWidget {
  final bool owner; // compte connecté = propriétaire
  const _LevelsHelp({required this.owner});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.35);
    final bold = TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface);
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
                TextSpan(text: 'Propriétaire', style: bold),
                const TextSpan(text: ' : gère les gérants et la cuisine. Son compte ne peut être ni modifié par un autre, ni supprimé.\n'),
                TextSpan(text: 'Gérant', style: bold),
                const TextSpan(text: ' : accès complet (argent, réglages, clients) et gestion des comptes cuisine.\n'),
                TextSpan(text: 'Cuisine', style: bold),
                const TextSpan(
                    text: ' : commandes, disponibilité des plats, attribution des livreurs. '
                        'Ni chiffre d\'affaires, ni paiements, ni réglages.'),
                if (!owner)
                  const TextSpan(text: '\nSeul le propriétaire peut créer ou modifier un administrateur.'),
              ]),
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

Color _goldColor(bool dark) => dark ? const Color(0xFFFFD54F) : const Color(0xFF9A6B00);

class _StaffTile extends StatelessWidget {
  final StaffMember member;
  final bool self; // compte connecté
  final _StaffRights rights;
  final bool busy;
  final VoidCallback onRename;
  final VoidCallback onLevel;
  final VoidCallback onToggle;
  final VoidCallback onPassword;
  final VoidCallback onDelete;

  const _StaffTile({
    required this.member,
    required this.self,
    required this.rights,
    required this.busy,
    required this.onRename,
    required this.onLevel,
    required this.onToggle,
    required this.onPassword,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final m = member;
    final muted = scheme.onSurfaceVariant;
    final gold = _goldColor(dark);
    final levelColor = m.isOwner
        ? gold
        : m.isKitchen
            ? (dark ? Colors.orange.shade300 : Colors.orange.shade800)
            : (dark ? scheme.primary : AppColors.red);
    final activeColor = dark ? AppColors.darkTertiary : AppColors.green;
    final dangerColor = dark ? scheme.error : AppColors.darkRed;
    final r = rights;
    return Card(
      shape: m.isOwner
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: gold.withValues(alpha: 0.55), width: 1.5),
            )
          : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 8, r.any ? 6 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: m.active ? AppColors.yellow : scheme.onSurface.withValues(alpha: 0.10),
                  child: Icon(
                    m.isOwner
                        ? Icons.workspace_premium_rounded
                        : m.isKitchen
                            ? Icons.soup_kitchen_rounded
                            : Icons.admin_panel_settings_rounded,
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
                _chip(staffLevelLabel(m.adminLevel), levelColor,
                    icon: m.isOwner ? Icons.workspace_premium_rounded : null),
                _chip(m.active ? 'Actif' : 'Désactivé', m.active ? activeColor : muted),
                _chip('Depuis le ${formatDateTime(m.createdAt).split(' à ').first}', muted),
              ],
            ),
            if (r.any) ...[
              const SizedBox(height: 2),
              Wrap(
                alignment: WrapAlignment.end,
                children: [
                  if (r.rename)
                    TextButton.icon(
                      onPressed: busy ? null : onRename,
                      icon: const Icon(Icons.edit_rounded, size: 18),
                      label: const Text('Nom'),
                    ),
                  if (r.level)
                    TextButton.icon(
                      onPressed: busy ? null : onLevel,
                      icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                      label: Text(m.isKitchen ? 'Passer gérant' : 'Passer cuisine'),
                    ),
                  if (r.password)
                    TextButton.icon(
                      onPressed: busy ? null : onPassword,
                      icon: const Icon(Icons.key_rounded, size: 18),
                      label: const Text('Mot de passe'),
                    ),
                  if (r.toggle)
                    TextButton.icon(
                      onPressed: busy ? null : onToggle,
                      style: TextButton.styleFrom(foregroundColor: m.active ? dangerColor : activeColor),
                      icon: busy
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(m.active ? Icons.block_rounded : Icons.check_circle_rounded, size: 18),
                      label: Text(m.active ? 'Désactiver' : 'Activer'),
                    ),
                  if (r.delete)
                    TextButton.icon(
                      onPressed: busy ? null : onDelete,
                      style: TextButton.styleFrom(foregroundColor: dangerColor),
                      icon: const Icon(Icons.delete_forever_rounded, size: 18),
                      label: const Text('Supprimer le compte'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color, {IconData? icon}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
            ],
            Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

String? _validatePassword(String? v) => (v ?? '').length < 6 ? 'Au moins 6 caractères' : null;

/// Création d'un compte du personnel (nom, téléphone, mot de passe, niveau) ; renvoie le compte créé.
/// Propriétaire : administrateur (gérant) ou cuisine. Gérant : cuisine seulement.
class _StaffFormDialog extends StatefulWidget {
  final bool canCreateManager;
  const _StaffFormDialog({required this.canCreateManager});

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
        adminLevel: widget.canCreateManager ? _level : 'kitchen',
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
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
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
              Text('Niveau', style: TextStyle(color: muted)),
              const SizedBox(height: 6),
              if (widget.canCreateManager) ...[
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'kitchen', label: Text('Cuisine'), icon: Icon(Icons.soup_kitchen_rounded)),
                    ButtonSegment(
                      value: 'manager',
                      label: Text('Administrateur (gérant)'),
                      icon: Icon(Icons.admin_panel_settings_rounded),
                    ),
                  ],
                  selected: {_level},
                  onSelectionChanged: (v) => setState(() => _level = v.first),
                ),
                const SizedBox(height: 6),
                Text(
                  _level == 'kitchen'
                      ? 'Commandes, disponibilité des plats et livreurs.'
                      : 'Accès complet, y compris l\'argent, les réglages et les comptes cuisine.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ] else ...[
                Row(
                  children: [
                    Icon(Icons.soup_kitchen_rounded, size: 20, color: muted),
                    const SizedBox(width: 8),
                    Text('Cuisine', style: TextStyle(fontWeight: FontWeight.w800, color: Theme.of(context).colorScheme.onSurface)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Commandes, disponibilité des plats et livreurs.\nSeul le propriétaire peut créer un administrateur.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
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

/// Nouveau nom ; renvoie le nom saisi (sans espaces superflus).
class _NameDialog extends StatefulWidget {
  final String initial;
  final bool self;
  const _NameDialog({required this.initial, required this.self});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) Navigator.pop(context, _ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.self ? 'Modifier votre nom' : 'Modifier le nom'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nom'),
          validator: (v) => (v ?? '').trim().length < 2 ? 'Nom requis' : null,
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
