import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../services/api.dart';
import '../../services/auth_api.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../client/profile/help_screen.dart' show dialNumber, openExternalLink, whatsappNumber;

/// « Mot de passe oublié » : numéro → code → nouveau mot de passe (connexion directe ensuite).
class ForgotPasswordScreen extends StatefulWidget {
  final String initialPhone;
  const ForgotPasswordScreen({super.key, this.initialPhone = ''});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _phoneForm = GlobalKey<FormState>();
  final _resetForm = GlobalKey<FormState>();
  late final _phone = TextEditingController(text: widget.initialPhone);
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  bool _codeStep = false;
  bool _bySms = false; // vrai : code reçu par SMS ; faux : le restaurant appelle le client
  AppSettings? _settings; // numéro du restaurant (mode sans SMS)

  @override
  void initState() {
    super.initState();
    Api.instance.settings().then((s) {
      if (mounted) setState(() => _settings = s);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    for (final c in [_phone, _code, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _requestCode() async {
    if (!_phoneForm.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    try {
      final sms = await forgotPassword(_phone.text.trim());
      if (!mounted) return;
      _code.clear();
      setState(() {
        _bySms = sms;
        _codeStep = true;
      });
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reset() async {
    if (!_resetForm.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final auth = context.read<AuthProvider>();
    setState(() => _loading = true);
    try {
      final (token, user) = await resetPassword(
        phone: _phone.text.trim(),
        code: _code.text.trim(),
        newPassword: _password.text,
      );
      await auth.applySession(token, user);
      if (!mounted) return;
      showMessage(context, 'Mot de passe modifié. Bienvenue !');
      Navigator.of(context).popUntil((r) => r.isFirst);
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
      canPop: !_codeStep,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _codeStep) setState(() => _codeStep = false);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Mot de passe oublié')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _codeStep ? _buildResetStep(cs) : _buildPhoneStep(cs),
        ),
      ),
    );
  }

  Widget _buildPhoneStep(ColorScheme cs) {
    return Form(
      key: _phoneForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_reset_rounded, size: 56, color: AppColors.red),
          const SizedBox(height: 12),
          Text(
            'Indiquez le numéro de téléphone de votre compte. Vous recevrez un code pour choisir '
            'un nouveau mot de passe.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _loading ? null : _requestCode(),
            decoration: const InputDecoration(labelText: 'Numéro de téléphone', prefixIcon: Icon(Icons.phone_rounded)),
            validator: (v) => (v == null || v.trim().length < 8) ? 'Entrez un numéro valide' : null,
          ),
          const SizedBox(height: 24),
          _button('Recevoir un code', _requestCode),
        ],
      ),
    );
  }

  Widget _buildResetStep(ColorScheme cs) {
    final phone = _phone.text.trim();
    final restaurant = _settings?.restaurantPhone.trim() ?? '';
    return Form(
      key: _resetForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_bySms ? Icons.sms_rounded : Icons.support_agent_rounded, color: AppColors.red, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _bySms
                        ? 'Un code à 6 chiffres a été envoyé par SMS au $phone (si un compte existe pour ce numéro). '
                            'Pas de SMS d\'ici quelques minutes ? Le restaurant vous appellera pour vous le donner.'
                        : 'Votre demande a été transmise au restaurant. Le restaurant va vous appeler au $phone '
                            '(ou vous écrire sur WhatsApp) pour vous communiquer le code à 6 chiffres. '
                            'Gardez votre téléphone à portée de main.',
                    style: TextStyle(color: cs.onSurface, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          if (!_bySms && restaurant.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openExternalLink(
                      context,
                      Uri(scheme: 'tel', path: dialNumber(restaurant)),
                      'Impossible de lancer l\'appel vers $restaurant',
                    ),
                    icon: const Icon(Icons.call_rounded),
                    label: const Text('Appeler'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openExternalLink(
                      context,
                      Uri.parse('https://wa.me/${whatsappNumber(restaurant)}'),
                      'Impossible d\'ouvrir WhatsApp',
                    ),
                    icon: const Icon(Icons.chat_rounded),
                    label: const Text('WhatsApp'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          TextFormField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Code à 6 chiffres',
              prefixIcon: Icon(Icons.pin_rounded),
              counterText: '',
            ),
            validator: (v) => (v == null || v.trim().length != 6) ? 'Entrez le code à 6 chiffres' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _password,
            obscureText: _obscure,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Nouveau mot de passe',
              prefixIcon: const Icon(Icons.lock_rounded),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Afficher' : 'Masquer',
                icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (v) => (v == null || v.length < 6) ? '6 caractères minimum' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _confirm,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _loading ? null : _reset(),
            decoration: const InputDecoration(labelText: 'Confirmer le mot de passe', prefixIcon: Icon(Icons.lock_rounded)),
            validator: (v) => v != _password.text ? 'Les mots de passe ne correspondent pas' : null,
          ),
          const SizedBox(height: 24),
          _button('Changer mon mot de passe', _reset),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading ? null : _requestAgain,
            child: const Text('Je n\'ai pas reçu de code : refaire une demande'),
          ),
          TextButton(
            onPressed: _loading ? null : () => setState(() => _codeStep = false),
            child: const Text('Modifier mon numéro'),
          ),
        ],
      ),
    );
  }

  /// Nouvelle demande depuis l'étape du code (le formulaire du numéro n'est plus affiché).
  Future<void> _requestAgain() async {
    setState(() => _loading = true);
    try {
      _bySms = await forgotPassword(_phone.text.trim());
      if (mounted) showMessage(context, _bySms ? 'Nouveau code envoyé' : 'Nouvelle demande transmise au restaurant');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
