import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/cart_provider.dart';
import '../../../services/account_api.dart';
import '../../../theme.dart';
import '../../../widgets/common.dart';

/// Suppression du compte (exigée par Google Play). Le compte est anonymisé ;
/// l'historique des commandes est conservé pour la comptabilité du restaurant.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _understood = false;
  bool _obscure = true;
  bool _deleting = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final ok = await confirmDialog(
      context,
      'Supprimer définitivement ?',
      'Votre compte sera supprimé et vous serez déconnecté. Cette action est irréversible.',
      confirm: 'Supprimer',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await deleteAccount(_password.text);
      if (!mounted) return;
      final cart = context.read<CartProvider>();
      final auth = context.read<AuthProvider>();
      showMessage(context, 'Votre compte a été supprimé.');
      // On revient à la racine avant de déconnecter (sinon cet écran resterait affiché).
      Navigator.of(context).popUntil((r) => r.isFirst);
      cart.clear();
      await auth.logout();
    } catch (e) {
      if (mounted) {
        showMessage(context, e, error: true);
        setState(() => _deleting = false);
      }
    }
  }

  Widget _point(BuildContext context, IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Supprimer mon compte')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.darkRed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: AppColors.darkRed),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Cette action est définitive : vous ne pourrez plus vous connecter avec ce compte.',
                      style: TextStyle(color: cs.onSurface, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('Ce qui est supprimé', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            _point(context, Icons.delete_outline_rounded, AppColors.darkRed,
                'Vos informations personnelles : nom, e-mail, adresse, numéro mobile money préféré.'),
            _point(context, Icons.delete_outline_rounded, AppColors.darkRed,
                'Votre photo de profil et vos adresses enregistrées.'),
            _point(context, Icons.delete_outline_rounded, AppColors.darkRed,
                'Votre accès : le numéro de téléphone et le mot de passe ne permettront plus de se connecter.'),
            const SizedBox(height: 10),
            const Text('Ce qui est conservé', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            _point(context, Icons.receipt_long_rounded, cs.onSurfaceVariant,
                'L\'historique de vos commandes et paiements, rendu anonyme (« Compte supprimé »), '
                'car le restaurant doit le garder pour sa comptabilité.'),
            _point(context, Icons.info_outline_rounded, cs.onSurfaceVariant,
                'Une commande en cours n\'est pas annulée automatiquement : contactez le restaurant si besoin.'),
            const SizedBox(height: 16),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: 'Mot de passe',
                helperText: 'Pour confirmer qu\'il s\'agit bien de vous',
                prefixIcon: const Icon(Icons.lock_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Afficher' : 'Masquer',
                  icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => (v == null || v.isEmpty) ? 'Mot de passe requis' : null,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _understood,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => setState(() => _understood = v ?? false),
              title: const Text('Je comprends que la suppression de mon compte est définitive.'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppColors.darkRed, foregroundColor: Colors.white),
              onPressed: (_understood && !_deleting) ? _delete : null,
              icon: _deleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                    )
                  : const Icon(Icons.delete_forever_rounded),
              label: const Text('Supprimer mon compte'),
            ),
          ],
        ),
      ),
    );
  }
}
