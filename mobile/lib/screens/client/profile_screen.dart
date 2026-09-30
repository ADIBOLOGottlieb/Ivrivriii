import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    if (user == null) return const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: const Text('Mon profil')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: AppColors.red,
                    child: Text(
                      user.name.isEmpty ? '?' : user.name[0].toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                        Text(user.phone, style: const TextStyle(color: AppColors.muted)),
                        if (user.email != null) Text(user.email!, style: const TextStyle(color: AppColors.muted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_rounded, color: AppColors.red),
                  title: const Text('Modifier mes informations'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => EditProfileScreen(user: user)),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.location_on_rounded, color: AppColors.red),
                  title: const Text('Adresse de livraison'),
                  subtitle: Text(user.address ?? 'Non renseignée'),
                ),
                const _RestaurantContact(),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.darkRed),
            onPressed: () async {
              if (await confirmDialog(context, 'Déconnexion', 'Voulez-vous vous déconnecter ?',
                  confirm: 'Se déconnecter')) {
                if (!context.mounted) return;
                context.read<CartProvider>().clear();
                context.read<AuthProvider>().logout();
              }
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Se déconnecter'),
          ),
          const SizedBox(height: 24),
          const Center(child: AppLogo(size: 70)),
          const SizedBox(height: 8),
          const Center(
            child: Text('Ivrivrii Chicken • v1.0.0', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _RestaurantContact extends StatelessWidget {
  const _RestaurantContact();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppSettings>(
      future: Api.instance.settings(),
      builder: (context, snap) {
        final s = snap.data;
        if (s == null) return const SizedBox.shrink();
        return ListTile(
          leading: const Icon(Icons.support_agent_rounded, color: AppColors.red),
          title: const Text('Appeler le restaurant'),
          subtitle: Text('${s.restaurantPhone}\n${s.restaurantAddress}'),
          isThreeLine: true,
          onTap: () => launchUrl(Uri(scheme: 'tel', path: s.restaurantPhone.replaceAll(' ', ''))),
        );
      },
    );
  }
}

class EditProfileScreen extends StatefulWidget {
  final AppUser user;
  const EditProfileScreen({super.key, required this.user});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.name);
  late final _email = TextEditingController(text: widget.user.email ?? '');
  late final _address = TextEditingController(text: widget.user.address ?? '');
  final _password = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _email, _address, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<AuthProvider>().updateProfile({
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        'address': _address.text.trim(),
        if (_password.text.isNotEmpty) 'password': _password.text,
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
    return Scaffold(
      appBar: AppBar(title: const Text('Mes informations')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nom complet', prefixIcon: Icon(Icons.person_rounded)),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Requis' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              initialValue: widget.user.phone,
              enabled: false,
              decoration: const InputDecoration(labelText: 'Téléphone', prefixIcon: Icon(Icons.phone_rounded)),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'E-mail', prefixIcon: Icon(Icons.email_rounded)),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _address,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Adresse de livraison',
                prefixIcon: Icon(Icons.location_on_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Nouveau mot de passe (optionnel)',
                prefixIcon: Icon(Icons.lock_rounded),
              ),
              validator: (v) => (v != null && v.isNotEmpty && v.length < 6) ? '6 caractères minimum' : null,
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
