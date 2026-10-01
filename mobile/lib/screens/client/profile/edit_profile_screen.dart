import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models.dart';
import '../../../providers/auth_provider.dart';
import '../../../theme.dart';
import '../../../widgets/common.dart';
import 'change_password_screen.dart';

/// Modification des informations du compte (client ou administrateur).
/// Le mot de passe se change sur un écran à part ([ChangePasswordScreen]).
class EditProfileScreen extends StatefulWidget {
  final AppUser user;
  const EditProfileScreen({super.key, required this.user});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.name);
  late final _phone = TextEditingController(text: widget.user.phone);
  late final _email = TextEditingController(text: widget.user.email ?? '');
  late final _address = TextEditingController(text: widget.user.address ?? '');
  late final _momo = TextEditingController(text: widget.user.momoPhone ?? '');
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _momo]) {
      c.dispose();
    }
    super.dispose();
  }

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  // Même règle que le serveur : 8 à 16 chiffres/espaces, « + » initial facultatif.
  static final _phoneRe = RegExp(r'^\+?[\d\s]{8,16}$');

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      await context.read<AuthProvider>().updateProfile({
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        'address': _address.text.trim(),
        if (!widget.user.isAdmin) 'momo_phone': _momo.text.trim(),
      });
      if (!mounted) return;
      showMessage(context, 'Profil mis à jour');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mes informations')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nom complet', prefixIcon: Icon(Icons.person_rounded)),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Requis' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              enabled: false,
              decoration: const InputDecoration(
                labelText: 'Téléphone (identifiant de connexion)',
                prefixIcon: Icon(Icons.phone_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'E-mail (facultatif)', prefixIcon: Icon(Icons.email_rounded)),
              validator: (v) {
                final t = v?.trim() ?? '';
                return t.isEmpty || _emailRe.hasMatch(t) ? null : 'Adresse e-mail invalide';
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _address,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Adresse de livraison habituelle',
                prefixIcon: Icon(Icons.location_on_rounded),
              ),
            ),
            if (!widget.user.isAdmin) ...[
              const SizedBox(height: 14),
              TextFormField(
                controller: _momo,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Numéro mobile money préféré',
                  hintText: 'Ex. 90 12 34 56',
                  prefixIcon: Icon(Icons.account_balance_wallet_rounded),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  return t.isEmpty || _phoneRe.hasMatch(t) ? null : 'Numéro invalide';
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: Text(
                  'Pré-rempli lors d\'un paiement Flooz ou Mixx by Yas.',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Enregistrer'),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.red),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ChangePasswordScreen()),
              ),
              icon: const Icon(Icons.lock_reset_rounded),
              label: const Text('Changer mon mot de passe'),
            ),
          ],
        ),
      ),
    );
  }
}
