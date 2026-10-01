import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../../config.dart';
import '../../../models.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/account_api.dart';
import '../../../theme.dart';
import '../../../widgets/common.dart';

/// Photo de profil ronde, avec repli sur l'initiale du nom.
class UserAvatar extends StatelessWidget {
  final AppUser user;
  final double radius;

  const UserAvatar({super.key, required this.user, this.radius = 32});

  @override
  Widget build(BuildContext context) {
    final size = radius * 2;
    final initial = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: AppColors.red, shape: BoxShape.circle),
      child: Text(
        user.name.trim().isEmpty ? '?' : user.name.trim()[0].toUpperCase(),
        style: TextStyle(color: Colors.white, fontSize: radius * 0.8, fontWeight: FontWeight.w900),
      ),
    );
    final url = resolveImageUrl(user.avatarUrl);
    if (url.isEmpty) return initial;
    return ClipOval(
      child: Image.network(
        url,
        key: ValueKey(url),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => initial,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        },
      ),
    );
  }
}

/// Avatar cliquable : appareil photo, galerie ou suppression de la photo.
class EditableAvatar extends StatefulWidget {
  final AppUser user;
  final double radius;

  const EditableAvatar({super.key, required this.user, this.radius = 36});

  @override
  State<EditableAvatar> createState() => _EditableAvatarState();
}

class _EditableAvatarState extends State<EditableAvatar> {
  bool _busy = false;

  Future<void> _openActions() async {
    if (_busy) return;
    final hasPhoto = (widget.user.avatarUrl ?? '').isNotEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Photo de profil', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded, color: AppColors.red),
              title: const Text('Appareil photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded, color: AppColors.red),
              title: const Text('Galerie'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (hasPhoto)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: AppColors.darkRed),
                title: const Text('Supprimer la photo'),
                onTap: () => Navigator.pop(ctx, 'delete'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      await _delete();
    } else {
      await _pick(action == 'camera' ? ImageSource.camera : ImageSource.gallery);
    }
  }

  Future<void> _pick(ImageSource source) async {
    XFile? file;
    try {
      file = await ImagePicker().pickImage(source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 80);
    } on PlatformException catch (e) {
      if (mounted) {
        showMessage(
          context,
          e.code.contains('denied')
              ? 'Accès refusé : autorisez l\'appareil photo ou la galerie dans les réglages.'
              : 'Impossible d\'ouvrir ${source == ImageSource.camera ? 'l\'appareil photo' : 'la galerie'}.',
          error: true,
        );
      }
      return;
    }
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final original = await file.readAsBytes();
      Uint8List bytes;
      String filename;
      String subtype;
      try {
        bytes = await cropSquarePng(original);
        filename = 'avatar.png';
        subtype = 'png';
      } catch (_) {
        // Recadrage impossible : on envoie l'image déjà réduite par le sélecteur.
        bytes = original;
        final ext = file.name.split('.').last.toLowerCase();
        subtype = ext == 'png' ? 'png' : (ext == 'webp' ? 'webp' : 'jpeg');
        filename = 'avatar.${subtype == 'jpeg' ? 'jpg' : subtype}';
      }
      final user = await uploadAvatar(bytes, filename: filename, subtype: subtype);
      if (!mounted) return;
      context.read<AuthProvider>().setUser(user);
      showMessage(context, 'Photo de profil mise à jour');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    try {
      final user = await deleteAvatar();
      if (!mounted) return;
      context.read<AuthProvider>().setUser(user);
      showMessage(context, 'Photo supprimée');
    } catch (e) {
      if (mounted) showMessage(context, e, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = widget.radius * 2;
    return Semantics(
      button: true,
      label: 'Changer la photo de profil',
      child: GestureDetector(
        onTap: _openActions,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              UserAvatar(user: widget.user, radius: widget.radius),
              if (_busy)
                Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                  child: const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  ),
                ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: AppColors.red,
                    shape: BoxShape.circle,
                    border: Border.all(color: cs.surface, width: 2),
                  ),
                  child: const Icon(Icons.photo_camera_rounded, size: 15, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Recadre l'image au centre en carré (512 px max) et l'encode en PNG, sans dépendance
/// supplémentaire (dart:ui ne sait pas encoder en JPEG). Une photo 512×512 en PNG pèse
/// en général moins de 600 Ko, bien en dessous de la limite de 5 Mo du serveur.
Future<Uint8List> cropSquarePng(Uint8List bytes, {int size = 512}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final src = frame.image;
  try {
    final side = math.min(src.width, src.height);
    final out = math.min(size, side);
    final srcRect = Rect.fromLTWH(
      (src.width - side) / 2,
      (src.height - side) / 2,
      side.toDouble(),
      side.toDouble(),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      src,
      srcRect,
      Rect.fromLTWH(0, 0, out.toDouble(), out.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(out, out);
    picture.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('Encodage PNG impossible');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    src.dispose();
    codec.dispose();
  }
}
