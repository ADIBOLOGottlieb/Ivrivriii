import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/api.dart';
import '../../services/auth_api.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../legal/legal_screen.dart';

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
  final _code = TextEditingController();
  late final TapGestureRecognizer _termsTap = TapGestureRecognizer()
    ..onTap = () => openLegalDoc(context, LegalDoc.terms);
  late final TapGestureRecognizer _privacyTap = TapGestureRecognizer()
    ..onTap = () => openLegalDoc(context, LegalDoc.privacy);
  bool _loading = false;
  bool _accepted = false;
  bool _otpRequired = false; // code SMS exigé (réglages du serveur)
  bool _codeStep = false; // étape « saisir le code reçu »

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final s = await Api.instance.settings();
      if (mounted) setState(() => _otpRequired = s.otpRequired);
    } catch (_) {
      // Sans réglages : le serveur signalera si un code est exigé.
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _email, _address, _password, _code]) {
      c.dispose();
    }
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  String? _opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _createAccount({String? otpToken}) async {
    final auth = context.read<AuthProvider>();
    final (token, user) = await registerAccount(
      name: _name.text.trim(),
      phone: _phone.text.trim(),
      password: _password.text,
      email: _opt(_email),
      address: _opt(_address),
      otpToken: otpToken,
    );
    await auth.applySession(token, user);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Étape 1 : formulaire. Avec code SMS exigé : envoie le code puis passe à l'étape 2.
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_accepted) {
      showMessage(context, 'Acceptez les conditions d\'utilisation pour créer votre compte', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      if (_otpRequired) {
        await requestOtp(_phone.text.trim());
        if (!mounted) return;
        _code.clear();
        setState(() => _codeStep = true);
        showMessage(context, 'Code envoyé par SMS au ${_phone.text.trim()}');
      } else {
        await _createAccount();
      }
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Étape 2 : vérifie le code puis crée le compte.
  Future<void> _verifyAndCreate() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      showMessage(context, 'Entrez le code à 6 chiffres', error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final otpToken = await verifyOtp(_phone.text.trim(), code);
      await _createAccount(otpToken: otpToken);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    setState(() => _loading = true);
    try {
      await requestOtp(_phone.text.trim());
      if (mounted) showMessage(context, 'Nouveau code envoyé');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _button(String label, VoidCallback onPressed) => FilledButton(
        onPressed: _loading ? null : onPressed,
        child: _loading
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
            : Text(label),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      // Retour pendant l'étape du code : revient au formulaire.
      canPop: !_codeStep,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _codeStep) setState(() => _codeStep = false);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_codeStep ? 'Vérification du numéro' : 'Créer un compte')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _codeStep ? _buildCodeStep(cs) : _buildForm(cs),
        ),
      ),
    );
  }

  Widget _buildCodeStep(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.sms_rounded, size: 56, color: AppColors.red),
        const SizedBox(height: 12),
        Text(
          'Entrez le code à 6 chiffres envoyé par SMS au ${_phone.text.trim()}.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 8),
          decoration: const InputDecoration(labelText: 'Code reçu', counterText: ''),
          onSubmitted: (_) => _loading ? null : _verifyAndCreate(),
        ),
        const SizedBox(height: 20),
        _button('Valider et créer mon compte', _verifyAndCreate),
        const SizedBox(height: 8),
        TextButton(onPressed: _loading ? null : _resend, child: const Text('Renvoyer le code')),
        TextButton(
          onPressed: _loading ? null : () => setState(() => _codeStep = false),
          child: const Text('Modifier mon numéro'),
        ),
      ],
    );
  }

  Widget _buildForm(ColorScheme cs) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: AppLogo(size: 100)),
          const SizedBox(height: 12),
          Text(
            'Bienvenue chez Ivrivrii Chicken 🐔',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant),
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
            decoration: const InputDecoration(labelText: 'Téléphone *', prefixIcon: Icon(Icons.phone_rounded)),
            validator: (v) => (v == null || v.trim().length < 8) ? 'Entrez un numéro valide' : null,
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
            decoration: const InputDecoration(labelText: 'Mot de passe *', prefixIcon: Icon(Icons.lock_rounded)),
            validator: (v) => (v == null || v.length < 6) ? '6 caractères minimum' : null,
          ),
          const SizedBox(height: 16),
          // Acceptation obligatoire des conditions (liens vers les documents).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: _accepted,
                activeColor: AppColors.red,
                onChanged: (v) => setState(() => _accepted = v ?? false),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text.rich(
                    TextSpan(
                      style: TextStyle(color: cs.onSurface, height: 1.35),
                      children: [
                        const TextSpan(text: 'J\'accepte les '),
                        TextSpan(
                          text: 'conditions d\'utilisation',
                          recognizer: _termsTap,
                          style: const TextStyle(
                              color: AppColors.red, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                        ),
                        const TextSpan(text: ' et la '),
                        TextSpan(
                          text: 'politique de confidentialité',
                          recognizer: _privacyTap,
                          style: const TextStyle(
                              color: AppColors.red, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                        ),
                        const TextSpan(text: '.'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_otpRequired) ...[
            const SizedBox(height: 8),
            Text(
              'Un code de vérification vous sera envoyé par SMS.',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 20),
          _button(_otpRequired ? 'Recevoir mon code' : 'Créer mon compte', _submit),
        ],
      ),
    );
  }
}
