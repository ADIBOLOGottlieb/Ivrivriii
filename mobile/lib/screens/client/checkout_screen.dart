import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/api.dart';
import '../../services/maps_link.dart';
import '../../services/order_events.dart';
import '../../services/shared_location.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'gps_picker_screen.dart';
import 'location_import_sheet.dart';
import 'profile/saved_addresses_screen.dart';

/// Finalisation de la commande. Retourne la [Order] créée via `Navigator.pop`.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _address;
  late final TextEditingController _phone;
  final _note = TextEditingController();
  String _mode = 'delivery';
  String _payment = 'cash';
  AppSettings? _settings;
  bool _settingsFailed = false; // 3 essais sans succès : bouton « Réessayer »
  bool _submitting = false;
  LocationData? _location;
  // Dernière adresse remplie automatiquement (profil, GPS, « Mes adresses »).
  String? _prefilledAddress;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    _prefilledAddress = user?.address;
    _address = TextEditingController(text: user?.address ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    _loadSettings();
    // Position partagée depuis Google Maps (avant ou pendant l'ouverture de cet écran).
    SharedLocationService.instance.pending.addListener(_onSharedLocation);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSharedLocation());
  }

  /// Réglages à jour (ouverture, minimum, frais) : 3 essais espacés, puis bouton « Réessayer ».
  Future<void> _loadSettings() async {
    if (_settingsFailed) setState(() => _settingsFailed = false);
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final s = await Api.instance.settings(fresh: true);
        if (mounted) setState(() => _settings = s);
        return;
      } catch (_) {
        if (!mounted) return;
        if (attempt < 3) await Future.delayed(Duration(seconds: 2 * attempt));
        if (!mounted) return;
      }
    }
    setState(() => _settingsFailed = true);
  }

  @override
  void dispose() {
    SharedLocationService.instance.pending.removeListener(_onSharedLocation);
    _address.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  int _getDeliveryFee() => _mode == 'delivery' ? (_settings?.deliveryFee ?? 0) : 0;

  int _getPaymentFee(CartProvider cart) {
    final settings = _settings;
    if (settings == null || _payment == 'cash') return 0;
    return paymentFeeFor(cart.subtotal + _getDeliveryFee(), _payment, settings.feePercentFor(_payment));
  }

  /// Taux des frais du moyen sélectionné (commission de l'agrégateur pour cet opérateur).
  double _feePercent() => _settings?.feePercentFor(_payment) ?? 2;

  /// Remplit le champ adresse sans écraser ce que le client a tapé lui-même :
  /// seulement s'il est vide ou s'il contient encore l'adresse pré-remplie précédente.
  void _prefillAddress(String? address) {
    final a = address?.trim() ?? '';
    if (a.isEmpty) return;
    final current = _address.text.trim();
    if (current.isEmpty || current == (_prefilledAddress ?? '').trim()) {
      _address.text = a;
      _prefilledAddress = a;
    }
  }

  /// Choix de la position : Google Maps (partage / lien), coordonnées, plus code ou GPS.
  Future<void> _selectLocation() async {
    final loc = await showLocationImportSheet(context, initialLat: _location?.lat, initialLng: _location?.lng);
    if (loc == null || !mounted) return;
    setState(() {
      _location = loc;
      _prefillAddress(loc.address);
    });
  }

  /// Une position partagée depuis Google Maps est arrivée : on l'utilise directement,
  /// sauf si la feuille « Choisir ma position » est ouverte (elle s'en charge).
  void _onSharedLocation() {
    final service = SharedLocationService.instance;
    if (!mounted || service.pending.value == null || isLocationImportSheetOpen) return;
    final imported = service.consume();
    if (imported != null) _useImported(imported);
  }

  Future<void> _useImported(ImportedLocation imported) async {
    setState(() {
      _mode = 'delivery';
      _location = LocationData(lat: imported.lat, lng: imported.lng, address: importedAddressText(imported));
      _prefillAddress(_location!.address);
    });
    showMessage(context, 'Position reçue de Google Maps ✅');
    if ((imported.address?.trim() ?? '').isNotEmpty) return;
    // Pas d'adresse partagée : on la cherche (OpenStreetMap) pour pré-remplir le champ.
    final address = await resolveImportedAddress(imported);
    final current = _location;
    if (!mounted || address == null || current == null) return;
    if (current.lat != imported.lat || current.lng != imported.lng) return;
    setState(() {
      _location = LocationData(lat: current.lat, lng: current.lng, address: address);
      _prefillAddress(address);
    });
  }

  /// « Mes adresses » : remplit l'adresse et, si elle en a une, la position GPS.
  Future<void> _pickSavedAddress() async {
    final a = await showSavedAddressPicker(context);
    if (a == null || !mounted) return;
    setState(() {
      _address.text = a.address;
      _prefilledAddress = a.address;
      if (a.lat != null && a.lng != null) {
        _location = LocationData(lat: a.lat!, lng: a.lng!, address: a.address);
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final cart = context.read<CartProvider>();
    final settings = _settings;
    if (settings != null && !settings.isOpen) {
      showMessage(context, 'Le restaurant est fermé pour le moment', error: true);
      return;
    }
    if (settings != null && cart.subtotal < settings.minOrder) {
      showMessage(context, 'Commande minimum : ${formatPrice(settings.minOrder)}', error: true);
      return;
    }
    if (_mode == 'delivery' && _location == null) {
      showMessage(context, 'Veuillez sélectionner votre localisation', error: true);
      return;
    }

    setState(() => _submitting = true);
    try {
      final order = await Api.instance.createOrder({
        'items': cart.toOrderItems(),
        'mode': _mode,
        'address': _mode == 'delivery' ? _address.text.trim() : null,
        'phone': _phone.text.trim(),
        'note': _note.text.trim(),
        'payment_method': _payment,
        'location': _mode == 'delivery' ? _location?.toJson() : null,
      });
      notifyOrdersChanged();
      // Panier vidé seulement après la boîte de confirmation (sinon récapitulatif vide derrière).
      if (!mounted) {
        cart.clear();
        return;
      }
      // Retient l'adresse pour la prochaine fois.
      final auth = context.read<AuthProvider>();
      if (_mode == 'delivery' && (auth.user?.address ?? '').isEmpty) {
        auth.updateProfile({'address': _address.text.trim()}).catchError((_) {});
      }
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Text('🎉', style: TextStyle(fontSize: 48)),
          title: const Text('Commande envoyée !'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Votre commande n°${order.id} a bien été reçue. ${isMobileMoney(order.paymentMethod) ? 'Réglez-la maintenant par ${paymentLabel(order.paymentMethod)} pour que le restaurant la lance.' : 'Vous pouvez suivre sa préparation en temps réel.'}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Montant officiel renvoyé par le serveur.
              Text(
                'Total : ${formatPrice(order.total)}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: AppColors.red),
              ),
            ],
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(isMobileMoney(order.paymentMethod) ? 'Payer maintenant' : 'Suivre ma commande')),
          ],
        ),
      );
      cart.clear();
      if (mounted) Navigator.pop(context, order);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();
    final deliveryFee = _getDeliveryFee();
    final paymentFee = _getPaymentFee(cart);
    return Scaffold(
      appBar: AppBar(title: const Text('Finaliser la commande')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (_settingsFailed) ...[
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.cloud_off_rounded, color: Theme.of(context).colorScheme.onErrorContainer),
                  title: Text(
                    'Impossible de charger les informations du restaurant (horaires, frais).',
                    style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                  trailing: TextButton(onPressed: _loadSettings, child: const Text('Réessayer')),
                ),
              ),
              const SizedBox(height: 16),
            ],
            const _Label('Mode de retrait'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'delivery', label: Text('Livraison'), icon: Icon(Icons.delivery_dining_rounded)),
                ButtonSegment(value: 'pickup', label: Text('À emporter'), icon: Icon(Icons.storefront_rounded)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: AppColors.red,
                selectedForegroundColor: Colors.white,
                backgroundColor: Theme.of(context).colorScheme.surface,
              ),
            ),
            const SizedBox(height: 20),
            if (_mode == 'delivery') ...[
              Row(
                children: [
                  const Expanded(child: _Label('Adresse de livraison')),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextButton.icon(
                      onPressed: _pickSavedAddress,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.bookmark_rounded, size: 18),
                      label: const Text('Mes adresses'),
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: _address,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: 'Quartier, rue, point de repère (ex : Tokoin, Bè...)',
                  prefixIcon: Icon(Icons.location_on_rounded),
                ),
                validator: (v) =>
                    _mode == 'delivery' && (v == null || v.trim().isEmpty) ? 'Indiquez votre adresse' : null,
              ),
              const SizedBox(height: 14),
              const _Label('Localisation'),
              FilledButton(
                onPressed: _selectLocation,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(_location == null
                    ? '📍 Choisir ma position dans Google Maps'
                    : '📍 Changer ma position (Google Maps)'),
              ),
              const SizedBox(height: 10),
              Material(
                color: _location != null
                    ? AppColors.green.withValues(alpha: 0.12)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: _selectLocation,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.map_rounded, color: _location != null ? Colors.green : AppColors.red),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _location != null
                                ? [
                                    if ((_location!.address ?? '').trim().isNotEmpty) _location!.address!.trim(),
                                    '${_location!.lat.toStringAsFixed(4)}, ${_location!.lng.toStringAsFixed(4)}',
                                  ].join('\n')
                                : 'Aucune position choisie : le livreur en a besoin pour vous trouver.',
                            style: TextStyle(
                              color: _location != null ? AppColors.green : Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: _location != null ? 13 : 14,
                              fontWeight: _location != null ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                        Icon(Icons.arrow_forward_rounded, color: _location != null ? Colors.green : AppColors.red, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ] else if (_settings != null) ...[
              Card(
                child: ListTile(
                  leading: const Icon(Icons.storefront_rounded, color: AppColors.red),
                  title: const Text('À récupérer au restaurant'),
                  subtitle: Text(_settings!.restaurantAddress),
                ),
              ),
              const SizedBox(height: 16),
            ],
            const _Label('Téléphone de contact'),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.phone_rounded)),
              validator: (v) => (v == null || v.trim().length < 8) ? 'Numéro invalide' : null,
            ),
            const SizedBox(height: 16),
            const _Label('Note pour la cuisine (optionnel)'),
            TextFormField(
              controller: _note,
              maxLines: 2,
              decoration: const InputDecoration(hintText: 'Ex : sans piment, bien cuit...'),
            ),
            const SizedBox(height: 20),
            const _Label('Paiement'),
            Card(
              child: RadioGroup<String>(
                groupValue: _payment,
                onChanged: (v) => setState(() => _payment = v!),
                child: Column(
                  children: [
                    for (final e in paymentMethods.entries)
                      RadioListTile<String>(
                        value: e.key,
                        title: Text(e.key == 'cash' && _mode == 'pickup' ? 'Espèces au retrait' : e.value),
                        subtitle: isMobileMoney(e.key) && _settings != null
                            ? Text('Frais ${formatPercent(_settings!.feePercentFor(e.key))} %')
                            : null,
                        secondary: Icon(paymentIcon(e.key), color: AppColors.red),
                      ),
                  ],
                ),
              ),
            ),
            if (_payment != 'cash')
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4),
                child: Text(
                  '${_settings?.paymentProvider == 'kadev' ? 'Après validation, vous serez redirigé vers la page de paiement sécurisée (KADEV PAY). ' : 'Après validation, vous recevrez une demande de paiement sur votre téléphone : confirmez-la avec votre code PIN. '}'
                  "Des frais de ${formatPercent(_feePercent())} % (commission ${paymentLabel(_payment).split(' ').first}) s'ajoutent au total.",
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12.5),
                ),
              ),
            const SizedBox(height: 20),
            const _Label('Récapitulatif'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    for (final l in cart.lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Text('${l.quantity}×', style: const TextStyle(fontWeight: FontWeight.w800)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(l.product.name)),
                            Text(formatPrice(l.total)),
                          ],
                        ),
                      ),
                    const Divider(height: 20),
                    _TotalRow('Sous-total', cart.subtotal),
                    if (_mode == 'delivery') _TotalRow('Livraison', deliveryFee),
                    if (_payment != 'cash' && paymentFee > 0)
                      _TotalRow('Frais ${paymentLabel(_payment).split(' ').first} (${formatPercent(_feePercent())} %)', paymentFee),
                    const SizedBox(height: 6),
                    _TotalRow('Total', cart.subtotal + deliveryFee + (_payment != 'cash' ? paymentFee : 0), bold: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: SafeArea(
          top: false,
          child: FilledButton(
            // Sans les réglages, les frais affichés seraient faux : on attend leur chargement.
            onPressed: _submitting || _settings == null || cart.isEmpty || (_mode == 'delivery' && _location == null)
                ? null
                : _submit,
            child: _submitting
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text('Commander • ${formatPrice(cart.subtotal + deliveryFee + (_payment != 'cash' ? paymentFee : 0))}'),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      );
}

class _TotalRow extends StatelessWidget {
  final String label;
  final int amount;
  final bool bold;
  const _TotalRow(this.label, this.amount, {this.bold = false});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w900 : FontWeight.w500,
      fontSize: bold ? 17 : 14,
      color: bold ? AppColors.red : Theme.of(context).colorScheme.onSurface,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [Text(label, style: style), const Spacer(), Text(formatPrice(amount), style: style)]),
    );
  }
}
