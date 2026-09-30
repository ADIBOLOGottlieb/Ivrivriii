import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'gps_picker_screen.dart';

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
  bool _submitting = false;
  LocationData? _location;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    _address = TextEditingController(text: user?.address ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    // FIX: Add proper error handling for settings API call
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final s = await Api.instance.settings();
      if (mounted) {
        setState(() => _settings = s);
      }
    } catch (e) {
      // FIX: Show error to user instead of silently failing
      if (mounted) {
        showMessage(context, 'Impossible de charger les paramètres du restaurant. Certaines restrictions pourraient ne pas être appliquées.', error: true);
      }
      // Retry after 3 seconds
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) {
        _loadSettings(); // Retry
      }
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  int _getDeliveryFee() => _mode == 'delivery' ? (_settings?.deliveryFee ?? 0) : 0;

  int _getPaymentFee(CartProvider cart) {
    final settings = _settings;
    if (settings == null || _payment == 'cash') return 0;
    return paymentFeeFor(cart.subtotal + _getDeliveryFee(), _payment, settings.paymentFeePercent);
  }

  Future<void> _selectLocation() async {
    final loc = await Navigator.push<LocationData>(
      context,
      MaterialPageRoute(
        builder: (_) => GpsPickerScreen(initialLat: _location?.lat, initialLng: _location?.lng),
      ),
    );
    if (loc != null) setState(() => _location = loc);
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
      cart.clear();
      // Retient l'adresse pour la prochaine fois.
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (_mode == 'delivery' && (auth.user?.address ?? '').isEmpty) {
        auth.updateProfile({'address': _address.text.trim()}).catchError((_) {});
      }
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Text('🎉', style: TextStyle(fontSize: 48)),
          title: const Text('Commande envoyée !'),
          content: Text(
            'Votre commande n°${order.id} a bien été reçue. '
            (isMobileMoney(order.paymentMethod)
                ? 'Réglez-la maintenant par ${paymentLabel(order.paymentMethod)} pour que le restaurant la lance.'
                : 'Vous pouvez suivre sa préparation en temps réel.'),
            textAlign: TextAlign.center,
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(isMobileMoney(order.paymentMethod) ? 'Payer maintenant' : 'Suivre ma commande')),
          ],
        ),
      );
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
              const _Label('Adresse de livraison'),
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
              const _Label('Localisation GPS'),
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
                                ? '${_location!.lat.toStringAsFixed(4)}, ${_location!.lng.toStringAsFixed(4)}'
                                : 'Cliquer pour sélectionner votre position',
                            style: TextStyle(
                              color: _location != null ? AppColors.green : AppColors.muted,
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
                  'Après validation, vous serez redirigé vers la page de paiement sécurisée (KADEV PAY). '
                  "Des frais de ${formatPercent(_settings?.paymentFeePercent ?? 2)} % s'ajoutent au total.",
                  style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
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
                    if (_payment != 'cash' && paymentFee > 0) _TotalRow('Frais moyen paiement', paymentFee),
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
            onPressed: _submitting || cart.isEmpty || (_mode == 'delivery' && _location == null) ? null : _submit,
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
