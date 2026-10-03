import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/animations.dart';
import '../../widgets/common.dart';
import 'product_form_screen.dart';

class AdminMenuScreen extends StatefulWidget {
  const AdminMenuScreen({super.key});

  @override
  State<AdminMenuScreen> createState() => _AdminMenuScreenState();
}

class _AdminMenuScreenState extends State<AdminMenuScreen> {
  List<Product>? _products;
  List<Category> _categories = [];
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [fresh] : ignore le cache (« tirer pour rafraîchir », après une modification).
  Future<void> _load({bool fresh = false}) async {
    try {
      final r = await Future.wait([
        Api.instance.products(all: true, fresh: fresh),
        Api.instance.categories(fresh: fresh),
      ]);
      if (!mounted) return;
      setState(() {
        _products = r[0] as List<Product>;
        _categories = r[1] as List<Category>;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _openProduct([Product? p]) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ProductFormScreen(product: p, categories: _categories)),
    );
    if (changed == true) _load(fresh: true);
  }

  Future<void> _toggle(Product p, bool available) async {
    try {
      final updated = await Api.instance.setProductAvailability(p.id, available);
      if (!mounted) return;
      setState(() => _products = _products!.map((x) => x.id == p.id ? updated : x).toList());
      showMessage(context, available ? '${p.name} est disponible' : '${p.name} est en rupture');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    }
  }

  Future<void> _editCategory([Category? c]) async {
    // Le champ de saisie appartient à la boîte de dialogue : libéré seulement à sa fermeture effective.
    final result = await showDialog<Category>(
      context: context,
      builder: (_) => _CategoryDialog(category: c, position: c?.position ?? _categories.length),
    );
    if (result == null) return;
    try {
      await Api.instance.saveCategory(result);
      await _load(fresh: true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    }
  }

  Future<void> _deleteCategory(Category c) async {
    final count = _products?.where((p) => p.categoryId == c.id).length ?? 0;
    final ok = await confirmDialog(
      context,
      'Supprimer « ${c.name} » ?',
      count > 0
          ? '$count produit(s) de cette catégorie deviendront « sans catégorie ».'
          : 'Cette catégorie sera supprimée.',
      confirm: 'Supprimer',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.deleteCategory(c.id);
      await _load(fresh: true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Builder(builder: (context) {
        final tab = DefaultTabController.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Gestion du menu'),
            bottom: const TabBar(
              labelStyle: TextStyle(fontWeight: FontWeight.w800),
              tabs: [Tab(text: 'Produits'), Tab(text: 'Catégories')],
            ),
          ),
          floatingActionButton: ListenableBuilder(
            listenable: tab,
            builder: (_, _) => FloatingActionButton.extended(
              backgroundColor: AppColors.red,
              foregroundColor: Colors.white,
              onPressed: () => tab.index == 0 ? _openProduct() : _editCategory(),
              icon: const Icon(Icons.add_rounded),
              label: Text(tab.index == 0 ? 'Produit' : 'Catégorie'),
            ),
          ),
          body: _products == null
              ? (_error != null
                  ? ErrorRetry(error: _error!, onRetry: () => _load(fresh: true))
                  : const Center(child: CircularProgressIndicator()))
              : TabBarView(children: [_productsTab(), _categoriesTab()]),
        );
      }),
    );
  }

  Widget _productsTab() {
    final products = _products!;
    final sections = <(String, List<Product>)>[
      for (final c in _categories)
        ('${categoryEmoji(c.icon)} ${c.name}', products.where((p) => p.categoryId == c.id).toList()),
      (
        'Sans catégorie',
        products.where((p) => p.categoryId == null || !_categories.any((c) => c.id == p.categoryId)).toList()
      ),
    ].where((s) => s.$2.isNotEmpty).toList();

    return RefreshIndicator(
      onRefresh: () => _load(fresh: true),
      child: products.isEmpty
          ? ListView(children: const [
              SizedBox(height: 80),
              EmptyState(emoji: '🍽️', title: 'Aucun produit', message: 'Ajoutez votre premier plat.'),
            ])
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                for (final s in sections) ...[
                  SectionTitle(s.$1),
                  for (final (i, p) in s.$2.indexed)
                    FadeSlideIn(
                      key: ValueKey('p-${p.id}'),
                      delay: FadeSlideIn.stagger(i),
                      child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _openProduct(p),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(
                              children: [
                                AnimatedOpacity(
                                  opacity: p.available ? 1 : 0.4,
                                  duration: const Duration(milliseconds: 300),
                                  child: ProductImage(
                                    url: p.imageUrl,
                                    width: 60,
                                    height: 60,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${p.popular ? '🔥 ' : ''}${p.name}',
                                        style: const TextStyle(fontWeight: FontWeight.w800),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(formatPrice(p.price), style: const TextStyle(color: AppColors.red)),
                                      if (!p.available)
                                        Text('Rupture de stock',
                                            style: TextStyle(
                                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                fontSize: 12)),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: p.available,
                                  activeTrackColor: AppColors.green,
                                  onChanged: (v) => _toggle(p, v),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _categoriesTab() {
    return RefreshIndicator(
      onRefresh: () => _load(fresh: true),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 96),
        itemCount: _categories.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final c = _categories[i];
          final count = _products!.where((p) => p.categoryId == c.id).length;
          return Card(
            child: ListTile(
              leading: Text(categoryEmoji(c.icon), style: const TextStyle(fontSize: 28)),
              title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text('$count produit${count > 1 ? 's' : ''}'),
              onTap: () => _editCategory(c),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.darkRed),
                onPressed: () => _deleteCategory(c),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Création / modification d'une catégorie (nom + icône).
class _CategoryDialog extends StatefulWidget {
  final Category? category;
  final int position;
  const _CategoryDialog({this.category, required this.position});

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.category?.name ?? '');
  late String? _icon = widget.category?.icon ?? 'chicken';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.category;
    return AlertDialog(
      title: Text(c == null ? 'Nouvelle catégorie' : 'Modifier la catégorie'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Nom'),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in categoryIcons.entries)
                ChoiceChip(
                  label: Text(e.value, style: const TextStyle(fontSize: 20)),
                  selected: _icon == e.key,
                  showCheckmark: false,
                  selectedColor: AppColors.yellow,
                  onSelected: (_) => setState(() => _icon = e.key),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(
              context,
              Category(id: c?.id ?? 0, name: name, icon: _icon, position: widget.position),
            );
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}
