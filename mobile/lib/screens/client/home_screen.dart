import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import 'client_shell.dart';
import 'product_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Category> _categories = [];
  List<Product> _products = [];
  AppSettings? _settings;
  Object? _error;
  bool _loading = true;
  int? _selectedCategory;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _products.isEmpty;
      _error = null;
    });
    try {
      final results = await Future.wait([
        Api.instance.categories(),
        Api.instance.products(),
        Api.instance.settings(),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = results[0] as List<Category>;
        _products = results[1] as List<Product>;
        _settings = results[2] as AppSettings;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  List<Product> get _filtered {
    final q = _query.toLowerCase();
    return _products.where((p) {
      if (_selectedCategory != null && p.categoryId != _selectedCategory) return false;
      if (q.isNotEmpty &&
          !p.name.toLowerCase().contains(q) &&
          !(p.description ?? '').toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return SafeArea(child: ErrorRetry(error: _error!, onRetry: _load));

    final popular = _products.where((p) => p.popular).toList();
    final filtered = _filtered;
    final showPopular = _selectedCategory == null && _query.isEmpty && popular.isNotEmpty;
    // Change quand le filtre change : relance l'animation d'apparition de la liste.
    final listKey = '$_selectedCategory|$_query';

    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _Header(userName: user?.name ?? '', settings: _settings)),
          SliverToBoxAdapter(
            child: Transform.translate(
              offset: const Offset(0, -26),
              child: FadeSlideIn(
                delay: const Duration(milliseconds: 150),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Material(
                    elevation: 6,
                    shadowColor: const Color(0x33A50E1E),
                    borderRadius: BorderRadius.circular(16),
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: 'Rechercher un plat...',
                        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.red),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: const BorderSide(color: AppColors.red, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Transform.translate(
              offset: const Offset(0, -14),
              child: SizedBox(
                height: 50,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _CategoryPill(
                      emoji: '🔥',
                      label: 'Tout',
                      selected: _selectedCategory == null,
                      onTap: () => setState(() => _selectedCategory = null),
                    ),
                    for (final (i, c) in _categories.indexed)
                      FadeSlideIn(
                        delay: FadeSlideIn.stagger(i + 1, stepMs: 60),
                        offset: const Offset(0.4, 0),
                        child: _CategoryPill(
                          emoji: categoryEmoji(c.icon),
                          label: c.name,
                          selected: _selectedCategory == c.id,
                          onTap: () => setState(() => _selectedCategory = c.id),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (showPopular) ...[
            const SliverToBoxAdapter(child: SectionTitle('Les plus demandés 🔥')),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 236,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  itemCount: popular.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (_, i) => FadeSlideIn(
                    delay: FadeSlideIn.stagger(i, stepMs: 80),
                    offset: const Offset(0.3, 0),
                    child: _PopularCard(product: popular[i]),
                  ),
                ),
              ),
            ),
          ],
          SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: SectionTitle(
                _query.isNotEmpty
                    ? 'Résultats (${filtered.length})'
                    : _selectedCategory == null
                        ? 'Notre menu'
                        : _categories.firstWhere((c) => c.id == _selectedCategory).name,
                key: ValueKey(listKey),
              ),
            ),
          ),
          if (filtered.isEmpty)
            const SliverToBoxAdapter(child: EmptyState(emoji: '🔍', title: 'Aucun plat trouvé'))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
              sliver: SliverList.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const SizedBox(height: 14),
                itemBuilder: (_, i) => FadeSlideIn(
                  key: ValueKey('$listKey-${filtered[i].id}'),
                  delay: FadeSlideIn.stagger(i),
                  child: _ProductTile(product: filtered[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String userName;
  final AppSettings? settings;
  const _Header({required this.userName, this.settings});

  @override
  Widget build(BuildContext context) {
    final firstName = userName.split(' ').first;
    final isOpen = settings?.isOpen ?? true;
    final cartCount = context.select<CartProvider, int>((c) => c.count);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.red, AppColors.darkRed],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Stack(
        children: [
          Positioned(top: -60, right: -40, child: _bubble(170)),
          Positioned(bottom: -30, left: 60, child: _bubble(90)),
          Padding(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + 14, 20, 46),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const AppLogo(size: 54),
                    const SizedBox(width: 14),
                    Expanded(
                      child: FadeSlideIn(
                        offset: const Offset(0.15, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Bonjour $firstName 👋', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                            const Text(
                              'Qu\'est-ce qui vous ferait plaisir ?',
                              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800, height: 1.25),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Material(
                      color: Colors.white.withValues(alpha: 0.18),
                      shape: const CircleBorder(),
                      child: IconButton(
                        onPressed: () => ClientShell.of(context)?.goTo(ClientShellState.cartTab),
                        icon: Badge(
                          isLabelVisible: cartCount > 0,
                          backgroundColor: AppColors.yellow,
                          textColor: AppColors.ink,
                          label: Text('$cartCount'),
                          child: BounceOnChange(
                            trigger: cartCount,
                            child: const Icon(Icons.shopping_bag_rounded, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 100),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _PulsingDot(color: isOpen ? const Color(0xFF6CF09A) : Colors.white54, animate: isOpen),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            isOpen
                                ? 'Ouvert • Livraison ${formatPrice(settings?.deliveryFee ?? 0)}'
                                : 'Fermé pour le moment',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.07)),
      );
}

class _PulsingDot extends StatefulWidget {
  final Color color;
  final bool animate;
  const _PulsingDot({required this.color, required this.animate});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 8 + 10 * _c.value,
              height: 8 + 10 * _c.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.5 * (1 - _c.value)),
              ),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryPill({required this.emoji, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.red : Colors.white,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: selected ? AppColors.red.withValues(alpha: 0.35) : Colors.black.withValues(alpha: 0.05),
                blurRadius: selected ? 12 : 6,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: selected ? 1.2 : 1,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutBack,
                child: Text(emoji, style: const TextStyle(fontSize: 15)),
              ),
              const SizedBox(width: 6),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 280),
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: selected ? Colors.white : AppColors.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PopularCard extends StatelessWidget {
  final Product product;
  const _PopularCard({required this.product});

  @override
  Widget build(BuildContext context) {
    final tag = 'popular-${product.id}';
    return Pressable(
      onTap: () => openProduct(context, product, heroTag: tag),
      child: SizedBox(
        width: 172,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Hero(tag: tag, child: ProductImage(url: product.imageUrl, height: 124, width: 172)),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: _AddButton(product: product, small: true),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, height: 1.25, fontSize: 13.5),
                    ),
                    const SizedBox(height: 6),
                    Price(product.price, size: 14),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final Product product;
  const _ProductTile({required this.product});

  @override
  Widget build(BuildContext context) {
    final tag = 'menu-${product.id}';
    return Pressable(
      onTap: () => openProduct(context, product, heroTag: tag),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Hero(
                tag: tag,
                child: ProductImage(
                  url: product.imageUrl,
                  width: 96,
                  height: 96,
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    if (product.description != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        product.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: Price(product.price, size: 15)),
                        _AddButton(product: product),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bouton « + » qui se transforme en sélecteur de quantité une fois l'article au panier.
class _AddButton extends StatelessWidget {
  final Product product;
  final bool small;
  const _AddButton({required this.product, this.small = false});

  @override
  Widget build(BuildContext context) {
    final qty = context.select<CartProvider, int>((c) => c.quantityOf(product.id));
    final cart = context.read<CartProvider>();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
      child: qty == 0 || small
          ? Material(
              key: const ValueKey('plus'),
              color: AppColors.red,
              shape: const CircleBorder(),
              elevation: small ? 3 : 0,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => cart.add(product),
                child: SizedBox(
                  width: small ? 34 : 38,
                  height: small ? 34 : 38,
                  child: small && qty > 0
                      ? Center(
                          child: Text('$qty',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                        )
                      : const Icon(Icons.add_rounded, color: Colors.white),
                ),
              ),
            )
          : QuantityStepper(
              key: const ValueKey('stepper'),
              compact: true,
              value: qty,
              onChanged: (v) => cart.setQuantity(product.id, v),
            ),
    );
  }
}
