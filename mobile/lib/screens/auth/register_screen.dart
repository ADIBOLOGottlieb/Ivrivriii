import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await context.read<AuthProvider>().register(
            name: _name.text.trim(),
            phone: _phone.text.trim(),
            password: _password.text,
            email: _email.text.trim().isEmpty ? null : _email.text.trim(),
            address: _address.text.trim().isEmpty ? null : _address.text.trim(),
          );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Créer un compte')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: AppLogo(size: 100)),
              const SizedBox(height: 12),
              const Text(
                'Bienvenue chez Ivrivrii Chicken 🐔',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: AppColors.muted),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nom complet *', prefixIcon: Icon(Icons.person_rounded)),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Entrez votre nom' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration:
                    const InputDecoration(labelText: 'Téléphone *', prefixIcon: Icon(Icons.phone_rounded)),
                validator: (v) =>
                    (v == null || v.trim().length < 8) ? 'Entrez un numéro valide' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration:
                    const InputDecoration(labelText: 'E-mail (optionnel)', prefixIcon: Icon(Icons.email_rounded)),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: 'Adresse de livraison (optionnel)',
                  hintText: 'Quartier, rue, repère (ex : Bè, Lomé)',
                  prefixIcon: Icon(Icons.location_on_rounded),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration:
                    const InputDecoration(labelText: 'Mot de passe *', prefixIcon: Icon(Icons.lock_rounded)),
                validator: (v) => (v == null || v.length < 6) ? '6 caractères minimum' : null,
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Text('Créer mon compte'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
