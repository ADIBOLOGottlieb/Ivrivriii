import 'package:flutter/material.dart';

import '../../models_admin.dart';
import '../../services/admin_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import '../shared/order_detail_screen.dart';

/// Paiements mobile money à vérifier à la main : en attente depuis plus de 2 minutes,
/// ou refusés avec un écart (montant reçu inférieur au total, etc.).
class PaymentsReviewScreen extends StatefulWidget {
  const PaymentsReviewScreen({super.key});

  @override
  State<PaymentsReviewScreen> createState() => _PaymentsReviewScreenState();
}

class _PaymentsReviewScreenState extends State<PaymentsReviewScreen> {
  List<PaymentReview>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await fetchPaymentsReview();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _validate(PaymentReview p) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ValidatePaymentDialog(review: p),
    );
    if (ok == true && mounted) {
      showMessage(context, 'Paiement de la commande n°${p.orderId} validé');
      _load();
    }
  }

  Future<void> _reject(PaymentReview p) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RejectPaymentDialog(review: p),
    );
    if (ok == true && mounted) {
      showMessage(context, 'Paiement de la commande n°${p.orderId} rejeté');
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Flexible(child: Text('Paiements à vérifier', overflow: TextOverflow.ellipsis)),
            if (items != null && items.isNotEmpty) ...[
              const SizedBox(width: 8),
              Badge(label: Text('${items.length}'), backgroundColor: AppColors.red),
            ],
          ],
        ),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: items == null
            ? (_error != null
                ? ListView(children: [ErrorRetry(error: _error!, onRetry: _load)])
                : const Center(child: CircularProgressIndicator()))
            : items.isEmpty
                ? ListView(children: const [
                    SizedBox(height: 80),
                    EmptyState(
                      emoji: '✅',
                      title: 'Rien à vérifier',
                      message: 'Tous les paiements mobile money sont à jour.',
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.all(20),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => FadeSlideIn(
                      key: ValueKey(items[i].id),
                      delay: FadeSlideIn.stagger(i),
                      child: _ReviewCard(
                        review: items[i],
                        onValidate: () => _validate(items[i]),
                        onReject: () => _reject(items[i]),
                        onOpenOrder: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => OrderDetailScreen(orderId: items[i].orderId, admin: true),
                            ),
                          );
                          _load();
                        },
                      ),
                    ),
                  ),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final PaymentReview review;
  final VoidCallback onValidate;
  final VoidCallback onReject;
  final VoidCallback onOpenOrder;

  const _ReviewCard({
    required this.review,
    required this.onValidate,
    required this.onReject,
    required this.onOpenOrder,
  });

  static String _statusText(String s) {
    switch (s) {
      case 'pending':
        return 'En attente';
      case 'failed':
        return 'Refusé';
      case 'expired':
        return 'Expiré';
      case 'rejected':
        return 'Rejeté';
      case 'paid':
        return 'Payé';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final a = review.attempt;
    final pending = a.status == 'pending';
    final statusColor = pending ? Colors.orange.shade700 : cs.error;
    final waiting = review.waitingMinutes;
    final waitingText = waiting >= 60
        ? 'En attente depuis ${waiting ~/ 60} h ${(waiting % 60).toString().padLeft(2, '0')}'
        : 'En attente depuis $waiting min';

    Widget line(IconData icon, String text, {Color? color, FontWeight? weight}) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(icon, size: 17, color: color ?? cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text, style: TextStyle(color: color ?? cs.onSurface, fontWeight: weight)),
              ),
            ],
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onOpenOrder,
                    borderRadius: BorderRadius.circular(6),
                    child: Text(
                      'Commande n°${review.orderId}',
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _statusText(a.status),
                    style: TextStyle(color: statusColor, fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
              ],
            ),
            line(Icons.person_rounded, review.customerName.isEmpty ? 'Client inconnu' : review.customerName),
            line(Icons.payments_rounded, 'Montant attendu : ${formatPrice(review.orderTotal)}',
                weight: FontWeight.w800),
            if (a.amount > 0 && a.amount != review.orderTotal)
              line(Icons.compare_arrows_rounded, 'Montant de la tentative : ${formatPrice(a.amount)}'),
            if (review.receivedAmount != null && review.receivedAmount! > 0)
              line(
                Icons.call_received_rounded,
                'Montant reçu : ${formatPrice(review.receivedAmount!)}',
                color: review.receivedAmount! < review.orderTotal ? cs.error : null,
                weight: FontWeight.w700,
              ),
            line(Icons.phone_android_rounded,
                '${paymentLabel(a.operator)}${(a.phone ?? '').isEmpty ? '' : ' • ${a.phone}'}'),
            line(Icons.schedule_rounded, waitingText, color: waiting >= 10 ? Colors.orange.shade700 : null),
            if ((a.message ?? '').isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(a.message!, style: TextStyle(color: cs.onErrorContainer)),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: cs.error,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: onReject,
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Rejeter'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.green,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: onValidate,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Valider'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Montant saisi : accepte les espaces et points de milliers (« 21 150 », « 21.150 »).
int? _parseAmount(String v) => int.tryParse(v.replaceAll(RegExp(r'[\s.,  ]'), '').replaceAll('FCFA', ''));

class _ValidatePaymentDialog extends StatefulWidget {
  final PaymentReview review;
  const _ValidatePaymentDialog({required this.review});

  @override
  State<_ValidatePaymentDialog> createState() => _ValidatePaymentDialogState();
}

class _ValidatePaymentDialogState extends State<_ValidatePaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _reference = TextEditingController();
  late final _amount = TextEditingController(text: '${widget.review.orderTotal}');
  bool _busy = false;
  String? _serverError;

  @override
  void dispose() {
    _reference.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverError = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await validatePayment(
        widget.review.id,
        reference: _reference.text.trim(),
        amount: _parseAmount(_amount.text)!,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _serverError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = widget.review.orderTotal;
    return AlertDialog(
      title: Text('Valider la commande n°${widget.review.orderId}'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Vérifiez le paiement dans votre espace ${paymentLabel(widget.review.attempt.operator)} '
                'avant de le valider. Total attendu : ${formatPrice(total)}.',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _reference,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Référence de la transaction *',
                  hintText: 'Ex. : FL240612.1530.A12345',
                ),
                validator: (v) =>
                    (v ?? '').trim().length < 3 ? 'La référence de la transaction est obligatoire' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Montant reçu', suffixText: 'FCFA'),
                validator: (v) {
                  final n = _parseAmount(v ?? '');
                  if (n == null) return 'Montant invalide';
                  if (n < total) {
                    return 'Montant reçu inférieur au total (${formatPrice(total)}) : validation impossible';
                  }
                  return null;
                },
              ),
              if (_serverError != null) ...[
                const SizedBox(height: 14),
                _ErrorBox(message: _serverError!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.green,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 44),
          ),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Text('Valider le paiement'),
        ),
      ],
    );
  }
}

class _RejectPaymentDialog extends StatefulWidget {
  final PaymentReview review;
  const _RejectPaymentDialog({required this.review});

  @override
  State<_RejectPaymentDialog> createState() => _RejectPaymentDialogState();
}

class _RejectPaymentDialogState extends State<_RejectPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  bool _busy = false;
  String? _serverError;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverError = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await rejectPayment(widget.review.id, reason: _reason.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _serverError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Rejeter le paiement n°${widget.review.orderId}'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Le client verra que son paiement n\'a pas été accepté et pourra réessayer.',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _reason,
                autofocus: true,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Motif du rejet *',
                  hintText: 'Ex. : aucun paiement reçu sur le compte marchand',
                ),
                validator: (v) => (v ?? '').trim().length < 3 ? 'Indiquez le motif du rejet' : null,
              ),
              if (_serverError != null) ...[
                const SizedBox(height: 14),
                _ErrorBox(message: _serverError!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.darkRed,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 44),
          ),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Text('Rejeter'),
        ),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: cs.onErrorContainer, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(color: cs.onErrorContainer))),
        ],
      ),
    );
  }
}
