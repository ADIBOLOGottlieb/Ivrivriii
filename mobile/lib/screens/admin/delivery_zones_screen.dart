import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../services/admin_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../client/gps_picker_screen.dart';
import 'admin_layout.dart';

/// Zones de livraison (gérant) : quartiers avec un prix, dans l'ordre proposé au client.
/// Une zone peut être reconnue automatiquement par la position du client (cercle centre + rayon).
class DeliveryZonesScreen extends StatefulWidget {
  /// Position du restaurant : point de départ de la carte pour placer le centre d'une zone.
  final double? restaurantLat;
  final double? restaurantLng;

  const DeliveryZonesScreen({super.key, this.restaurantLat, this.restaurantLng});

  @override
  State<DeliveryZonesScreen> createState() => _DeliveryZonesScreenState();
}

class _DeliveryZonesScreenState extends State<DeliveryZonesScreen> {
  List<DeliveryZone>? _zones;
  Object? _error;
  bool _reordering = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final zones = await fetchDeliveryZones();
      if (!mounted) return;
      setState(() {
        _zones = zones;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _edit([DeliveryZone? zone]) async {
    final zones = _zones ?? const <DeliveryZone>[];
    final nextPosition = zones.isEmpty ? 0 : zones.map((z) => z.position).reduce((a, b) => a > b ? a : b) + 1;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _ZoneFormScreen(
          zone: zone,
          newPosition: nextPosition,
          restaurantLat: widget.restaurantLat,
          restaurantLng: widget.restaurantLng,
        ),
      ),
    );
    if (changed == true) _load();
  }

  /// Déplace une zone puis enregistre le nouvel ordre (affichage immédiat, rechargé en cas d'erreur).
  Future<void> _move(int from, int to) async {
    final zones = _zones;
    if (zones == null || from == to || to < 0 || to >= zones.length || _reordering) return;
    final list = [...zones];
    list.insert(to, list.removeAt(from));
    setState(() {
      _zones = list;
      _reordering = true;
    });
    try {
      await reorderDeliveryZones(list);
      await _load();
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
      await _load();
    } finally {
      if (mounted) setState(() => _reordering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<AuthProvider>().user?.isManager ?? false;
    if (!manager) {
      return Scaffold(
        appBar: AppBar(title: const Text('Zones de livraison')),
        body: const EmptyState(emoji: '🔒', title: 'Réservé au gérant'),
      );
    }
    final zones = _zones;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zones de livraison'),
        bottom: _reordering
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      floatingActionButton: zones == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add_location_alt_rounded),
              label: const Text('Ajouter une zone'),
            ),
      body: zones == null
          ? (_error != null
                ? ErrorRetry(error: _error!, onRetry: _load)
                : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: _load,
              child: zones.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 60),
                        EmptyState(
                          emoji: '🗺️',
                          title: 'Aucune zone',
                          message:
                              'Ajoutez vos quartiers de livraison avec leur prix. '
                              'Le client choisira sa zone au moment de commander.',
                        ),
                      ],
                    )
                  : MaxContentWidth(
                      maxWidth: 760,
                      child: ReorderableListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                        header: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Ordre proposé au client. Maintenez une zone pour la déplacer, ou utilisez les flèches.',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                          ),
                        ),
                        itemCount: zones.length,
                        buildDefaultDragHandles: false,
                        onReorderItem: _move,
                        itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
                          key: ValueKey(zones[i].id),
                          index: i,
                          child: FadeSlideIn(
                            delay: FadeSlideIn.stagger(i),
                            child: _ZoneTile(
                              zone: zones[i],
                              onTap: () => _edit(zones[i]),
                              onUp: i == 0 || _reordering ? null : () => _move(i, i - 1),
                              onDown: i == zones.length - 1 || _reordering ? null : () => _move(i, i + 1),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
    );
  }
}

class _ZoneTile extends StatelessWidget {
  final DeliveryZone zone;
  final VoidCallback onTap;
  final VoidCallback? onUp;
  final VoidCallback? onDown;

  const _ZoneTile({required this.zone, required this.onTap, this.onUp, this.onDown});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final green = dark ? AppColors.darkTertiary : AppColors.green;
    Widget pill(String text, Color color, IconData icon) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              Icon(Icons.drag_indicator_rounded, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zone.name,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: zone.active ? scheme.onSurface : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatPrice(zone.fee),
                      style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        zone.active
                            ? pill('Active', green, Icons.check_circle_rounded)
                            : pill('Inactive', scheme.onSurfaceVariant, Icons.pause_circle_outline_rounded),
                        if (zone.hasArea)
                          pill(
                            'Reconnue automatiquement · ${formatPercent(zone.radiusKm!)} km',
                            dark ? scheme.primary : AppColors.red,
                            Icons.my_location_rounded,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Monter',
                    visualDensity: VisualDensity.compact,
                    onPressed: onUp,
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  ),
                  IconButton(
                    tooltip: 'Descendre',
                    visualDensity: VisualDensity.compact,
                    onPressed: onDown,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ajout ou modification d'une zone. Renvoie `true` via Navigator.pop si quelque chose a changé.
class _ZoneFormScreen extends StatefulWidget {
  final DeliveryZone? zone;
  final int newPosition;
  final double? restaurantLat;
  final double? restaurantLng;

  const _ZoneFormScreen({this.zone, required this.newPosition, this.restaurantLat, this.restaurantLng});

  @override
  State<_ZoneFormScreen> createState() => _ZoneFormScreenState();
}

class _ZoneFormScreenState extends State<_ZoneFormScreen> {
  static const _minRadius = 0.3;
  static const _maxRadius = 10.0;

  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.zone?.name ?? '');
  late final _fee = TextEditingController(text: widget.zone == null ? '' : '${widget.zone!.fee}');
  late bool _active = widget.zone?.active ?? true;
  late bool _useArea = widget.zone?.hasArea ?? false;
  late double? _lat = widget.zone?.centerLat;
  late double? _lng = widget.zone?.centerLng;
  late double _radius = (widget.zone?.radiusKm ?? 1.5).clamp(_minRadius, _maxRadius).toDouble();
  String? _centerAddress;
  bool _saving = false;

  bool get _editing => widget.zone != null;

  @override
  void dispose() {
    _name.dispose();
    _fee.dispose();
    super.dispose();
  }

  Future<void> _pickCenter() async {
    final loc = await Navigator.push<LocationData>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GpsPickerScreen(initialLat: _lat ?? widget.restaurantLat, initialLng: _lng ?? widget.restaurantLng),
      ),
    );
    if (loc == null || !mounted) return;
    setState(() {
      _lat = loc.lat;
      _lng = loc.lng;
      final a = loc.address?.trim() ?? '';
      _centerAddress = a.isEmpty ? null : a;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_useArea && (_lat == null || _lng == null)) {
      showMessage(
        context,
        'Placez le centre de la zone sur la carte, ou désactivez la reconnaissance automatique.',
        error: true,
      );
      return;
    }
    final area = _useArea && _lat != null && _lng != null;
    final zone = DeliveryZone(
      id: widget.zone?.id ?? 0,
      name: _name.text.trim(),
      fee: int.parse(_fee.text.trim()),
      active: _active,
      position: widget.zone?.position ?? widget.newPosition,
      centerLat: area ? _lat : null,
      centerLng: area ? _lng : null,
      radiusKm: area ? double.parse(_radius.toStringAsFixed(1)) : null,
    );
    setState(() => _saving = true);
    try {
      if (_editing) {
        await updateDeliveryZone(zone.id, zone);
      } else {
        await createDeliveryZone(zone);
      }
      if (!mounted) return;
      showMessage(context, _editing ? 'Zone enregistrée' : 'Zone ajoutée');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final zone = widget.zone;
    if (zone == null) return;
    final ok = await confirmDialog(
      context,
      'Supprimer la zone ?',
      '« ${zone.name} » ne sera plus proposée aux clients. '
          'Si des commandes l\'utilisent déjà, elle sera seulement désactivée.',
      confirm: 'Supprimer',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await deleteDeliveryZone(zone.id);
      if (!mounted) return;
      showMessage(context, 'Zone supprimée');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hasCenter = _lat != null && _lng != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Modifier la zone' : 'Nouvelle zone'),
        actions: [
          if (_editing)
            IconButton(
              tooltip: 'Supprimer',
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: MaxContentWidth(
          maxWidth: 640,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Nom de la zone', hintText: 'Ex. Bè, Tokoin, Agoè...'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Nom obligatoire' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _fee,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Frais de livraison', suffixText: 'FCFA'),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  return n == null || n < 0 || n > 100000 ? 'Entre 0 et 100 000' : null;
                },
              ),
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile(
                  value: _active,
                  activeTrackColor: AppColors.green,
                  onChanged: (v) => setState(() => _active = v),
                  title: const Text('Active', style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(_active ? 'Proposée aux clients' : 'Masquée pour les clients'),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Zone sur la carte (facultatif)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text(
                'Avec un cercle, la zone est reconnue automatiquement à partir de la position du client. '
                'Sans cercle, le client la choisit dans la liste.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Card(
                child: SwitchListTile(
                  value: _useArea,
                  activeTrackColor: AppColors.green,
                  onChanged: (v) => setState(() => _useArea = v),
                  title: const Text('Reconnaître automatiquement', style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: const Text('Centre + rayon'),
                ),
              ),
              if (_useArea) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: hasCenter ? scheme.surfaceContainerHighest : AppColors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: hasCenter ? null : Border.all(color: AppColors.red.withValues(alpha: 0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            hasCenter ? Icons.place : Icons.location_off_outlined,
                            color: hasCenter ? (dark ? AppColors.darkTertiary : AppColors.green) : AppColors.red,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Centre de la zone',
                                  style: TextStyle(fontWeight: FontWeight.w900, color: scheme.onSurface),
                                ),
                                const SizedBox(height: 4),
                                if (!hasCenter)
                                  Text('Non placé', style: TextStyle(color: scheme.onSurfaceVariant))
                                else ...[
                                  if (_centerAddress != null)
                                    Text(_centerAddress!, style: TextStyle(color: scheme.onSurface)),
                                  Text(
                                    '${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}',
                                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton.icon(
                          onPressed: _saving ? null : _pickCenter,
                          icon: const Icon(Icons.map_outlined),
                          label: Text(hasCenter ? 'Déplacer sur la carte' : 'Placer sur la carte'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            'Rayon',
                            style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface),
                          ),
                          const Spacer(),
                          Text(
                            '${formatPercent(double.parse(_radius.toStringAsFixed(1)))} km',
                            style: TextStyle(fontWeight: FontWeight.w900, color: scheme.onSurface),
                          ),
                        ],
                      ),
                      Slider(
                        value: _radius,
                        min: _minRadius,
                        max: _maxRadius,
                        divisions: 97, // pas de 0,1 km
                        label: '${formatPercent(double.parse(_radius.toStringAsFixed(1)))} km',
                        onChanged: (v) => setState(() => _radius = v),
                      ),
                      Text(
                        'Si plusieurs cercles contiennent la position du client, le plus petit l\'emporte.',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : Text(_editing ? 'Enregistrer' : 'Ajouter la zone'),
              ),
              if (_editing) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: dark ? scheme.error : AppColors.darkRed),
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Supprimer la zone'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
