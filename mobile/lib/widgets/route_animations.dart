import 'package:flutter/material.dart';

/// Custom route animations for Material 3 design
abstract class RouteAnimations {
  /// Fade transition (simple cross-fade)
  static Route<T> fadeRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 250),
    );
  }

  /// Slide transition from right (standard Material)
  static Route<T> slideRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        const begin = Offset(1, 0);
        const end = Offset.zero;
        final tween = Tween(begin: begin, end: end);
        final offsetAnimation = animation.drive(tween);
        return SlideTransition(position: offsetAnimation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 300),
    );
  }

  /// Slide transition from bottom (modal-like)
  static Route<T> slideUpRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        const begin = Offset(0, 1);
        const end = Offset.zero;
        final tween = Tween(begin: begin, end: end);
        final offsetAnimation = animation.drive(tween);
        return SlideTransition(position: offsetAnimation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 300),
    );
  }

  /// Slide and fade combined
  static Route<T> slideWithFadeRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        const begin = Offset(0.3, 0);
        const end = Offset.zero;
        final tween = Tween(begin: begin, end: end);
        final offsetAnimation = animation.drive(
          tween.chain(CurveTween(curve: Curves.easeOutCubic)),
        );
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offsetAnimation, child: child),
        );
      },
      transitionDuration: const Duration(milliseconds: 280),
    );
  }

  /// Scale transition with fade
  static Route<T> scaleRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        const begin = 0.0;
        const end = 1.0;
        final tween = Tween(begin: begin, end: end);
        final scaleAnimation = animation.drive(
          tween.chain(CurveTween(curve: Curves.easeOutCubic)),
        );
        return ScaleTransition(scale: scaleAnimation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 250),
    );
  }

  /// Rotation and scale transition
  static Route<T> rotateScaleRoute<T>(Widget page) {
    return PageRouteBuilder<T>(
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        return ScaleTransition(
          scale: animation,
          child: RotationTransition(
            turns: animation,
            child: child,
          ),
        );
      },
      transitionDuration: const Duration(milliseconds: 350),
    );
  }
}

/// Widget that applies shared axis transition (Material Design pattern)
class SharedAxisPageRoute<T> extends PageRouteBuilder<T> {
  SharedAxisPageRoute({
    required Widget Function(
      BuildContext,
      Animation<double>,
      Animation<double>,
    ) pageBuilder,
    bool barrierDismissible = false,
    Color? barrierColor,
    String? barrierLabel,
    Duration transitionDuration = const Duration(milliseconds: 300),
    Duration reverseTransitionDuration = const Duration(milliseconds: 300),
    RouteSettings? settings,
    String axis = 'vertical',
  }) : super(
    pageBuilder: (context, animation, secondaryAnimation) =>
        pageBuilder(context, animation, secondaryAnimation),
    transitionDuration: transitionDuration,
    reverseTransitionDuration: reverseTransitionDuration,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    settings: settings,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return _buildSharedAxisTransition(
        animation,
        secondaryAnimation,
        child,
        axis: axis,
      );
    },
  );

  static Widget _buildSharedAxisTransition(
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child, {
    required String axis,
  }) {
    final animation2 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: animation, curve: Curves.easeInOutCubic),
    );

    if (axis == 'vertical') {
      return FadeTransition(
        opacity: animation2,
        child: SlideTransition(
          position: animation.drive(
            Tween(begin: const Offset(0, 0.3), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeOutCubic)),
          ),
          child: child,
        ),
      );
    } else if (axis == 'horizontal') {
      return FadeTransition(
        opacity: animation2,
        child: SlideTransition(
          position: animation.drive(
            Tween(begin: const Offset(0.3, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeOutCubic)),
          ),
          child: child,
        ),
      );
    } else {
      return FadeTransition(
        opacity: animation2,
        child: child,
      );
    }
  }
}
