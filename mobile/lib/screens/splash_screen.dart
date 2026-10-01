import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/animations.dart';
import '../widgets/common.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  // Le réveil du serveur peut durer jusqu'à une minute : on explique l'attente.
  late final Timer _slowTimer = Timer(const Duration(seconds: 4), () {
    if (mounted) setState(() => _slow = true);
  });
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _slowTimer; // Démarre le minuteur.
  }

  @override
  void dispose() {
    _slowTimer.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            colors: [AppColors.red, AppColors.darkRed],
            radius: 1.1,
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 260,
                height: 260,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Halo qui pulse derrière le logo.
                    AnimatedBuilder(
                      animation: _pulse,
                      builder: (_, _) => Container(
                        width: 170 + 90 * _pulse.value,
                        height: 170 + 90 * _pulse.value,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.18 * (1 - _pulse.value)),
                        ),
                      ),
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.3, end: 1),
                      duration: const Duration(milliseconds: 1100),
                      curve: Curves.elasticOut,
                      builder: (_, v, child) => Transform.scale(scale: v, child: child),
                      child: const AppLogo(size: 170),
                    ),
                  ],
                ),
              ),
              const FadeSlideIn(
                delay: Duration(milliseconds: 400),
                child: Text(
                  'Le goût qui fait chanter le coq !',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 28),
              AnimatedOpacity(
                opacity: _slow ? 1 : 0,
                duration: const Duration(milliseconds: 400),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      ),
                      SizedBox(height: 12),
                      Text(
                        "Connexion au serveur…\nAu premier lancement, cela peut prendre jusqu'à une minute.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
