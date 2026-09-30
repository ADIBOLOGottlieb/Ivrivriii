import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import '../widgets/animations.dart';

/// Écran d'onboarding animé. Appelé la première fois.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const OnboardingScreen({required this.onComplete, super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> with SingleTickerProviderStateMixin {
  late PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);
    if (mounted) widget.onComplete();
  }

  void _nextPage() {
    if (_currentPage < 3) {
      _pageController.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.easeInOut);
    } else {
      _markCompleted();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          PageView(
            controller: _pageController,
            onPageChanged: (i) => setState(() => _currentPage = i),
            children: [
              _OnboardingPage(
                emoji: '🍗',
                title: 'Bienvenue chez Ivrivrii',
                description: 'Dégustez les meilleures brochettes et poulets grillés de Lomé, livrés chauds à votre porte.',
              ),
              _OnboardingPage(
                emoji: '🔍',
                title: 'Explorez le menu',
                description: 'Parcourez nos plats délicieux en utilisant la barre de recherche. Filtrez par catégorie pour trouver rapidement ce que vous aimez.',
              ),
              _OnboardingPage(
                emoji: '📍',
                title: 'Indiquez votre position',
                description: 'Lors de la livraison, utilisez Google Maps pour localiser votre adresse précisément. Le livreur vous trouvera plus facilement !',
              ),
              _OnboardingPage(
                emoji: '💳',
                title: 'Payez facilement',
                description: 'Réglez vos commandes en espèces ou par mobile money (Flooz, Mixx by Yas). Frais de paiement appliqués seulement si nécessaire.',
              ),
            ],
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.white.withValues(alpha: 0.95)],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Dots indicateurs
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (int i = 0; i < 4; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              width: _currentPage == i ? 32 : 8,
                              height: 8,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: _currentPage == i ? AppColors.red : AppColors.muted.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      // Boutons
                      if (_currentPage < 3)
                        Row(
                          children: [
                            if (_currentPage > 0)
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => _pageController.previousPage(
                                    duration: const Duration(milliseconds: 400),
                                    curve: Curves.easeInOut,
                                  ),
                                  child: const Text('Précédent'),
                                ),
                              ),
                            if (_currentPage > 0) const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: _nextPage,
                                child: const Text('Suivant'),
                              ),
                            ),
                          ],
                        )
                      else
                        FilledButton(
                          onPressed: _nextPage,
                          child: const Text('Commencer à commander'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnboardingPage extends StatelessWidget {
  final String emoji;
  final String title;
  final String description;

  const _OnboardingPage({
    required this.emoji,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 60, 20, 200),
        child: FadeSlideIn(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 96)),
              const SizedBox(height: 32),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, height: 1.2),
              ),
              const SizedBox(height: 16),
              Text(
                description,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: AppColors.muted, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
