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
  int _qty = 1;
  bool _added = false;

  Future<void> _add() async {
    context.read<CartProvider>().add(widget.product, _qty);
    setState(() => _added = true);
    await Future.delayed(const Duration(milliseconds: 750));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final topPad = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: Colors.white,
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
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
                        child: const Text('🔥 Populaire', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
                      ),
                    ),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 60),
                    child: Text(p.name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.2)),
                  ),
                  const SizedBox(height: 8),
                  FadeSlideIn(delay: const Duration(milliseconds: 120), child: Price(p.price, size: 20)),
                  if (p.description != null) ...[
                    const SizedBox(height: 16),
                    FadeSlideIn(
                      delay: const Duration(milliseconds: 180),
                      child: Text(
                        p.description!,
                        style: const TextStyle(color: AppColors.muted, fontSize: 15, height: 1.55),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  FadeSlideIn(
                    delay: const Duration(milliseconds: 240),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(color: AppColors.cream, borderRadius: BorderRadius.circular(18)),
                      child: Row(
                        children: [
                          const Text('Quantité', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          const Spacer(),
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
          color: Colors.white,
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
                          ? const Row(
                              key: ValueKey('added'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle_rounded, color: Colors.white),
                                SizedBox(width: 8),
                                Text('Ajouté au panier',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                              ],
                            )
                          : Row(
                              key: const ValueKey('add'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.shopping_bag_rounded, color: Colors.white),
                                const SizedBox(width: 8),
                                Text(
                                  'Ajouter • ${formatPrice(p.price * _qty)}',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
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
    );
  }
}
