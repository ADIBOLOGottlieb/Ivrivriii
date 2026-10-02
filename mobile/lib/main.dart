import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/auth_provider.dart';
import 'providers/cart_provider.dart';
import 'providers/theme_provider.dart';
import 'screens/admin/admin_shell.dart';
import 'screens/auth/login_screen.dart';
import 'screens/client/client_shell.dart';
import 'screens/driver/driver_shell.dart';
import 'screens/onboarding_screen.dart';
import 'screens/splash_screen.dart';
import 'services/maps_link.dart';
import 'services/shared_location.dart';
import 'theme.dart';
import 'utils/cache_manager.dart';

/// Messager global : messages affichés hors de tout écran précis (ex. position partagée depuis Google Maps).
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Réception des positions partagées depuis l'app Google Maps (sans bloquer le démarrage).
  unawaited(SharedLocationService.instance.init().catchError((Object e) {
    debugPrint('Partage Google Maps indisponible : $e');
  }));

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
      builder: (_, themeProvider, _) {
        return MaterialApp(
          title: 'Ivrivrii Chicken',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: scaffoldMessengerKey,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: themeProvider.themeMode,
          // Calendriers, sélecteurs et textes système en français.
          locale: const Locale('fr'),
          supportedLocales: const [Locale('fr')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const _Root(),
        );
      },
    );
  }
}

/// Aiguille vers l'onboarding, l'espace client, livreur ou admin selon le compte connecté.
class _Root extends StatefulWidget {
  const _Root();

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  bool? _onboardingCompleted;

  final _shared = SharedLocationService.instance;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    _shared.pending.addListener(_onSharedLocation);
    _shared.failure.addListener(_onSharedFailure);
    if (_shared.pending.value != null) _onSharedLocation();
    if (_shared.failure.value != null) _onSharedFailure();
  }

  @override
  void dispose() {
    _shared.pending.removeListener(_onSharedLocation);
    _shared.failure.removeListener(_onSharedFailure);
    super.dispose();
  }

  /// Position reçue de Google Maps : si aucun écran (commande) ne l'a utilisée dans la seconde,
  /// on prévient le client qu'elle servira pour sa prochaine commande.
  void _onSharedLocation() {
    final ImportedLocation? received = _shared.pending.value;
    if (received == null) return;
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || !identical(_shared.pending.value, received)) return;
      final user = context.read<AuthProvider>().user;
      final String message;
      if (user != null && (user.isAdmin || user.isDriver)) {
        // Livreur / admin : message neutre, la position n'est pas gardée.
        _shared.consume();
        message = 'Position Google Maps reçue : elle ne sert que pour les commandes clients.';
      } else {
        message = '📍 Position reçue de Google Maps : elle sera utilisée pour votre prochaine commande';
      }
      _showMessage(message);
    });
  }

  void _onSharedFailure() {
    final message = _shared.failure.value;
    if (message == null) return;
    _showMessage(message);
  }

  void _showMessage(String message) {
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
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

    // Onboarding réservé aux clients (ni admin ni livreur).
    if (_onboardingCompleted == false && auth.user != null && !auth.user!.isAdmin && !auth.user!.isDriver) {
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
    } else if (auth.user!.isDriver) {
      child = const DriverShell();
    } else {
      child = const ClientShell();
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      child: KeyedSubtree(key: ValueKey(child.runtimeType), child: child),
    );
  }
}
