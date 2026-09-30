import 'package:flutter/material.dart';

/// Enhanced card with better Material 3 styling
class Material3Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  final bool outlined;
  final bool filled;
  final Color? backgroundColor;
  final double elevation;

  const Material3Card({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
    this.outlined = false,
    this.filled = false,
    this.backgroundColor,
    this.elevation = 2,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (outlined) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.12),
            width: 1,
          ),
          borderRadius: borderRadius,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: borderRadius,
            child: Padding(padding: padding, child: child),
          ),
        ),
      );
    }

    return Card(
      elevation: onTap != null ? elevation + 1 : elevation,
      color: backgroundColor ?? (filled ? theme.colorScheme.surfaceVariant : theme.colorScheme.surface),
      shape: RoundedRectangleBorder(borderRadius: borderRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Elevated button with Material 3 styling
class Material3Button extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool isLoading;
  final bool fullWidth;
  final Size minimumSize;

  const Material3Button({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.isLoading = false,
    this.fullWidth = false,
    this.minimumSize = const Size.fromHeight(48),
  });

  @override
  Widget build(BuildContext context) {
    if (icon != null) {
      return FilledButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(
                    Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              )
            : Icon(icon),
        label: Text(label),
        style: FilledButton.styleFrom(
          minimumSize: fullWidth ? Size.fromHeight(minimumSize.height) : minimumSize,
        ),
      );
    }

    return FilledButton(
      onPressed: isLoading ? null : onPressed,
      style: FilledButton.styleFrom(
        minimumSize: fullWidth ? Size.fromHeight(minimumSize.height) : minimumSize,
      ),
      child: isLoading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(
                  Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            )
          : Text(label),
    );
  }
}

/// Chip with Material 3 styling
class Material3Chip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool selected;
  final Color? selectedColor;

  const Material3Chip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.selected = false,
    this.selectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (selected) {
      return FilterChip(
        label: Text(label),
        avatar: icon != null ? Icon(icon) : null,
        selected: true,
        onSelected: onTap != null ? (_) => onTap!() : null,
        backgroundColor: selectedColor ?? theme.colorScheme.primaryContainer,
        labelStyle: TextStyle(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return FilterChip(
      label: Text(label),
      avatar: icon != null ? Icon(icon) : null,
      onSelected: onTap != null ? (_) => onTap!() : null,
      backgroundColor: theme.colorScheme.surfaceVariant.withValues(alpha: 0.5),
    );
  }
}

/// Text input field with Material 3 styling
class Material3TextField extends StatefulWidget {
  final String? label;
  final String? hint;
  final ValueChanged<String> onChanged;
  final TextInputType keyboardType;
  final IconData? prefixIcon;
  final IconData? suffixIcon;
  final String? initialValue;
  final int? maxLines;
  final int? minLines;
  final bool obscureText;
  final String? Function(String?)? validator;

  const Material3TextField({
    super.key,
    this.label,
    this.hint,
    required this.onChanged,
    this.keyboardType = TextInputType.text,
    this.prefixIcon,
    this.suffixIcon,
    this.initialValue,
    this.maxLines = 1,
    this.minLines,
    this.obscureText = false,
    this.validator,
  });

  @override
  State<Material3TextField> createState() => _Material3TextFieldState();
}

class _Material3TextFieldState extends State<Material3TextField> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        prefixIcon: widget.prefixIcon != null ? Icon(widget.prefixIcon) : null,
        suffixIcon: widget.suffixIcon != null ? Icon(widget.suffixIcon) : null,
      ),
      keyboardType: widget.keyboardType,
      obscureText: widget.obscureText,
      maxLines: widget.obscureText ? 1 : widget.maxLines,
      minLines: widget.minLines,
      onChanged: widget.onChanged,
      validator: widget.validator,
    );
  }
}

/// Progress indicator with Material 3 styling
class Material3ProgressIndicator extends StatelessWidget {
  final double? value;
  final String? label;
  final bool isLinear;

  const Material3ProgressIndicator({
    super.key,
    this.value,
    this.label,
    this.isLinear = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (isLinear) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                label!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 8,
            ),
          ),
        ],
      );
    }

    return CircularProgressIndicator(value: value);
  }
}

/// Divider with Material 3 styling
class Material3Divider extends StatelessWidget {
  final EdgeInsets padding;
  final double thickness;

  const Material3Divider({
    super.key,
    this.padding = const EdgeInsets.symmetric(vertical: 16),
    this.thickness = 1,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Divider(
        thickness: thickness,
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
      ),
    );
  }
}

/// Badge widget for notifications
class Material3Badge extends StatelessWidget {
  final String? label;
  final int? count;
  final Widget child;
  final Color? backgroundColor;
  final Color? textColor;
  final Offset offset;

  const Material3Badge({
    super.key,
    this.label,
    this.count,
    required this.child,
    this.backgroundColor,
    this.textColor,
    this.offset = const Offset(0, 0),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final badgeColor = backgroundColor ?? theme.colorScheme.error;
    final textCol = textColor ?? theme.colorScheme.onError;

    return Badge(
      backgroundColor: badgeColor,
      textColor: textCol,
      label: Text(label ?? count.toString()),
      offset: offset,
      child: child,
    );
  }
}

/// List tile with Material 3 styling
class Material3ListTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  const Material3ListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      enabled: enabled,
      title: Text(
        title,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: enabled
              ? theme.colorScheme.onSurface
              : theme.colorScheme.onSurface.withValues(alpha: 0.38),
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      leading: leading != null
          ? Icon(
              leading,
              color: enabled
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface.withValues(alpha: 0.38),
            )
          : null,
      trailing: trailing,
      onTap: enabled ? onTap : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}
