import 'package:flutter/material.dart';

/// Apparition en fondu + glissement, avec un délai optionnel (effet « cascade »).
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final Offset offset;
  final Curve curve;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 450),
    this.offset = const Offset(0, 0.12),
    this.curve = Curves.easeOutCubic,
  });

  /// Délai en cascade pour le n-ième élément d'une liste, plafonné pour rester rapide.
  static Duration stagger(int index, {int stepMs = 55, int maxMs = 450}) =>
      Duration(milliseconds: (index * stepMs).clamp(0, maxMs));

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _curve = CurvedAnimation(parent: _c, curve: widget.curve);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween(begin: widget.offset, end: Offset.zero).animate(_curve),
        child: widget.child,
      ),
    );
  }
}

/// Enhanced scale transition with customizable curve and duration
class ScaleInTransition extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;
  final double begin;
  final Curve curve;

  const ScaleInTransition({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 400),
    this.begin = 0.85,
    this.curve = Curves.easeOutBack,
  });

  @override
  State<ScaleInTransition> createState() => _ScaleInTransitionState();
}

class _ScaleInTransitionState extends State<ScaleInTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _animation =
      CurvedAnimation(parent: _controller, curve: widget.curve);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween<double>(begin: widget.begin, end: 1).animate(_animation),
      child: FadeTransition(
        opacity: _animation,
        child: widget.child,
      ),
    );
  }
}

/// Réduit légèrement l'élément pendant l'appui, pour un retour tactile doux.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  const Pressable({super.key, required this.child, this.onTap, this.scale = 0.965});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Fait « rebondir » son enfant à chaque changement de [trigger] (ex : badge du panier).
class BounceOnChange extends StatefulWidget {
  final Object? trigger;
  final Widget child;
  const BounceOnChange({super.key, required this.trigger, required this.child});

  @override
  State<BounceOnChange> createState() => _BounceOnChangeState();
}

class _BounceOnChangeState extends State<BounceOnChange> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  late final Animation<double> _scale = TweenSequence([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.35, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)), weight: 65),
  ]).animate(_c);

  @override
  void didUpdateWidget(BounceOnChange old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(scale: _scale, child: widget.child);
}

/// Nombre qui défile de l'ancienne à la nouvelle valeur.
class AnimatedCount extends StatelessWidget {
  final int value;
  final String Function(int) format;
  final TextStyle? style;

  const AnimatedCount({super.key, required this.value, required this.format, this.style});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.toDouble()),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text(format(v.round()), style: style),
    );
  }
}

/// Comme IndexedStack (les onglets gardent leur état), avec un fondu + léger zoom
/// lors du changement d'onglet.
class FadeIndexedStack extends StatelessWidget {
  final int index;
  final List<Widget> children;

  const FadeIndexedStack({super.key, required this.index, required this.children});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < children.length; i++)
          IgnorePointer(
            ignoring: i != index,
            child: TickerMode(
              enabled: i == index,
              child: AnimatedOpacity(
                opacity: i == index ? 1 : 0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
                child: AnimatedScale(
                  scale: i == index ? 1 : 0.985,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOut,
                  child: ExcludeSemantics(excluding: i != index, child: children[i]),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Wiggle animation for attention-grabbing micro-interactions
class WiggleAnimation extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Offset offset;

  const WiggleAnimation({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.offset = const Offset(0.02, 0),
  });

  @override
  State<WiggleAnimation> createState() => _WiggleAnimationState();
}

class _WiggleAnimationState extends State<WiggleAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  late final Animation<double> _animation =
      Tween<double>(begin: 0, end: 1).animate(
    CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (_, child) {
        final wiggles = (_animation.value * 8).floor();
        final offset = (wiggles % 2 == 0 ? 1 : -1) * widget.offset.dx;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Pulse animation for loading indicators or attention
class PulseAnimation extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final double minOpacity;

  const PulseAnimation({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1500),
    this.minOpacity = 0.4,
  });

  @override
  State<PulseAnimation> createState() => _PulseAnimationState();
}

class _PulseAnimationState extends State<PulseAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: widget.minOpacity).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// Floating animation (smooth vertical movement)
class FloatingAnimation extends StatefulWidget {
  final Widget child;
  final double distance;
  final Duration duration;

  const FloatingAnimation({
    super.key,
    required this.child,
    this.distance = 8,
    this.duration = const Duration(milliseconds: 2000),
  });

  @override
  State<FloatingAnimation> createState() => _FloatingAnimationState();
}

class _FloatingAnimationState extends State<FloatingAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        return Transform.translate(
          offset: Offset(0, _controller.value * widget.distance - widget.distance / 2),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Shake animation for error states
class ShakeAnimation extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final VoidCallback? onEnd;

  const ShakeAnimation({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.onEnd,
  });

  @override
  State<ShakeAnimation> createState() => _ShakeAnimationState();
}

class _ShakeAnimationState extends State<ShakeAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward().then((_) {
      widget.onEnd?.call();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        final shakes = (_controller.value * 8).floor();
        final offset = (shakes % 2 == 0 ? 1 : -1) * 4.0;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Flip animation (3D card flip effect)
class FlipAnimation extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final bool autoFlip;

  const FlipAnimation({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 600),
    this.autoFlip = false,
  });

  @override
  State<FlipAnimation> createState() => _FlipAnimationState();
}

class _FlipAnimationState extends State<FlipAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    if (widget.autoFlip) {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void flip() {
    if (_controller.isAnimating) return;
    if (_controller.isDismissed) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: flip,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, child) {
          final angle = _controller.value * 3.14159;
          final transform = Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle);
          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
