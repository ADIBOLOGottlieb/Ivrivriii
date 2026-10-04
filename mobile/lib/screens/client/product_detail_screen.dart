import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/cart_provider.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';

/// Ouvre la fiche produit ; [heroTag] relie l'image de la carte à celle de la fiche.
Future<void> openProduct(BuildContext context, Product product, {required String heroTag}) {
  return Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ProductDetailScreen(product: product, heroTag: heroTag)),
  );
}

class ProductDetailScreen extends StatefulWidget {
  final Product product;
  final String heroTag;

  const ProductDetailScreen({super.key, required this.product, required this.heroTag});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  late int _qty;
  // Vrai si le plat était déjà au panier à l'ouverture : on fixe la quantité au lieu de l'ajouter.
  late final bool _inCart;
  bool _added = false;

  @override
  void initState() {
    super.initState();
    final current = context.read<CartProvider>().quantityOf(widget.product.id);
    _inCart = current > 0;
    _qty = _inCart ? current.clamp(1, maxQuantityPerItem) : 1;
  }

  Future<void> _add() async {
    final cart = context.read<CartProvider>();
    if (_inCart && cart.quantityOf(widget.product.id) > 0) {
      cart.setQuantity(widget.product.id, _qty);
    } else {
      cart.add(widget.product, _qty);
    }
    setState(() => _added = true);
    await Future.delayed(const Duration(milliseconds: 750));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final topPad = MediaQuery.paddingOf(context).top;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 330,
            pinned: true,
            stretch: true,
            backgroundColor: AppColors.red,
            foregroundColor: Colors.white,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.ink),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground],
              background: Hero(
                tag: widget.heroTag,
                child: ProductImage(url: p.imageUrl, width: double.infinity, height: 330 + topPad),
              ),
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(24),
              child: Container(
                height: 24,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.popular)
                    FadeSlideIn(
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: AppColors.yellow, borderRadius: BorderRadius.circular(20)),
                        // Texte foncé fixe : le fond jaune ne change pas avec le thème.
                        child: const Text('🔥 Populaire',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: AppColors.ink)),
                      ),
                    ),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 60),
                    child: Text(p.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.2)),
                  ),
                  const SizedBox(height: 8),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 120),
                    child: p.isPack && p.savings > 0
                        ? Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 10,
                            children: [
                              Price(p.price, size: 20),
                              // Total des plats achetés séparément, barré.
                              Text(
                                formatPrice(p.packValue ?? p.price + p.savings),
                                style: TextStyle(
                                  fontSize: 15,
                                  color: scheme.onSurfaceVariant,
                                  decoration: TextDecoration.lineThrough,
                                  decorationColor: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          )
                        : Price(p.price, size: 20),
                  ),
                  if (p.isPack) ...[
                    const SizedBox(height: 10),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 150),
                      child: Row(
                        children: [
                          const PackBadge(),
                          if (p.savings > 0) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Vous économisez ${formatPrice(p.savings)}',
                                style: TextStyle(fontWeight: FontWeight.w800, color: scheme.tertiary),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (p.description != null) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 180),
                      child: Text(
                        p.description!,
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15, height: 1.55),
                      ),
                    ),
                  ],
                  if (p.isPack) ...[
                    const SizedBox(height: 22),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 210),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('Ce pack contient',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          for (final c in p.packItems)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  Container(
                                    constraints: const BoxConstraints(minWidth: 38),
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isDark ? scheme.onSurface.withValues(alpha: 0.08) : AppColors.cream,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text('${c.quantity}×',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(child: Text(c.name, style: const TextStyle(fontSize: 15))),
                                  if (c.price > 0)
                                    Text(formatPrice(c.price * c.quantity),
                                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 240),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      // Crème en clair ; léger voile en sombre (le crème rendait le texte clair invisible).
                      decoration: BoxDecoration(
                        color: isDark ? scheme.onSurface.withValues(alpha: 0.08) : AppColors.cream,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Quantité',
                                    style: TextStyle(
                                        fontWeight: FontWeight.w700, fontSize: 16, color: scheme.onSurface)),
                                if (_inCart)
                                  Text('Déjà dans votre panier',
                                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          QuantityStepper(value: _qty, min: 1, onChanged: (v) => setState(() => _qty = v)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 16, offset: const Offset(0, -4))],
        ),
        child: SafeArea(
          top: false,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: _added ? AppColors.green : AppColors.red,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _added ? null : _add,
                child: SizedBox(
                  height: 56,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: _added
                          ? Row(
                              key: const ValueKey('added'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.check_circle_rounded, color: Colors.white),
                                const SizedBox(width: 8),
                                Text(_inCart ? 'Panier mis à jour' : 'Ajouté au panier',
                                    style: const TextStyle(
                                        color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                              ],
                            )
                          : Padding(
                              key: const ValueKey('add'),
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(_inCart ? Icons.refresh_rounded : Icons.shopping_bag_rounded,
                                      color: Colors.white),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      '${_inCart ? 'Mettre à jour le panier' : 'Ajouter au panier'}'
                                      ' • ${formatPrice(p.price * _qty)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
