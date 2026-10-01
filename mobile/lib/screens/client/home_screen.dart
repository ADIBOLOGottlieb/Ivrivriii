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
  // Gardé ici : le texte tapé survit aux reconstructions de l'en-tête épinglé.
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String v) {
    if (v == _query) return;
    setState(() => _query = v);
  }

  void _clearQuery() {
    _searchCtrl.clear();
    _onQueryChanged('');
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
    final cartCount = context.select<CartProvider, int>((c) => c.count);
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
          SliverPersistentHeader(
            pinned: true,
            delegate: _HomeHeaderDelegate(
              topPadding: MediaQuery.paddingOf(context).top,
              firstName: (user?.name ?? '').trim().split(' ').first,
              isOpen: _settings?.isOpen ?? true,
              deliveryFee: _settings?.deliveryFee ?? 0,
              cartCount: cartCount,
              query: _query,
              scheme: Theme.of(context).colorScheme,
              controller: _searchCtrl,
              onChanged: _onQueryChanged,
              onClear: _clearQuery,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
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

/// En-tête épinglé de l'accueil : la bienvenue et le statut s'effacent au défilement,
/// la barre de recherche et le panier restent toujours visibles sur une bande rouge compacte.
class _HomeHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double topPadding;
  final String firstName;
  final bool isOpen;
  final int deliveryFee;
  final int cartCount;
  final String query;
  final ColorScheme scheme;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  _HomeHeaderDelegate({
    required this.topPadding,
    required this.firstName,
    required this.isOpen,
    required this.deliveryFee,
    required this.cartCount,
    required this.query,
    required this.scheme,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  // Positions verticales (hors encoche), en pixels logiques.
  static const double _rowTop = 14;
  static const double _rowHeight = 60;
  static const double _pillTop = 86;
  static const double _searchTopExpanded = 134;
  static const double _searchTopCollapsed = 8;
  static const double _searchHeight = 52;
  static const double _cartSize = 48;
  static const double _bottomExpanded = 18;
  static const double _bottomCollapsed = 10;
  static const double _side = 20;
  static const double _gap = 10;

  // Déplié : encoche + 204 ; replié : encoche + 70.
  @override
  double get maxExtent => topPadding + _searchTopExpanded + _searchHeight + _bottomExpanded;

  @override
  double get minExtent => topPadding + _searchTopCollapsed + _searchHeight + _bottomCollapsed;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = maxExtent - minExtent;
    final double t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    final double greetingOpacity = (1 - t * 1.6).clamp(0.0, 1.0);
    final double pillOpacity = (1 - t * 2.2).clamp(0.0, 1.0);

    final searchTop = topPadding + _lerp(_searchTopExpanded, _searchTopCollapsed, t);
    final searchRight = _lerp(_side, _side + _cartSize + _gap, t);
    final cartTop = topPadding +
        _lerp(
          _rowTop + (_rowHeight - _cartSize) / 2,
          _searchTopCollapsed + (_searchHeight - _cartSize) / 2,
          t,
        );
    final greeting = firstName.isEmpty ? 'Bonjour 👋' : 'Bonjour $firstName 👋';

    return SizedBox.expand(
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.red, AppColors.darkRed],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(_lerp(32, 24, t))),
        ),
        child: Stack(
          children: [
            Positioned(top: -60, right: -40, child: _bubble(170)),
            Positioned(bottom: -30, left: 60, child: _bubble(90)),
            // Logo + bienvenue (s'efface en fondu).
            Positioned(
              top: topPadding + _rowTop - shrinkOffset,
              left: _side,
              right: _side + _cartSize + _gap,
              child: IgnorePointer(
                ignoring: greetingOpacity == 0,
                child: Opacity(
                  opacity: greetingOpacity,
                  child: Row(
                    children: [
                      const AppLogo(size: 54),
                      const SizedBox(width: 14),
                      Expanded(
                        child: FadeSlideIn(
                          offset: const Offset(0.15, 0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                greeting,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                              const Text(
                                "Qu'est-ce qui vous ferait plaisir ?",
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Pastille Ouvert / Fermé (s'efface en fondu).
            Positioned(
              top: topPadding + _pillTop - shrinkOffset,
              left: _side,
              right: _side,
              child: IgnorePointer(
                child: Opacity(
                  opacity: pillOpacity,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FadeSlideIn(
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
                            _PulsingDot(
                              color: isOpen ? const Color(0xFF6CF09A) : Colors.white54,
                              animate: isOpen,
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                isOpen
                                    ? 'Ouvert • Livraison ${formatPrice(deliveryFee)}'
                                    : 'Fermé pour le moment',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
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
            // Barre de recherche (toujours visible).
            Positioned(
              top: searchTop,
              left: _side,
              right: searchRight,
              height: _searchHeight,
              child: Material(
                color: scheme.surface,
                elevation: 6,
                shadowColor: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: Center(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    textInputAction: TextInputAction.search,
                    cursorColor: AppColors.red,
                    style: TextStyle(color: scheme.onSurface, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Rechercher un plat...',
                      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
                      filled: false,
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      prefixIcon: const Icon(Icons.search_rounded, color: AppColors.red),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Effacer',
                              icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
                              onPressed: onClear,
                            ),
                    ),
                  ),
                ),
              ),
            ),
            // Bouton panier (toujours visible).
            Positioned(
              top: cartTop,
              right: _side,
              width: _cartSize,
              height: _cartSize,
              child: Material(
                color: Colors.white.withValues(alpha: 0.18),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Panier',
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.07)),
      );

  @override
  bool shouldRebuild(covariant _HomeHeaderDelegate oldDelegate) {
    return oldDelegate.topPadding != topPadding ||
        oldDelegate.firstName != firstName ||
        oldDelegate.isOpen != isOpen ||
        oldDelegate.deliveryFee != deliveryFee ||
        oldDelegate.cartCount != cartCount ||
        oldDelegate.query != query ||
        oldDelegate.scheme != scheme ||
        oldDelegate.controller != controller;
  }
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
            color: selected ? AppColors.red : Theme.of(context).colorScheme.surface,
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
                  color: selected ? Colors.white : Theme.of(context).colorScheme.onSurface,
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
