import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../theme.dart';

/// Compte enregistré mais serveur injoignable (réseau coupé, serveur endormi) :
/// on garde la session et on réessaie, au lieu de renvoyer à l'écran de connexion.
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  static const _retryEvery = 10; // secondes

  Timer? _timer;
  int _countdown = _retryEvery;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    // En arrière-plan ou pendant un essai : on attend.
    final state = WidgetsBinding.instance.lifecycleState;
    final foreground = state == null || state == AppLifecycleState.resumed;
    if (!foreground || auth.retrying) return;
    if (_countdown <= 1) {
      _retry();
    } else {
      setState(() => _countdown--);
    }
  }

  Future<void> _retry() async {
    final auth = context.read<AuthProvider>();
    if (auth.retrying) return;
    setState(() => _countdown = _retryEvery);
    await auth.retryConnection();
    if (mounted) setState(() => _countdown = _retryEvery);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final retrying = auth.retrying;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.red.withValues(alpha: 0.12),
                  ),
                  child: const Icon(Icons.cloud_off_rounded, size: 48, color: AppColors.red),
                ),
                const SizedBox(height: 24),
                Text(
                  'Connexion au serveur impossible',
                  textAlign: TextAlign.center,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurface),
                ),
                const SizedBox(height: 12),
                Text(
                  'Vérifiez votre connexion Internet. Le serveur peut aussi mettre jusqu\'à une minute '
                  'à se réveiller. Votre compte reste connecté.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: retrying ? null : _retry,
                    icon: retrying
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.onSurfaceVariant),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: Text(retrying ? 'Connexion…' : 'Réessayer'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  retrying ? 'Connexion en cours…' : 'Nouvel essai automatique dans $_countdown s',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: retrying ? null : () => context.read<AuthProvider>().logout(),
                  child: const Text('Se déconnecter'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
