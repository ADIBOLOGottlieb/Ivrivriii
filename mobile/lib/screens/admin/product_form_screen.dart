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

  const ProductFormScreen({super.key, this.product, required this.categories});

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
  late bool _available = widget.product?.available ?? true;
  late bool _popular = widget.product?.popular ?? false;
  bool _saving = false;
  bool _uploading = false;

  bool get _isNew => widget.product == null;

  @override
  void initState() {
    super.initState();
    if (_categoryId != null && !widget.categories.any((c) => c.id == _categoryId)) _categoryId = null;
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
              onChanged: (v) => setState(() => _categoryId = v),
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
                    subtitle: const Text('Visible et commandable par les clients'),
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
}
