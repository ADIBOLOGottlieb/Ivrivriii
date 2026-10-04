import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../services/api.dart';
import '../../services/order_events.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'order_estimate.dart' show formatKm;

enum _Step { input, waiting, result }

/// Paiement mobile money par push USSD : l'application envoie la demande, le client
/// confirme en tapant son code PIN SUR SON TÉLÉPHONE (jamais dans l'application).
/// Renvoie l'[Order] à jour via `Navigator.pop`.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.order});
  final Order order;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> with SingleTickerProviderStateMixin {
  static const _pollEvery = Duration(seconds: 3);
  static const _defaultWait = Duration(minutes: 2);
  static const _graceSeconds = 20; // on attend encore un peu la réponse du serveur après le délai

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _phone;
  late final AnimationController _pulse;
  late Order _order;
  PaymentAttempt? _payment;
  _Step _step = _Step.input;
  bool _busy = false;
  bool _polling = false;
  Timer? _pollTimer;
  Timer? _tickTimer;
  DateTime _deadline = DateTime.now();
  Duration _waitTotal = _defaultWait;
  Duration _remaining = _defaultWait;
  String? _localMessage; // explication quand le serveur n'a rien précisé

  @override
  void initState() {
    super.initState();
    _order = widget.order;
    final momo = context.read<AuthProvider>().user?.momoPhone?.trim() ?? '';
    _phone = TextEditingController(text: momo.isNotEmpty ? momo : widget.order.phone);
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
    if (_order.isPaid) {
      _step = _Step.result;
    } else {
      _resume();
    }
  }

  @override
  void dispose() {
    _stopTimers();
    _pulse.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  /// Une demande est peut-être déjà en cours (retour sur l'écran) : on la reprend.
  Future<void> _resume() async {
    try {
      final (o, p) = await Api.instance.currentPayment(_order.id);
      if (!mounted || _step != _Step.input || _busy) return;
      if (o.isPaid || (p != null && p.isPending)) {
        _apply(o, p);
      } else {
        setState(() => _order = o);
      }
    } catch (_) {
      // Pas grave : le client peut lancer une nouvelle demande.
    }
  }

  /// Met à jour l'écran selon la réponse du serveur.
  void _apply(Order o, PaymentAttempt? p) {
    final expiresAt = p?.expiresAt;
    final paid = o.isPaid || (p != null && p.isPaid);
    final pending = !paid && p != null && p.isPending;
    final startWaiting = pending && _step != _Step.waiting;
    setState(() {
      _order = o;
      _payment = p;
      _step = pending ? _Step.waiting : _Step.result;
    });
    if (startWaiting) _startWaiting(expiresAt);
    if (!pending) {
      _stopTimers();
      notifyOrdersChanged();
    }
  }

  void _startWaiting(DateTime? expiresAt) {
    final now = DateTime.now();
    var deadline = expiresAt ?? now.add(_defaultWait);
    // Horloge du téléphone décalée : on se rabat sur ~2 min.
    if (deadline.isBefore(now) || deadline.isAfter(now.add(const Duration(minutes: 10)))) {
      deadline = now.add(_defaultWait);
    }
    _stopTimers();
    _deadline = deadline;
    _waitTotal = deadline.difference(now);
    _remaining = _waitTotal;
    _pollTimer = Timer.periodic(_pollEvery, (_) => _poll());
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted || _step != _Step.waiting) return;
    final r = _deadline.difference(DateTime.now());
    setState(() => _remaining = r);
    if (r.inSeconds < -_graceSeconds) _timeout();
  }

  Future<void> _poll() async {
    if (_polling || _step != _Step.waiting) return;
    _polling = true;
    try {
      final (o, p) = await Api.instance.currentPayment(_order.id);
      if (!mounted || _step != _Step.waiting) return;
      _apply(o, p);
    } catch (_) {
      // Réseau instable : nouvel essai au prochain tour.
    } finally {
      _polling = false;
    }
  }

  /// Plus de réponse après le délai : dernier contrôle puis « Expiré ».
  Future<void> _timeout() async {
    _stopTimers();
    try {
      final (o, p) = await Api.instance.currentPayment(_order.id);
      if (!mounted || _step != _Step.waiting) return;
      if (o.isPaid || p == null || !p.isPending) {
        _apply(o, p);
        return;
      }
    } catch (_) {
      if (!mounted) return;
    }
    setState(() {
      _step = _Step.result;
      _localMessage = "Aucune confirmation reçue à temps. Si votre compte a été débité, la commande "
          'se mettra à jour toute seule ; sinon, réessayez.';
    });
    notifyOrdersChanged();
  }

  Future<void> _start() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _localMessage = null;
    });
    try {
      final phone = _phone.text.replaceAll(RegExp(r'[\s.\-]'), '');
      final (o, p) = await Api.instance.startPayment(_order.id, phone);
      if (!mounted) return;
      _apply(o, p);
      notifyOrdersChanged();
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Change d'opérateur (Flooz ↔ Mixx) avant d'envoyer la demande : le serveur recalcule
  /// les frais et le total, et refuse si une demande est encore en cours.
  Future<void> _changeOperator(String method) async {
    if (_busy || method == _order.paymentMethod) return;
    setState(() {
      _busy = true;
      _localMessage = null;
    });
    try {
      final o = await Api.instance.changePaymentMethod(_order.id, method);
      if (!mounted) return;
      setState(() => _order = o);
      notifyOrdersChanged();
      showMessage(context, 'Paiement par ${paymentLabel(o.paymentMethod)} : ${formatPrice(o.total)}');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _abandon() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (o, p) = await Api.instance.abandonPayment(_order.id);
      if (!mounted) return;
      _apply(o, p);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _simulate(String result) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (o, p) = await Api.instance.simulatePayment(_order.id, result);
      if (!mounted) return;
      _apply(o, p);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _retry() {
    _stopTimers();
    setState(() {
      _step = _Step.input;
      _payment = null;
      _localMessage = null;
    });
  }

  Future<void> _leave() async {
    if (_step == _Step.waiting) {
      final ok = await confirmDialog(
        context,
        'Quitter le paiement ?',
        'Si vous avez déjà tapé votre code PIN, le paiement sera quand même pris en compte '
            'et votre commande se mettra à jour toute seule.',
        confirm: 'Quitter',
      );
      if (!ok || !mounted) return;
    }
    _stopTimers();
    notifyOrdersChanged();
    Navigator.pop(context, _order);
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (_step) {
      _Step.input => _buildInput(context),
      _Step.waiting => _buildWaiting(context),
      _Step.result => _buildResult(context),
    };
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Paiement • commande n°${_order.id}')),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: KeyedSubtree(key: ValueKey(_step), child: body),
          ),
        ),
      ),
    );
  }

  // ---------- Étape 1 : saisie du numéro ----------

  Widget _buildInput(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final o = _order;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Payer ${formatPrice(o.total)} par ${paymentLabel(o.paymentMethod)}',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: scheme.onSurface, height: 1.25),
          ),
          const SizedBox(height: 12),
          // Changer d'opérateur : seulement tant qu'aucune demande n'est en cours.
          if (isMobileMoney(o.paymentMethod) && !o.isCancelled && !o.isPaid) ...[
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'flooz', label: Text('Flooz'), icon: Icon(Icons.phone_android_rounded)),
                ButtonSegment(value: 'mixx', label: Text('Mixx by Yas'), icon: Icon(Icons.phone_android_rounded)),
              ],
              selected: {o.paymentMethod},
              showSelectedIcon: false,
              onSelectionChanged: _busy ? null : (s) => _changeOperator(s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: AppColors.red,
                selectedForegroundColor: Colors.white,
                backgroundColor: scheme.surface,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _AmountRow('Sous-total', o.subtotal),
                  if (o.isDelivery)
                    _AmountRow(
                      o.deliveryDistanceKm == null ? 'Livraison' : 'Livraison (${formatKm(o.deliveryDistanceKm!)})',
                      o.deliveryFee,
                    ),
                  if (o.paymentFee > 0) _AmountRow('Frais de paiement', o.paymentFee),
                  const Divider(height: 18),
                  _AmountRow('Total à payer', o.total, bold: true),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Numéro ${paymentLabel(o.paymentMethod)} à débiter',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.phone_android_rounded), hintText: 'Ex : 90 12 34 56'),
            validator: (v) =>
                (v == null || v.replaceAll(RegExp(r'\D'), '').length < 8) ? 'Numéro invalide' : null,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_rounded, color: scheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Vous confirmerez avec votre code PIN sur votre téléphone. '
                    'Ne communiquez jamais votre code PIN.',
                    style: TextStyle(color: scheme.onSecondaryContainer, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          if (o.isCancelled) ...[
            const SizedBox(height: 16),
            Text('Cette commande est annulée : elle ne peut plus être payée.',
                style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy || o.isCancelled ? null : _start,
            icon: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Icon(Icons.send_to_mobile_rounded),
            label: const Text('Envoyer la demande'),
          ),
        ],
      ),
    );
  }

  // ---------- Étape 2 : attente du code PIN ----------

  Widget _buildWaiting(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _payment;
    final totalSec = _waitTotal.inSeconds <= 0 ? 1 : _waitTotal.inSeconds;
    final fraction = (_remaining.inSeconds / totalSec).clamp(0.0, 1.0);
    final over = _remaining.inSeconds <= 0;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 8),
        Center(
          child: ScaleTransition(
            scale: Tween(begin: 0.9, end: 1.08).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
            child: CircleAvatar(
              radius: 44,
              backgroundColor: AppColors.red.withValues(alpha: 0.12),
              child: const Icon(Icons.phonelink_ring_rounded, size: 46, color: AppColors.red),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Confirmez le paiement en tapant votre code PIN sur votre téléphone',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: scheme.onSurface, height: 1.3),
        ),
        const SizedBox(height: 10),
        Text(
          'Une demande de ${formatPrice(p?.amount ?? _order.total)} a été envoyée au '
          '${p?.phone ?? _phone.text} (${paymentLabel(_order.paymentMethod)}).',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
        ),
        const SizedBox(height: 24),
        Center(
          child: SizedBox(
            width: 96,
            height: 96,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: over ? null : fraction,
                  strokeWidth: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: AppColors.red,
                ),
                Center(
                  child: Text(
                    over ? '...' : formatCountdown(_remaining),
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          over ? 'Vérification du paiement...' : 'En attente de votre confirmation',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
        ),
        if (p != null && p.simulated) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.yellow.withValues(alpha: 0.18),
              border: Border.all(color: AppColors.yellow),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('MODE TEST',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.5, color: scheme.onSurface)),
                const SizedBox(height: 4),
                Text(
                  "Aucun argent réel n'est débité. Simulez la réponse du client :",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.green, foregroundColor: Colors.white),
                  onPressed: _busy ? null : () => _simulate('paid'),
                  child: const Text('Simuler code PIN correct'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                  onPressed: _busy ? null : () => _simulate('failed'),
                  child: const Text('Simuler un refus'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        TextButton.icon(
          onPressed: _busy ? null : _abandon,
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          icon: const Icon(Icons.close_rounded),
          label: const Text('Annuler'),
        ),
      ],
    );
  }

  // ---------- Étape 3 : résultat ----------

  Widget _buildResult(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paid = _order.isPaid || (_payment?.isPaid ?? false);
    final status = _payment?.status ?? _order.paymentStatus;
    final String title;
    final String message;
    final IconData icon;
    final Color color;
    if (paid) {
      title = 'Paiement reçu ✅';
      message = 'Merci ! ${formatPrice(_order.total)} ont bien été reçus. '
          'Le restaurant va lancer votre commande.';
      icon = Icons.verified_rounded;
      color = AppColors.green;
    } else {
      icon = Icons.error_outline_rounded;
      color = scheme.error;
      if (status == 'expired' || (_localMessage != null && _payment?.message == null)) {
        title = 'Expiré';
      } else if (status == 'rejected') {
        title = 'Refusé';
      } else {
        title = 'Paiement non abouti';
      }
      message = _payment?.message ??
          _localMessage ??
          (status == 'expired'
              ? "Le paiement n'a pas été confirmé à temps. Aucun montant n'a été validé."
              : "Le paiement n'a pas été confirmé. Vous pouvez réessayer.");
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.elasticOut,
            builder: (_, v, child) => Transform.scale(scale: v, child: child),
            child: CircleAvatar(
              radius: 44,
              backgroundColor: color.withValues(alpha: 0.14),
              child: Icon(icon, size: 50, color: color),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(title,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: scheme.onSurface)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: paid ? AppColors.green.withValues(alpha: 0.12) : scheme.errorContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: paid ? scheme.onSurface : scheme.onErrorContainer, height: 1.4),
          ),
        ),
        const SizedBox(height: 28),
        if (paid)
          FilledButton.icon(
            onPressed: _leave,
            icon: const Icon(Icons.receipt_long_rounded),
            label: const Text('Suivre ma commande'),
          )
        else ...[
          FilledButton.icon(
            onPressed: _order.isCancelled ? null : _retry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Réessayer'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: _leave, child: const Text('Retour à la commande')),
        ],
      ],
    );
  }
}

class _AmountRow extends StatelessWidget {
  final String label;
  final int amount;
  final bool bold;
  const _AmountRow(this.label, this.amount, {this.bold = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w900 : FontWeight.w500,
      fontSize: bold ? 17 : 14,
      color: bold ? AppColors.red : scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [Text(label, style: style), const Spacer(), Text(formatPrice(amount), style: style)]),
    );
  }
}
