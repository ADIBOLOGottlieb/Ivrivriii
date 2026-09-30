import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Finalisation de la commande. Renvoie la [Order] créée via `Navigator.pop`.
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

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    _address = TextEditingController(text: user?.address ?? '');
    _phone = TextEditingController(text: user?.phone ?? '');
    Api.instance.settings().then((s) {
      if (mounted) setState(() => _settings = s);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _address.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _deliveryFee => _mode == 'delivery' ? (_settings?.deliveryFee ?? 0) : 0;

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

    setState(() => _submitting = true);
    try {
      final order = await Api.instance.createOrder({
        'items': cart.toOrderItems(),
        'mode': _mode,
        'address': _mode == 'delivery' ? _address.text.trim() : null,
        'phone': _phone.text.trim(),
        'note': _note.text.trim(),
        'payment_method': _payment,
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
            'Vous pouvez suivre sa préparation en temps réel.',
            textAlign: TextAlign.center,
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Suivre ma commande')),
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
                backgroundColor: Colors.white,
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
              const Padding(
                padding: EdgeInsets.only(top: 8, left: 4),
                child: Text(
                  'Le restaurant vous contactera pour confirmer le paiement mobile.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
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
                    if (_mode == 'delivery') _TotalRow('Livraison', _deliveryFee),
                    const SizedBox(height: 6),
                    _TotalRow('Total', cart.subtotal + _deliveryFee, bold: true),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 100),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: SafeArea(
          top: false,
          child: FilledButton(
            onPressed: _submitting || cart.isEmpty ? null : _submit,
            child: _submitting
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text('Commander • ${formatPrice(cart.subtotal + _deliveryFee)}'),
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
      color: bold ? AppColors.red : AppColors.ink,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [Text(label, style: style), const Spacer(), Text(formatPrice(amount), style: style)]),
    );
  }
}
