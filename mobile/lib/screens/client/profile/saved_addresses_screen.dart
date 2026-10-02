import 'package:flutter/material.dart';

import '../../../models.dart';
import '../../../services/account_api.dart';
import '../../../theme.dart';
import '../../../widgets/common.dart';
import '../gps_picker_screen.dart';
import '../location_import_sheet.dart';

const _labelHome = 'Maison';
const _labelOffice = 'Bureau';

IconData _labelIcon(String label) {
  switch (label.trim().toLowerCase()) {
    case 'maison':
      return Icons.home_rounded;
    case 'bureau':
      return Icons.work_rounded;
    default:
      return Icons.place_rounded;
  }
}

/// Feuille du bas : choix d'une adresse enregistrée (utilisée par l'écran de commande).
/// Renvoie l'adresse choisie, ou null si le client ferme la feuille.
Future<SavedAddress?> showSavedAddressPicker(BuildContext context) {
  return showModalBottomSheet<SavedAddress>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SavedAddressPickerSheet(),
  );
}

class _SavedAddressPickerSheet extends StatefulWidget {
  const _SavedAddressPickerSheet();

  @override
  State<_SavedAddressPickerSheet> createState() => _SavedAddressPickerSheetState();
}

class _SavedAddressPickerSheetState extends State<_SavedAddressPickerSheet> {
  late Future<List<SavedAddress>> _future = fetchSavedAddresses();

  void _reload() => setState(() => _future = fetchSavedAddresses());

  Future<void> _manage() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SavedAddressesScreen()));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Mes adresses', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            Flexible(
              child: FutureBuilder<List<SavedAddress>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            snap.error.toString(),
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('Réessayer'),
                          ),
                        ],
                      ),
                    );
                  }
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final list = snap.data ?? const <SavedAddress>[];
                  if (list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Text(
                        'Aucune adresse enregistrée. Ajoutez « Maison » ou « Bureau » pour commander plus vite.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final a = list[i];
                      return ListTile(
                        leading: Icon(_labelIcon(a.label), color: AppColors.red),
                        title: Text(a.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(a.address, maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: a.hasLocation
                            ? const Tooltip(
                                message: 'Position GPS enregistrée',
                                child: Icon(Icons.gps_fixed_rounded, size: 18, color: AppColors.green),
                              )
                            : null,
                        onTap: () => Navigator.pop(context, a),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.edit_location_alt_rounded, color: AppColors.red),
              title: const Text('Gérer mes adresses'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _manage,
            ),
          ],
        ),
      ),
    );
  }
}

/// Liste des adresses enregistrées : ajout, modification, suppression.
class SavedAddressesScreen extends StatefulWidget {
  const SavedAddressesScreen({super.key});

  @override
  State<SavedAddressesScreen> createState() => _SavedAddressesScreenState();
}

class _SavedAddressesScreenState extends State<SavedAddressesScreen> {
  late Future<List<SavedAddress>> _future = fetchSavedAddresses();

  Future<void> _reload() async {
    final f = fetchSavedAddresses();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // L'erreur est affichée par le FutureBuilder.
    }
  }

  Future<void> _edit([SavedAddress? address]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => SavedAddressFormScreen(address: address)),
    );
    if (saved == true && mounted) _reload();
  }

  Future<void> _delete(SavedAddress a) async {
    final ok = await confirmDialog(
      context,
      'Supprimer l\'adresse',
      'Supprimer « ${a.label} » de vos adresses ?',
      confirm: 'Supprimer',
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await deleteSavedAddress(a.id);
      if (!mounted) return;
      showMessage(context, 'Adresse supprimée');
      _reload();
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mes adresses')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_location_alt_rounded),
        label: const Text('Ajouter'),
      ),
      body: FutureBuilder<List<SavedAddress>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorRetry(error: snap.error!, onRetry: _reload);
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data ?? const <SavedAddress>[];
          if (list.isEmpty) {
            return EmptyState(
              emoji: '📍',
              title: 'Aucune adresse enregistrée',
              message: 'Ajoutez vos adresses (Maison, Bureau...) pour les retrouver en un geste à la commande.',
              action: FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_location_alt_rounded),
                label: const Text('Ajouter une adresse'),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final a = list[i];
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                    leading: CircleAvatar(
                      backgroundColor: AppColors.red.withValues(alpha: 0.12),
                      child: Icon(_labelIcon(a.label), color: AppColors.red),
                    ),
                    title: Text(a.label, style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.address),
                        if (a.hasLocation)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                const Icon(Icons.gps_fixed_rounded, size: 14, color: AppColors.green),
                                const SizedBox(width: 4),
                                Text('Position GPS enregistrée',
                                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    onTap: () => _edit(a),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Actions',
                      onSelected: (v) => v == 'edit' ? _edit(a) : _delete(a),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Modifier')),
                        PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Ajout ou modification d'une adresse. Renvoie true via pop si elle a été enregistrée.
class SavedAddressFormScreen extends StatefulWidget {
  final SavedAddress? address;
  const SavedAddressFormScreen({super.key, this.address});

  @override
  State<SavedAddressFormScreen> createState() => _SavedAddressFormScreenState();
}

class _SavedAddressFormScreenState extends State<SavedAddressFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _address = TextEditingController(text: widget.address?.address ?? '');
  late final TextEditingController _customLabel = TextEditingController();
  late String _kind; // Maison, Bureau ou Autre
  double? _lat;
  double? _lng;
  bool _saving = false;

  bool get _isEdit => widget.address != null;

  @override
  void initState() {
    super.initState();
    final a = widget.address;
    final label = a?.label ?? _labelHome;
    if (label == _labelHome || label == _labelOffice) {
      _kind = label;
    } else {
      _kind = 'Autre';
      _customLabel.text = label;
    }
    _lat = a?.lat;
    _lng = a?.lng;
  }

  @override
  void dispose() {
    _address.dispose();
    _customLabel.dispose();
    super.dispose();
  }

  String get _label => _kind == 'Autre' ? _customLabel.text.trim() : _kind;

  /// Position depuis Google Maps (partage / lien), coordonnées, plus code ou GPS.
  Future<void> _importPosition() async {
    final loc = await showLocationImportSheet(context, initialLat: _lat, initialLng: _lng);
    if (loc == null || !mounted) return;
    _applyPosition(loc);
  }

  /// Ajustement fin sur la carte OpenStreetMap.
  Future<void> _pickPosition() async {
    final loc = await Navigator.push<LocationData>(
      context,
      MaterialPageRoute(builder: (_) => GpsPickerScreen(initialLat: _lat, initialLng: _lng)),
    );
    if (loc == null || !mounted) return;
    _applyPosition(loc);
  }

  void _applyPosition(LocationData loc) {
    setState(() {
      _lat = loc.lat;
      _lng = loc.lng;
      final found = loc.address?.trim() ?? '';
      if (_address.text.trim().isEmpty && found.isNotEmpty) _address.text = found;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final a = widget.address;
      if (a == null) {
        await createSavedAddress(label: _label, address: _address.text.trim(), lat: _lat, lng: _lng);
      } else {
        await updateSavedAddress(a.id, label: _label, address: _address.text.trim(), lat: _lat, lng: _lng);
      }
      if (!mounted) return;
      showMessage(context, _isEdit ? 'Adresse modifiée' : 'Adresse enregistrée');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasPosition = _lat != null && _lng != null;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Modifier l\'adresse' : 'Nouvelle adresse')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Nom de l\'adresse', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in const [_labelHome, _labelOffice, 'Autre'])
                  ChoiceChip(
                    avatar: Icon(_labelIcon(k), size: 18),
                    label: Text(k),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
              ],
            ),
            if (_kind == 'Autre') ...[
              const SizedBox(height: 14),
              TextFormField(
                controller: _customLabel,
                maxLength: 40,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Nom (ex. Chez maman)',
                  prefixIcon: Icon(Icons.label_rounded),
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Donnez un nom à cette adresse' : null,
              ),
            ],
            const SizedBox(height: 14),
            TextFormField(
              controller: _address,
              maxLines: 3,
              minLines: 2,
              maxLength: 300,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Adresse / indications',
                hintText: 'Quartier, rue, repère (ex. près de la pharmacie)',
                prefixIcon: Icon(Icons.location_on_rounded),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Adresse requise' : null,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          hasPosition ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
                          color: hasPosition ? AppColors.green : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            hasPosition
                                ? 'Position GPS enregistrée (${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)})'
                                : 'Position GPS (facultative) : elle aide le livreur à vous trouver.',
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: _importPosition,
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                      icon: const Icon(Icons.map_rounded),
                      label: Text(hasPosition ? 'Changer (Google Maps)' : 'Choisir dans Google Maps'),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _pickPosition,
                          icon: const Icon(Icons.edit_location_alt_rounded),
                          label: Text(hasPosition ? 'Ajuster sur la carte' : 'Choisir sur la carte'),
                        ),
                        if (hasPosition)
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: AppColors.darkRed),
                            onPressed: () => setState(() {
                              _lat = null;
                              _lng = null;
                            }),
                            child: const Text('Retirer'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
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
