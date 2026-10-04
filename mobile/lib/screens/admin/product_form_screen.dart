import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';

/// Création / modification d'un produit. Renvoie `true` si le menu a changé.
class ProductFormScreen extends StatefulWidget {
  final Product? product;
  final List<Category> categories;
  /// Catalogue complet (admin) pour composer un pack ; chargé ici s'il n'est pas fourni.
  final List<Product>? products;

  const ProductFormScreen({super.key, this.product, required this.categories, this.products});

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?.name ?? '');
  late final _description = TextEditingController(text: widget.product?.description ?? '');
  late final _price = TextEditingController(text: widget.product == null ? '' : '${widget.product!.price}');
  late final _imageUrl = TextEditingController(text: widget.product?.imageUrl ?? '');
  late int? _categoryId = widget.product?.categoryId ??
      (widget.categories.isNotEmpty ? widget.categories.first.id : null);
  // Pack : on édite l'interrupteur de l'admin, pas la disponibilité calculée avec ses plats.
  late bool _available = widget.product?.availableRaw ?? widget.product?.available ?? true;
  late bool _popular = widget.product?.popular ?? false;
  late bool _isPack = widget.product?.isPack ?? false;
  late final List<PackComponent> _packItems = [...?widget.product?.packItems];
  late List<Product>? _catalog = widget.products;
  bool _saving = false;
  bool _uploading = false;

  bool get _isNew => widget.product == null;

  @override
  void initState() {
    super.initState();
    if (_categoryId != null && !widget.categories.any((c) => c.id == _categoryId)) _categoryId = null;
    if (_isPacksCategory(_categoryId)) _isPack = true;
    if (_catalog == null) _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    try {
      final all = await Api.instance.products(all: true);
      if (mounted) setState(() => _catalog = all);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    }
  }

  bool _isPacksCategory(int? id) {
    final c = widget.categories.where((c) => c.id == id).firstOrNull;
    return c != null && c.name.trim().toLowerCase() == 'packs';
  }

  int? get _priceValue => int.tryParse(_price.text.replaceAll(RegExp(r'\s'), ''));

  Product? _catalogProduct(PackComponent c) => _catalog?.where((p) => p.id == c.productId).firstOrNull;
  String _componentName(PackComponent c) =>
      _catalogProduct(c)?.name ?? (c.name.isEmpty ? 'Plat n°${c.productId}' : c.name);
  // Prix et disponibilité actuels du catalogue ; ceux renvoyés avec le pack servent de repli.
  int _componentPrice(PackComponent c) => _catalogProduct(c)?.price ?? c.price;
  bool _componentAvailable(PackComponent c) => _catalogProduct(c)?.available ?? c.available;

  int get _packValue => _packItems.fold(0, (sum, c) => sum + _componentPrice(c) * c.quantity);

  void _setQuantity(int index, int qty) {
    final c = _packItems[index];
    setState(() => _packItems[index] = PackComponent(
        productId: c.productId, name: c.name, quantity: qty, price: c.price, available: c.available));
  }

  Future<void> _addComponent() async {
    final catalog = _catalog;
    if (catalog == null) {
      showMessage(context, 'Chargement du menu en cours…');
      return;
    }
    final choices = catalog.where((p) => !p.isPack && p.id != widget.product?.id).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final picked = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DishPicker(products: choices, included: {for (final c in _packItems) c.productId}),
    );
    if (picked == null || !mounted) return;
    final i = _packItems.indexWhere((c) => c.productId == picked.id);
    if (i >= 0) {
      if (_packItems[i].quantity < maxPackQuantity) _setQuantity(i, _packItems[i].quantity + 1);
      return;
    }
    setState(() => _packItems.add(PackComponent(
          productId: picked.id,
          name: picked.name,
          quantity: 1,
          price: picked.price,
          available: picked.available,
        )));
  }

  @override
  void dispose() {
    for (final c in [_name, _description, _price, _imageUrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, maxWidth: 1200, imageQuality: 82);
    if (picked == null) return;
    setState(() => _uploading = true);
    try {
      final url = await Api.instance.uploadImage(File(picked.path));
      if (mounted) setState(() => _imageUrl.text = url);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isPack && _packItems.isEmpty) {
      showMessage(context, "Ajoutez au moins un plat au pack, ou désactivez « C'est un pack ».", error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await Api.instance.saveProduct(Product(
        id: widget.product?.id ?? 0,
        categoryId: _categoryId,
        name: _name.text.trim(),
        description: _description.text.trim().isEmpty ? null : _description.text.trim(),
        price: int.parse(_price.text.replaceAll(RegExp(r'\s'), '')),
        imageUrl: _imageUrl.text.trim().isEmpty ? null : _imageUrl.text.trim(),
        available: _available,
        popular: _popular,
        // Interrupteur désactivé : liste vide, le produit redevient un plat simple.
        packItems: _isPack ? List.of(_packItems) : const [],
      ));
      if (!mounted) return;
      showMessage(context, _isNew ? 'Produit ajouté' : 'Produit mis à jour');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(
      context,
      'Supprimer ce produit ?',
      '« ${widget.product!.name} » sera retiré définitivement du menu. '
          'Astuce : désactivez-le plutôt s\'il est seulement en rupture.',
      confirm: 'Supprimer',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.deleteProduct(widget.product!.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Nouveau produit' : 'Modifier le produit'),
        actions: [
          if (!_isNew)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.darkRed),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Stack(
              children: [
                ValueListenableBuilder(
                  valueListenable: _imageUrl,
                  builder: (_, v, _) => ProductImage(
                    url: v.text,
                    height: 190,
                    width: double.infinity,
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                if (_uploading)
                  const Positioned.fill(child: Center(child: CircularProgressIndicator())),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Row(
                    children: [
                      IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: AppColors.ink),
                        onPressed: _uploading ? null : () => _pickImage(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_rounded),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: AppColors.red),
                        onPressed: _uploading ? null : () => _pickImage(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_rounded),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _imageUrl,
              decoration: const InputDecoration(
                labelText: "URL de l'image (ou choisissez une photo)",
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Nom du plat *'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Requis' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _description,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _price,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Prix *', suffixText: 'FCFA'),
              validator: (v) {
                final n = int.tryParse((v ?? '').replaceAll(RegExp(r'\s'), ''));
                return (n == null || n <= 0) ? 'Prix invalide' : null;
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<int?>(
              initialValue: _categoryId,
              decoration: const InputDecoration(labelText: 'Catégorie'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Sans catégorie')),
                for (final c in widget.categories)
                  DropdownMenuItem(value: c.id, child: Text('${categoryEmoji(c.icon)} ${c.name}')),
              ],
              onChanged: (v) => setState(() {
                _categoryId = v;
                if (_isPacksCategory(v)) _isPack = true;
              }),
            ),
            const SizedBox(height: 14),
            Card(
              child: SwitchListTile(
                value: _isPack,
                activeTrackColor: AppColors.green,
                onChanged: (v) => setState(() => _isPack = v),
                title: const Text("🍱 C'est un pack (plusieurs plats)"),
                subtitle: const Text('Menu composé de plats du catalogue, à prix réduit'),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _isPack ? _packSection(context) : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: 14),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _available,
                    activeTrackColor: AppColors.green,
                    onChanged: (v) => setState(() => _available = v),
                    title: const Text('Disponible'),
                    subtitle: Text(_isPack && widget.product?.packBlockedByComponent == true
                        ? 'Indisponible : un plat est épuisé. Le pack reviendra avec ce plat.'
                        : 'Visible et commandable par les clients'),
                  ),
                  SwitchListTile(
                    value: _popular,
                    onChanged: (v) => setState(() => _popular = v),
                    title: const Text('🔥 Mettre en avant'),
                    subtitle: const Text('Affiché dans « Les plus demandés »'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving || _uploading ? null : _save,
              child: _saving
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : Text(_isNew ? 'Ajouter au menu' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  /// Contenu du pack : plats inclus, quantités, valeur et économie en direct.
  Widget _packSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    final full = _packItems.length >= maxPackComponents;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Contenu du pack', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    ),
                    Text('${_packItems.length}/$maxPackComponents plats', style: muted),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              if (_packItems.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 8, 6),
                  child: Text('Aucun plat pour le moment. Ajoutez les plats inclus dans ce pack.', style: muted),
                ),
              for (final (i, c) in _packItems.indexed)
                Padding(
                  key: ValueKey('pack-${c.productId}'),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_componentName(c), style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              _componentAvailable(c)
                                  ? formatPrice(_componentPrice(c))
                                  : '${formatPrice(_componentPrice(c))} • épuisé',
                              style: TextStyle(
                                fontSize: 12,
                                color: _componentAvailable(c) ? scheme.onSurfaceVariant : scheme.error,
                              ),
                            ),
                          ],
                        ),
                      ),
                      QuantityStepper(
                        compact: true,
                        value: c.quantity,
                        min: 1,
                        max: maxPackQuantity,
                        onChanged: (v) => _setQuantity(i, v),
                      ),
                      IconButton(
                        tooltip: 'Retirer du pack',
                        onPressed: () => setState(() => _packItems.removeAt(i)),
                        icon: const Icon(Icons.close_rounded, color: AppColors.darkRed),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton.icon(
                  onPressed: full ? null : _addComponent,
                  icon: const Icon(Icons.add_rounded),
                  label: Text(full ? 'Maximum $maxPackComponents plats différents' : 'Ajouter un plat'),
                ),
              ),
              if (_packItems.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ListenableBuilder(listenable: _price, builder: (context, _) => _packTotals(context)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// « Valeur des plats », économie pour le client, ou avertissement si le pack n'est pas avantageux.
  Widget _packTotals(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = _packValue;
    final price = _priceValue;
    final hasPrice = price != null && price > 0;
    final savings = hasPrice ? value - price : 0;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Valeur des plats : ${formatPrice(value)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          if (hasPrice && savings > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Économie pour le client : ${formatPrice(savings)} (${(savings * 100 / value).round()} %)',
                style: TextStyle(fontWeight: FontWeight.w700, color: scheme.tertiary),
              ),
            ),
          if (hasPrice && savings <= 0)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.yellow.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: scheme.secondary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Le prix du pack est supérieur ou égal à la valeur des plats : '
                      'le client ne fait aucune économie.',
                      style: TextStyle(fontSize: 13, color: scheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Limites d'un pack (identiques au serveur) : plats différents, et quantité par plat.
const maxPackComponents = 10;
const maxPackQuantity = 20;

/// Liste des plats simples (packs exclus), avec recherche. Renvoie le plat choisi.
class _DishPicker extends StatefulWidget {
  final List<Product> products;
  final Set<int> included;
  const _DishPicker({required this.products, required this.included});

  @override
  State<_DishPicker> createState() => _DishPickerState();
}

class _DishPickerState extends State<_DishPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final list = widget.products.where((p) => q.isEmpty || p.name.toLowerCase().contains(q)).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          children: [
            const Text('Ajouter un plat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Rechercher un plat',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const EmptyState(emoji: '🔎', title: 'Aucun plat trouvé')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final p = list[i];
                        final inPack = widget.included.contains(p.id);
                        return ListTile(
                          leading: ProductImage(
                            url: p.imageUrl,
                            width: 44,
                            height: 44,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text(
                            [
                              formatPrice(p.price),
                              if (!p.available) 'épuisé',
                              if (inPack) 'déjà dans le pack (+1)',
                            ].join(' • '),
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          trailing: Icon(inPack ? Icons.add_circle_outline_rounded : Icons.add_rounded),
                          onTap: () => Navigator.pop(context, p),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
