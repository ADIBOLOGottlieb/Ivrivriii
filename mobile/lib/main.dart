import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/auth_provider.dart';
import 'providers/cart_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/admin/admin_shell.dart';
import 'screens/auth/login_screen.dart';
import 'screens/client/client_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';
import 'utils/cache_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize cache manager for image and data caching
  try {
    final cache = CacheManager();
    await cache.init();
  } catch (e) {
    // Cache initialization is not critical
    debugPrint('Cache init warning: $e');
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..init()),
        ChangeNotifierProvider(create: (_) => CartProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()..init()),
      ],
      child: const IvrivriiApp(),
    ),
  );
}

class IvrivriiApp extends StatelessWidget {
  const IvrivriiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (_, themeProvider, __) {
        return MaterialApp(
          title: 'Ivrivrii Chicken',
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: themeProvider.themeMode,
          home: const _Root(),
        );
      },
    );
  }
}

/// Aiguille vers l'onboarding, l'espace client ou admin selon le compte connecté.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool? _onboardingCompleted;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _onboardingCompleted = prefs.getBool('onboarding_completed') ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (_onboardingCompleted == null || auth.initializing) {
      return const SplashScreen();
    }

    if (_onboardingCompleted == false && auth.user != null && !auth.user!.isAdmin) {
      return OnboardingScreen(
        onComplete: () {
          if (mounted) setState(() => _onboardingCompleted = true);
        },
      );
    }

    final Widget child;
    if (auth.user == null) {
      child = const LoginScreen();
    } else if (auth.user!.isAdmin) {
      child = const AdminShell();
    } else {
      child = const ClientShell();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: KeyedSubtree(key: ValueKey(child.runtimeType), child: child),
    );
  }
}
