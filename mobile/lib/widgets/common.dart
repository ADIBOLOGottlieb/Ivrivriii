import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../config.dart';
import '../services/api.dart';
import '../theme.dart';
import '../utils/format.dart';

class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 120});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: ClipOval(child: Image.asset('assets/images/logo.jpg', fit: BoxFit.cover)),
    );
  }
}

class ProductImage extends StatelessWidget {
  final String? url;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  const ProductImage({super.key, this.url, this.width, this.height, this.borderRadius = BorderRadius.zero});

  @override
  Widget build(BuildContext context) {
    final resolved = resolveImageUrl(url);
    final placeholder = Container(
      width: width,
      height: height,
      color: AppColors.yellow.withValues(alpha: 0.18),
      alignment: Alignment.center,
      child: const Text('🍗', style: TextStyle(fontSize: 34)),
    );

    // Shimmer loading animation for better UX
    final shimmer = Container(
      width: width,
      height: height,
      color: AppColors.yellow.withValues(alpha: 0.1),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );

    return ClipRRect(
      borderRadius: borderRadius,
      child: resolved.isEmpty
          ? placeholder
          : CachedNetworkImage(
              imageUrl: resolved,
              width: width,
              height: height,
              fit: BoxFit.cover,
              placeholder: (context, url) => shimmer,
              errorWidget: (context, url, error) => placeholder,
              fadeInDuration: const Duration(milliseconds: 300),
              fadeOutDuration: const Duration(milliseconds: 300),
            ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String status;
  final bool delivery;
  const StatusChip({super.key, required this.status, this.delivery = true});

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon(status), size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            statusLabel(status, delivery: delivery),
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Sélecteur de quantité − / + . Un appui long sur le chiffre ouvre une saisie au clavier.
class QuantityStepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final bool compact;

  const QuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = maxQuantityPerItem,
    this.compact = false,
  });

  Future<void> _editValue(BuildContext context) async {
    final v = await showQuantityDialog(context, initial: value, min: min, max: max);
    if (v != null && v != value) onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = compact ? 30.0 : 40.0;
    // Bouton désactivé : voile de onSurface, visible sur toute surface claire ou sombre
    // (surfaceContainerHighest n'est pas défini dans le thème et retombe sur surface).
    final disabledBg = scheme.onSurface.withValues(alpha: 0.10);
    Widget btn(IconData icon, VoidCallback? onTap) => Material(
          color: onTap == null ? disabledBg : AppColors.red,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: onTap == null ? scheme.onSurfaceVariant : Colors.white, size: size * 0.55),
            ),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.remove_rounded, value > min ? () => onChanged(value - 1) : null),
        Semantics(
          button: true,
          hint: 'Appui long pour saisir la quantité',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => _editValue(context),
            // Largeur minimale, mais le chiffre peut s'élargir (jusqu'à 3 chiffres).
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: compact ? 32 : 44, minHeight: size),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Center(
                  widthFactor: 1,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: Text(
                      '$value',
                      key: ValueKey(value),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: compact ? 15 : 18,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        btn(Icons.add_rounded, value < max ? () => onChanged(value + 1) : null),
      ],
    );
  }
}

/// Saisie d'une quantité au clavier numérique. Renvoie null si l'utilisateur annule.
/// Si [min] vaut 0, la valeur 0 retire l'article.
Future<int?> showQuantityDialog(BuildContext context,
    {required int initial, int min = 1, int max = maxQuantityPerItem}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _QuantityDialog(initial: initial, min: min, max: max),
  );
}

class _QuantityDialog extends StatefulWidget {
  final int initial;
  final int min;
  final int max;
  const _QuantityDialog({required this.initial, required this.min, required this.max});

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.initial}');
    _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = parseQuantity(_ctrl.text, min: widget.min, max: widget.max);
    if (v == null) {
      setState(() => _error = 'Entrez un nombre entre ${widget.min} et ${widget.max}');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final digits = '${widget.max}'.length;
    return AlertDialog(
      title: const Text('Quantité'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(digits),
        ],
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        decoration: InputDecoration(
          helperText: widget.min == 0
              ? '0 pour retirer l\'article • maximum ${widget.max}'
              : 'De ${widget.min} à ${widget.max}',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: _submit,
          child: const Text('Valider'),
        ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  final String emoji;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({super.key, required this.emoji, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.elasticOut,
              builder: (_, v, child) => Transform.scale(scale: v, child: child),
              child: Text(emoji, style: const TextStyle(fontSize: 64)),
            ),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class ErrorRetry extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ErrorRetry({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      emoji: '😕',
      title: 'Oups !',
      message: error is ApiException ? error.toString() : 'Une erreur est survenue.',
      action: OutlinedButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Réessayer'),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          ?trailing,
        ],
      ),
    );
  }
}

void showMessage(BuildContext context, Object message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      // Erreur : blanc sur rouge foncé ; sinon couleurs « inverse » du thème (lisibles en clair et sombre).
      content: Text(message.toString(), style: error ? const TextStyle(color: Colors.white) : null),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? AppColors.darkRed : null,
    ));
}

Future<bool> confirmDialog(BuildContext context, String title, String message,
    {String confirm = 'Confirmer', bool danger = false}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: danger ? AppColors.darkRed : AppColors.red,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok ?? false;
}

class Price extends StatelessWidget {
  final int amount;
  final double size;
  /// Par défaut : rouge de la marque en clair, rouge clair (primary) en sombre pour rester lisible.
  final Color? color;
  const Price(this.amount, {super.key, this.size = 16, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = color ?? (theme.brightness == Brightness.dark ? theme.colorScheme.primary : AppColors.red);
    return Text(formatPrice(amount), style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: c));
  }
}

/// Pastille « Pack » d'un menu composé ; [savings] > 0 ajoute « −600 F » (économie pour le client).
class PackBadge extends StatelessWidget {
  final int savings;
  final bool small;
  const PackBadge({super.key, this.savings = 0, this.small = false});

  @override
  Widget build(BuildContext context) {
    final fontSize = small ? 10.5 : 12.0;
    final pad = EdgeInsets.symmetric(horizontal: small ? 7 : 9, vertical: small ? 2 : 3);
    // Couleurs fixes : fonds jaune / vert identiques en clair et en sombre, texte toujours lisible.
    Widget pill(String text, Color bg, Color fg) => Container(
          padding: pad,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
          child: Text(text, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, color: fg)),
        );
    return Wrap(
      spacing: 5,
      runSpacing: 4,
      children: [
        pill('🍱 Pack', AppColors.yellow, AppColors.ink),
        if (savings > 0) pill('−${formatPrice(savings)}', AppColors.green, Colors.white),
      ],
    );
  }
}

/// Contenu d'un pack, en petit sous le nom d'un article (« 1× Demi-poulet braisé, 1× Alloco »).
class ItemDetailsText extends StatelessWidget {
  final String text;
  final int? maxLines;
  final double fontSize;
  const ItemDetailsText(this.text, {super.key, this.maxLines = 2, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        height: 1.3,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
