import 'package:flutter/material.dart';
import 'animations.dart';

/// Enhanced empty state with better visuals and interactions
class EnhancedEmptyState extends StatelessWidget {
  final String emoji;
  final String title;
  final String? description;
  final Widget? action;
  final IconData? icon;
  final Color? iconColor;
  final double iconSize;

  const EnhancedEmptyState({
    super.key,
    required this.emoji,
    required this.title,
    this.description,
    this.action,
    this.icon,
    this.iconColor,
    this.iconSize = 80,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Animated icon
            ScaleInTransition(
              duration: const Duration(milliseconds: 500),
              begin: 0.5,
              curve: Curves.easeOutBack,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                ),
                child: Center(
                  child: icon != null
                      ? Icon(
                          icon,
                          size: iconSize,
                          color: iconColor ?? theme.colorScheme.primary,
                        )
                      : Text(
                          emoji,
                          style: TextStyle(fontSize: iconSize),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Title
            FadeSlideIn(
              delay: const Duration(milliseconds: 100),
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            // Description
            if (description != null) ...[
              const SizedBox(height: 12),
              FadeSlideIn(
                delay: const Duration(milliseconds: 150),
                child: Text(
                  description!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ],
            // Action button
            if (action != null) ...[
              const SizedBox(height: 24),
              FadeSlideIn(
                delay: const Duration(milliseconds: 200),
                child: action!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Empty state with illustration style
class EmptyStateWithIllustration extends StatelessWidget {
  final String emoji;
  final String title;
  final String? description;
  final VoidCallback? onRetry;
  final String? actionLabel;

  const EmptyStateWithIllustration({
    super.key,
    required this.emoji,
    required this.title,
    this.description,
    this.onRetry,
    this.actionLabel = 'Réessayer',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Large animated emoji
              FloatingAnimation(
                distance: 12,
                child: Text(
                  emoji,
                  style: const TextStyle(fontSize: 120),
                ),
              ),
              const SizedBox(height: 24),
              // Title with gradient
              FadeSlideIn(
                delay: const Duration(milliseconds: 100),
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              // Description
              if (description != null) ...[
                const SizedBox(height: 12),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 150),
                  child: Text(
                    description!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
              // Retry button
              if (onRetry != null) ...[
                const SizedBox(height: 32),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 200),
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(actionLabel ?? 'Réessayer'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(200, 48),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading error state with retry
class ErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  final String? title;

  const ErrorState({
    super.key,
    required this.error,
    required this.onRetry,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    return EnhancedEmptyState(
      emoji: '⚠️',
      icon: Icons.error_outline_rounded,
      iconColor: Theme.of(context).colorScheme.error,
      title: title ?? 'Une erreur est survenue',
      description: error is Exception ? error.toString() : 'Vérifiez votre connexion et réessayez',
      action: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Réessayer'),
      ),
    );
  }
}

/// No results/items found state
class NoResultsState extends StatelessWidget {
  final String query;
  final VoidCallback? onClear;

  const NoResultsState({
    super.key,
    required this.query,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return EnhancedEmptyState(
      emoji: '🔍',
      title: 'Aucun résultat',
      description: 'Aucun article ne correspond à « $query ».\nEssayez avec d\'autres mots-clés.',
      action: onClear != null
          ? FilledButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.clear_rounded),
              label: const Text('Effacer la recherche'),
            )
          : null,
    );
  }
}

/// No items state (empty cart, no orders, etc.)
class NoItemsState extends StatelessWidget {
  final String emoji;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback? onAction;

  const NoItemsState({
    super.key,
    required this.emoji,
    required this.title,
    required this.description,
    required this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return EnhancedEmptyState(
      emoji: emoji,
      title: title,
      description: description,
      action: onAction != null
          ? FilledButton(
              onPressed: onAction,
              child: Text(actionLabel),
            )
          : null,
    );
  }
}

/// Network error state with specific messaging
class NetworkErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const NetworkErrorState({
    super.key,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return EnhancedEmptyState(
      emoji: '📡',
      icon: Icons.wifi_off_rounded,
      iconColor: Theme.of(context).colorScheme.error,
      title: 'Pas de connexion',
      description: 'Vérifiez votre connexion Internet et réessayez.',
      action: FilledButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Réessayer'),
      ),
    );
  }
}

/// Unauthorized/Permission error state
class UnauthorizedState extends StatelessWidget {
  final String message;
  final VoidCallback onAction;
  final String actionLabel;

  const UnauthorizedState({
    super.key,
    required this.message,
    required this.onAction,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    return EnhancedEmptyState(
      emoji: '🔒',
      icon: Icons.lock_outline_rounded,
      iconColor: Theme.of(context).colorScheme.error,
      title: 'Accès refusé',
      description: message,
      action: FilledButton.icon(
        onPressed: onAction,
        icon: const Icon(Icons.login_rounded),
        label: Text(actionLabel),
      ),
    );
  }
}
