import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../services/counter_api.dart';
import '../../services/order_alert.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';

/// Caisse : vente au comptoir (sur place ou à emporter), payée en espèces, Flooz ou Mixx by Yas.
/// Téléphone : plats puis ticket (barre du bas) ; tablette : plats à gauche, ticket à droite.
class CounterScreen extends StatefulWidget {
  final bool active;
  const CounterScreen({super.key, this.active = false});

  @override
  State<CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends State<CounterScreen> {
  static const _splitWidth = 760.0;

  List<Product>? _products;
  List<Category> _categories = const [];
  AppSettings? _settings;
  Object? _error;
  DateTime? _loadedAt;

  int? _categoryId; // null = toutes
  final _search = TextEditingController();
  String _query = '';

  /// Ticket : produit → quantité (ordre d'ajout conservé).
  final LinkedHashMap<int, int> _ticket = LinkedHashMap();
  CounterService _service = CounterService.dineIn;
  String _method = 'cash';
  final _name = TextEditingController();
  final _note = TextEditingController();
  final _phone = TextEditingController();
  final _received = TextEditingController();
  bool _busy = false;
  bool _showTicket = false; // téléphone : ticket affiché à la place des plats

  @override
  void initState() {
    super.initState();
    OrderAlert.instance.init();
    _load();
  }

  @override
  void didUpdateWidget(CounterScreen old) {
    super.didUpdateWidget(old);
    // Retour sur l'onglet : catalogue (disponibilités, prix) rechargé s'il date de plus d'une minute.
    final at = _loadedAt;
    if (widget.active && !old.active && (at == null || DateTime.now().difference(at).inMinutes >= 1)) {
      _load(fresh: true);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    _note.dispose();
    _phone.dispose();
    _received.dispose();
    super.dispose();
  }

  Future<void> _load({bool fresh = false}) async {
    try {
      final results = await Future.wait([
        Api.instance.products(fresh: fresh),
        Api.instance.categories(fresh: fresh),
        Api.instance.settings(fresh: true),
      ]);
      if (!mounted) return;
      final products = results[0] as List<Product>;
      setState(() {
        _products = products;
        _categories = [...results[1] as List<Category>]..sort((a, b) => a.position.compareTo(b.position));
        _settings = results[2] as AppSettings;
        _error = null;
        _loadedAt = DateTime.now();
        // Plat devenu indisponible ou supprimé : retiré du ticket.
        final available = {for (final p in products) if (p.available) p.id};
        _ticket.removeWhere((id, _) => !available.contains(id));
      });
    } catch (e) {
      if (mounted && _products == null) setState(() => _error = e);
      if (mounted && _products != null) showMessage(context, e, error: true);
    }
  }

  // ---------- Calculs ----------

  Map<int, Product> get _byId => {for (final p in _products ?? const <Product>[]) p.id: p};

  int get _itemCount => _ticket.values.fold(0, (s, q) => s + q);

  int get _subtotal {
    final byId = _byId;
    var sum = 0;
    _ticket.forEach((id, q) => sum += (byId[id]?.price ?? 0) * q);
    return sum;
  }

  /// Frais mobile money facturés au client (0 si le restaurant les absorbe ou en espèces).
  int _feeFor(int subtotal) {
    final s = _settings;
    if (s == null) return 0;
    return paymentFeeFor(subtotal, _method, s.clientFeePercentFor(_method));
  }

  int get _total => _subtotal + _feeFor(_subtotal);

  /// Montant reçu en espèces (null si non saisi).
  int? get _receivedAmount {
    final digits = _received.text.replaceAll(RegExp(r'\D'), '');
    return digits.isEmpty ? null : int.tryParse(digits);
  }

  List<Product> get _visibleProducts {
    final q = _query.trim().toLowerCase();
    return (_products ?? const <Product>[])
        .where((p) => p.available)
        .where((p) => _categoryId == null || p.categoryId == _categoryId)
        .where((p) => q.isEmpty || p.name.toLowerCase().contains(q))
        .toList();
  }

  // ---------- Ticket ----------

  void _add(Product p) {
    HapticFeedback.selectionClick();
    setState(() {
      final q = _ticket[p.id] ?? 0;
      if (q < maxQuantityPerItem) _ticket[p.id] = q + 1;
    });
  }

  void _setQty(int productId, int q) {
    setState(() {
      if (q <= 0) {
        _ticket.remove(productId);
      } else {
        _ticket[productId] = q;
      }
    });
  }

  void _clearTicket() {
    setState(() {
      _ticket.clear();
      _name.clear();
      _note.clear();
      _phone.clear();
      _received.clear();
      _service = CounterService.dineIn;
      _method = 'cash';
      _showTicket = false;
    });
  }

  Future<void> _confirmClear() async {
    if (_ticket.isEmpty) return;
    final ok = await confirmDialog(context, 'Vider le ticket ?', 'Tous les articles seront retirés.',
        confirm: 'Vider', danger: true);
    if (ok && mounted) _clearTicket();
  }

  // ---------- Encaissement ----------

  String? _validate() {
    if (_ticket.isEmpty) return 'Ajoutez au moins un plat';
    if (_method == 'cash') {
      final r = _receivedAmount;
      if (r != null && r < _total) return 'Montant reçu insuffisant';
    } else {
      if (_phone.text.replaceAll(RegExp(r'\D'), '').length < 8) {
        return 'Numéro ${counterPaymentMethods[_method]} du client obligatoire';
      }
    }
    return null;
  }

  Future<void> _checkout() async {
    if (_busy) return;
    final problem = _validate();
    if (problem != null) {
      showMessage(context, problem, error: true);
      return;
    }
    FocusScope.of(context).unfocus();
    if (_method == 'cash') {
      await _checkoutCash(received: _receivedAmount);
    } else {
      await _checkoutMobileMoney();
    }
  }

  Future<Order?> _create(String method) async {
    setState(() => _busy = true);
    try {
      final order = await createCounterOrder(
        items: Map.of(_ticket),
        service: _service,
        paymentMethod: method,
        customerName: _name.text,
        phone: method == 'cash' ? null : _phone.text,
        note: _note.text,
      );
      OrderAlert.instance.markLocalOrder(order.id); // pas de sonnerie pour cette vente
      return order;
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkoutCash({int? received}) async {
    final order = await _create('cash');
    if (order == null || !mounted) return;
    await _showSuccess(order, received: received);
    if (mounted) _clearTicket();
  }

  Future<void> _checkoutMobileMoney() async {
    final order = await _create(_method);
    if (order == null || !mounted) return;
    final result = await showDialog<_MomoResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MomoPaymentDialog(order: order, phone: _phone.text),
    );
    if (!mounted) return;
    switch (result) {
      case _MomoResult.paid:
        _clearTicket();
      case _MomoResult.cash:
        // La vente mobile money a été annulée : même ticket, encaissé en espèces.
        setState(() {
          _method = 'cash';
          _received.clear();
        });
        await _checkoutCash();
      case _MomoResult.cancelled:
      case null:
        showMessage(context, 'Vente n°${order.id} annulée. Le ticket est conservé.');
    }
  }

  Future<void> _showSuccess(Order order, {int? received}) {
    final change = received == null ? null : received - order.total;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_rounded, color: AppColors.green, size: 56),
        title: Text('Vente n°${order.id} enregistrée'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Envoyée en cuisine', textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
            const SizedBox(height: 14),
            _amountRow(ctx, 'Total', order.total, big: true),
            if (received != null) ...[
              _amountRow(ctx, 'Reçu', received),
              if (change != null && change > 0) _amountRow(ctx, 'Monnaie à rendre', change, big: true, accent: true),
            ],
          ],
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Nouvelle vente'),
          ),
        ],
      ),
    );
  }

  static Widget _amountRow(BuildContext context, String label, int amount, {bool big = false, bool accent = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(fontSize: big ? 17 : 15, fontWeight: big ? FontWeight.w800 : null)),
          ),
          Price(amount, size: big ? 20 : 15, color: accent ? AppColors.green : null),
        ],
      ),
    );
  }

  // ---------- Interface ----------

  @override
  Widget build(BuildContext context) {
    final products = _products;
    final Widget body;
    if (products == null) {
      body = _error != null
          ? ErrorRetry(error: _error!, onRetry: () => _load(fresh: true))
          : const Center(child: CircularProgressIndicator());
    } else {
      body = LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= _splitWidth) {
          return Row(
            children: [
              Expanded(child: _catalog()),
              const VerticalDivider(width: 1, thickness: 1),
              SizedBox(width: c.maxWidth >= 1100 ? 420 : 360, child: _ticketPanel(phone: false)),
            ],
          );
        }
        return _showTicket ? _ticketPanel(phone: true) : _catalog();
      });
    }
    final phone = MediaQuery.sizeOf(context).width < _splitWidth;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Caisse'),
        leading: phone && _showTicket
            ? IconButton(
                tooltip: 'Retour aux plats',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => setState(() => _showTicket = false),
              )
            : null,
        actions: [
          IconButton(
            tooltip: 'Actualiser le catalogue',
            onPressed: () => _load(fresh: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: phone && products != null && !_showTicket && _ticket.isNotEmpty ? _phoneBar() : null,
    );
  }

  /// Téléphone : résumé du ticket en bas des plats.
  Widget _phoneBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            backgroundColor: AppColors.red,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: () => setState(() => _showTicket = true),
          child: Row(
            children: [
              BounceOnChange(
                trigger: _itemCount,
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.white,
                  child: Text('$_itemCount',
                      style: const TextStyle(color: AppColors.red, fontWeight: FontWeight.w900, fontSize: 14)),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Voir le ticket', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ),
              Text(formatPrice(_subtotal), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _catalog() {
    final scheme = Theme.of(context).colorScheme;
    final visible = _visibleProducts;
    final usedCategories = {for (final p in _products ?? const <Product>[]) if (p.available) p.categoryId};
    final categories = _categories.where((c) => usedCategories.contains(c.id)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Rechercher un plat',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Effacer',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 50,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              _categoryChip(null, 'Tout', scheme),
              for (final c in categories) _categoryChip(c.id, '${categoryEmoji(c.icon)} ${c.name}', scheme),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? EmptyState(
                  emoji: '🔎',
                  title: 'Aucun plat',
                  message: _query.isNotEmpty ? 'Aucun plat disponible ne correspond à « $_query ».' : null,
                )
              : RefreshIndicator(
                  onRefresh: () => _load(fresh: true),
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 190,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.8,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (_, i) => _productTile(visible[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _categoryChip(int? id, String label, ColorScheme scheme) {
    final selected = _categoryId == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        selectedColor: AppColors.red,
        backgroundColor: scheme.surface,
        labelStyle: TextStyle(color: selected ? Colors.white : scheme.onSurface, fontWeight: FontWeight.w700),
        onSelected: (_) => setState(() => _categoryId = id),
      ),
    );
  }

  Widget _productTile(Product p) {
    final qty = _ticket[p.id] ?? 0;
    final scheme = Theme.of(context).colorScheme;
    return Pressable(
      onTap: () => _add(p),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: qty > 0 ? AppColors.red : Colors.transparent, width: 2),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: ProductImage(url: p.imageUrl)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: scheme.onSurface)),
                      const SizedBox(height: 2),
                      Price(p.price, size: 14),
                    ],
                  ),
                ),
              ],
            ),
            if (p.isPack)
              const Positioned(top: 8, left: 8, child: PackBadge(small: true)),
            if (qty > 0)
              Positioned(
                top: 8,
                right: 8,
                child: BounceOnChange(
                  trigger: qty,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: AppColors.red, borderRadius: BorderRadius.circular(20)),
                    child: Text('×$qty',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 15)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _ticketPanel({required bool phone}) {
    final scheme = Theme.of(context).colorScheme;
    final byId = _byId;
    final subtotal = _subtotal;
    final fee = _feeFor(subtotal);
    final total = subtotal + fee;
    final received = _receivedAmount;
    final momo = isMobileMoney(_method);

    final details = ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _itemCount == 0 ? 'Ticket' : 'Ticket · $_itemCount article${_itemCount > 1 ? 's' : ''}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            if (_ticket.isNotEmpty)
              TextButton.icon(
                onPressed: _confirmClear,
                icon: const Icon(Icons.delete_sweep_rounded),
                label: const Text('Vider'),
              ),
          ],
        ),
        if (_ticket.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              'Touchez un plat pour l\'ajouter au ticket.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          )
        else
          for (final e in _ticket.entries)
            if (byId[e.key] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(byId[e.key]!.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                          // Pack : contenu à préparer / à remettre au client.
                          if (byId[e.key]!.isPack) ItemDetailsText(byId[e.key]!.packSummary, maxLines: null),
                          Text(
                            '${formatPrice(byId[e.key]!.price)} · ${formatPrice(byId[e.key]!.price * e.value)}',
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    QuantityStepper(
                      value: e.value,
                      compact: true,
                      onChanged: (q) => _setQty(e.key, q),
                    ),
                  ],
                ),
              ),
        const Divider(height: 24),
        _label('Service'),
        SegmentedButton<CounterService>(
          segments: const [
            ButtonSegment(
                value: CounterService.dineIn, label: Text('Sur place'), icon: Icon(Icons.restaurant_rounded)),
            ButtonSegment(
                value: CounterService.takeaway, label: Text('À emporter'), icon: Icon(Icons.shopping_bag_rounded)),
          ],
          selected: {_service},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _service = s.first),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          maxLength: 60,
          decoration: const InputDecoration(
            labelText: 'Nom du client (facultatif)',
            prefixIcon: Icon(Icons.person_outline_rounded),
            isDense: true,
            counterText: '',
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _note,
          textCapitalization: TextCapitalization.sentences,
          maxLength: 300,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Note pour la cuisine (facultatif)',
            prefixIcon: Icon(Icons.sticky_note_2_outlined),
            isDense: true,
            counterText: '',
          ),
        ),
        const SizedBox(height: 14),
        _label('Paiement'),
        SegmentedButton<String>(
          segments: [
            for (final m in counterPaymentMethods.entries)
              ButtonSegment(value: m.key, label: Text(m.value, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
          selected: {_method},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _method = s.first),
        ),
        const SizedBox(height: 12),
        if (!momo) ...[
          TextField(
            controller: _received,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Montant reçu',
              prefixIcon: Icon(Icons.payments_outlined),
              suffixText: 'FCFA',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                label: const Text('Compte exact'),
                onPressed: total <= 0 ? null : () => setState(() => _received.text = '$total'),
              ),
              for (final bill in const [1000, 2000, 5000, 10000])
                if (bill >= total)
                  ActionChip(
                    label: Text(formatPrice(bill)),
                    onPressed: () => setState(() => _received.text = '$bill'),
                  ),
            ],
          ),
          if (received != null && _ticket.isNotEmpty) ...[
            const SizedBox(height: 10),
            _changeBox(received - total),
          ],
        ] else ...[
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 +]'))],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Téléphone ${counterPaymentMethods[_method]} du client',
              hintText: 'Ex : 90 12 34 56',
              prefixIcon: const Icon(Icons.phone_android_rounded),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Le client recevra la demande de paiement sur son téléphone et confirmera avec son code PIN.',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
          ),
        ],
      ],
    );

    final summary = Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (fee > 0) ...[
                _amountRow(context, 'Sous-total', subtotal),
                _amountRow(context, 'Frais ${counterPaymentMethods[_method]}', fee),
              ],
              Row(
                children: [
                  const Expanded(
                    child: Text('Total', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                  ),
                  Price(total, size: 24),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                  ),
                  onPressed: _busy || _ticket.isEmpty ? null : _checkout,
                  icon: _busy
                      ? const SizedBox(
                          width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                      : Icon(momo ? Icons.phone_android_rounded : Icons.point_of_sale_rounded),
                  label: Text(_busy ? 'Enregistrement…' : 'Encaisser'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Column(children: [Expanded(child: details), summary]);
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
      );

  Widget _changeBox(int change) {
    final ok = change >= 0;
    final color = ok ? AppColors.green : AppColors.darkRed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.currency_exchange_rounded : Icons.error_outline_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(ok ? 'Monnaie à rendre' : 'Il manque',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: color)),
          ),
          Text(formatPrice(change.abs()), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: color)),
        ],
      ),
    );
  }
}

// ---------- Paiement mobile money au comptoir ----------

enum _MomoResult { paid, cancelled, cash }

enum _MomoStep { sending, waiting, paid, failed }

/// Demande de paiement envoyée sur le téléphone du client, puis suivi toutes les 3 s.
/// Renvoie [_MomoResult.paid], [_MomoResult.cancelled] (vente annulée) ou [_MomoResult.cash]
/// (vente annulée, à ré-encaisser en espèces : l'API n'autorise pas le passage aux espèces).
class _MomoPaymentDialog extends StatefulWidget {
  final Order order;
  final String phone;
  const _MomoPaymentDialog({required this.order, required this.phone});

  @override
  State<_MomoPaymentDialog> createState() => _MomoPaymentDialogState();
}

class _MomoPaymentDialogState extends State<_MomoPaymentDialog> {
  static const _pollEvery = Duration(seconds: 3);
  static const _defaultWait = Duration(minutes: 2);
  static const _graceSeconds = 20;

  late Order _order = widget.order;
  late final TextEditingController _phone = TextEditingController(text: widget.phone);
  PaymentAttempt? _payment;
  _MomoStep _step = _MomoStep.sending;
  String? _message;
  bool _busy = false;
  bool _polling = false;
  Timer? _pollTimer;
  Timer? _tickTimer;
  DateTime _deadline = DateTime.now();
  Duration _remaining = _defaultWait;
  Duration _waitTotal = _defaultWait;

  @override
  void initState() {
    super.initState();
    _send();
  }

  @override
  void dispose() {
    _stopTimers();
    _phone.dispose();
    super.dispose();
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  Future<void> _send() async {
    _stopTimers();
    setState(() {
      _step = _MomoStep.sending;
      _message = null;
      _busy = true;
    });
    try {
      final phone = _phone.text.replaceAll(RegExp(r'[\s.\-]'), '');
      final (o, p) = await Api.instance.startPayment(_order.id, phone);
      if (!mounted) return;
      _apply(o, p);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _MomoStep.failed;
        _message = e.toString();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _apply(Order o, PaymentAttempt? p) {
    final paid = o.isPaid || (p?.isPaid ?? false);
    final pending = !paid && (p?.isPending ?? false);
    final startWaiting = pending && _step != _MomoStep.waiting;
    setState(() {
      _order = o;
      _payment = p;
      if (paid) {
        _step = _MomoStep.paid;
      } else if (pending) {
        _step = _MomoStep.waiting;
      } else {
        _step = _MomoStep.failed;
        _message = p?.message ?? 'Le paiement n\'a pas abouti.';
      }
    });
    if (startWaiting) _startWaiting(p?.expiresAt);
    if (!pending) _stopTimers();
    if (paid) HapticFeedback.heavyImpact();
  }

  void _startWaiting(DateTime? expiresAt) {
    final now = DateTime.now();
    var deadline = expiresAt ?? now.add(_defaultWait);
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
    if (!mounted || _step != _MomoStep.waiting) return;
    final r = _deadline.difference(DateTime.now());
    setState(() => _remaining = r);
    if (r.inSeconds < -_graceSeconds) _timeout();
  }

  Future<void> _poll() async {
    if (_polling || _step != _MomoStep.waiting) return;
    _polling = true;
    try {
      final (o, p) = await Api.instance.currentPayment(_order.id);
      if (mounted && _step == _MomoStep.waiting) _apply(o, p);
    } catch (_) {
      // Réseau instable : nouvel essai au prochain tour.
    } finally {
      _polling = false;
    }
  }

  Future<void> _timeout() async {
    _stopTimers();
    try {
      final (o, p) = await Api.instance.currentPayment(_order.id);
      if (!mounted || _step != _MomoStep.waiting) return;
      if (o.isPaid || p == null || !p.isPending) {
        _apply(o, p);
        return;
      }
    } catch (_) {
      if (!mounted) return;
    }
    setState(() {
      _step = _MomoStep.failed;
      _message = 'Aucune confirmation reçue à temps.';
    });
  }

  Future<void> _simulate(String result) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (o, p) = await Api.instance.simulatePayment(_order.id, result);
      if (mounted) _apply(o, p);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Annule la vente mobile money (sauf si le paiement vient d'arriver). Vrai si annulée.
  Future<bool> _cancelSale() async {
    setState(() => _busy = true);
    _stopTimers();
    try {
      try {
        final (o, p) = await Api.instance.currentPayment(_order.id);
        if (o.isPaid || (p?.isPaid ?? false)) {
          if (mounted) _apply(o, p);
          if (mounted) showMessage(context, 'Le paiement vient d\'être reçu : la vente est conservée.');
          return false;
        }
      } catch (_) {
        // On tente l'annulation quand même.
      }
      await Api.instance.setOrderStatus(_order.id, 'cancelled');
      return true;
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel({required bool toCash}) async {
    if (_busy) return;
    final ok = await confirmDialog(
      context,
      toCash ? 'Encaisser en espèces ?' : 'Annuler la vente ?',
      toCash
          ? 'La vente n°${_order.id} par ${paymentLabel(_order.paymentMethod)} sera annulée et le même ticket '
              'sera enregistré en espèces.'
          : 'La vente n°${_order.id} sera annulée. Le ticket reste affiché à la caisse.',
      confirm: toCash ? 'Passer aux espèces' : 'Annuler la vente',
      danger: !toCash,
    );
    if (!ok || !mounted) return;
    if (await _cancelSale() && mounted) {
      Navigator.pop(context, toCash ? _MomoResult.cash : _MomoResult.cancelled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Vente n°${_order.id} · ${paymentLabel(_order.paymentMethod)}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Center(child: Price(_order.total, size: 28)),
                const SizedBox(height: 18),
                ...switch (_step) {
                  _MomoStep.sending => _sending(),
                  _MomoStep.waiting => _waiting(scheme),
                  _MomoStep.paid => _paid(),
                  _MomoStep.failed => _failed(scheme),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _sending() => const [
        Center(child: CircularProgressIndicator()),
        SizedBox(height: 14),
        Text('Envoi de la demande de paiement…', textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
      ];

  List<Widget> _waiting(ColorScheme scheme) {
    final p = _payment;
    final progress = _waitTotal.inSeconds <= 0 ? 0.0 : (_remaining.inSeconds / _waitTotal.inSeconds).clamp(0.0, 1.0);
    return [
      const Icon(Icons.phonelink_ring_rounded, size: 52, color: AppColors.red),
      const SizedBox(height: 10),
      const Text(
        'Le client confirme avec son code PIN…',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 6),
      Text(
        'Demande envoyée au ${p?.phone ?? _phone.text}.',
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 16),
      Text(
        formatCountdown(_remaining),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, fontFeatures: [FontFeature.tabularFigures()]),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: progress, minHeight: 6, borderRadius: BorderRadius.circular(6)),
      if (p != null && p.simulated) ...[
        const SizedBox(height: 16),
        Text('Mode simulation', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _simulate('paid'),
                child: const Text('Simuler : payé'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _simulate('failed'),
                child: const Text('Simuler : refusé'),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      TextButton.icon(
        onPressed: _busy ? null : () => _cancel(toCash: false),
        icon: const Icon(Icons.close_rounded),
        label: const Text('Annuler la vente'),
      ),
    ];
  }

  List<Widget> _paid() => [
        const FadeSlideIn(child: Icon(Icons.check_circle_rounded, size: 72, color: AppColors.green)),
        const SizedBox(height: 10),
        const Text('Paiement reçu',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        Text('Vente n°${_order.id} envoyée en cuisine.', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => Navigator.pop(context, _MomoResult.paid),
          child: const Text('Nouvelle vente'),
        ),
      ];

  List<Widget> _failed(ColorScheme scheme) => [
        const Icon(Icons.error_outline_rounded, size: 60, color: AppColors.darkRed),
        const SizedBox(height: 8),
        const Text('Paiement non abouti',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
        if ((_message ?? '').isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(_message!, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 +]'))],
          decoration: const InputDecoration(
            labelText: 'Téléphone du client',
            prefixIcon: Icon(Icons.phone_android_rounded),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: _busy
              ? null
              : () {
                  if (_phone.text.replaceAll(RegExp(r'\D'), '').length < 8) {
                    showMessage(context, 'Numéro invalide', error: true);
                    return;
                  }
                  _send();
                },
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Réessayer'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : () => _cancel(toCash: true),
          icon: const Icon(Icons.payments_outlined),
          label: const Text('Encaisser en espèces'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : () => _cancel(toCash: false),
          child: const Text('Annuler la vente'),
        ),
      ];
}
