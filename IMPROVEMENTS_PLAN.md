# 🚀 Plan d'Améliorations - Ivrivrii Chicken App

## Phase 1: CORRECTIONS CRITIQUES (Jour 1)

### 1. Fix Navigation Blocking Issues
**Priority:** 🔴 CRITIQUE

```dart
// ✅ AVANT: cart_screen.dart
shell?.goTo(ClientShellState.ordersTab);
Navigator.push(...);  // Race condition!

// ✅ APRÈS: Ajouter délai
ClientShell.of(context)?.goTo(ClientShellState.ordersTab);
await Future.delayed(const Duration(milliseconds: 300));
if (!context.mounted) return;
Navigator.push(...);  // Safe now
```

### 2. Fix Auth Error Handling
**Priority:** 🔴 CRITIQUE

```dart
// ❌ AVANT: auth_provider.dart
try {
  user = await Api.instance.me();
} on ApiException catch (e) {
  if (e.statusCode == 401) await _clear();
}
// ⚠️ initializing reste true si timeout!

// ✅ APRÈS:
try {
  user = await Api.instance.me();
} on ApiException catch (e) {
  if (e.statusCode == 401) await _clear();
} catch (e) {
  // Network error - keep initializing false
} finally {
  initializing = false;  // Always set this
  notifyListeners();
}
```

### 3. Add Retry Logic to API
**Priority:** 🔴 CRITIQUE

```dart
// ✅ NOUVEAU: services/api.dart
Future<dynamic> _send(Future<http.Response> Function() request, {int retries = 3}) async {
  for (int attempt = 0; attempt < retries; attempt++) {
    try {
      final res = await request().timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) return parseBody(res);
      if (res.statusCode == 401 && token != null) onUnauthorized?.call();
      if (res.statusCode >= 500 && attempt < retries - 1) {
        // Retry on server error
        await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
        continue;
      }
      throw ApiException(getErrorMessage(res), res.statusCode);
    } on SocketException catch (e) {
      if (attempt < retries - 1) {
        await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
        continue;
      }
      throw ApiException('No internet connection');
    }
  }
}
```

---

## Phase 2: AMÉLIORATIONS UI/UX (Jour 2-3)

### 4. Add Loading Skeletons
**Priority:** 🟠 HIGH

```dart
// ✅ NOUVEAU: widgets/skeleton.dart
class SkeletonCard extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Shimmer.fromColors(
        baseColor: Colors.grey[300]!,
        highlightColor: Colors.grey[100]!,
        child: Column(
          children: [
            Container(height: 150, color: Colors.grey),
            SizedBox(height: 12),
            Container(height: 20, width: double.infinity, color: Colors.grey),
            SizedBox(height: 8),
            Container(height: 20, width: 100, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

// Utilisation:
if (products == null) {
  return ListView(children: [
    for (int i = 0; i < 6; i++) SkeletonCard(),
  ]);
}
```

### 5. Improve Error Messages
**Priority:** 🟠 HIGH

```dart
// ❌ AVANT: Erreur générique
} catch (e) {
  showMessage(context, 'Erreur: $e', error: true);
}

// ✅ APRÈS: Messages spécifiques
} catch (e) {
  String message = 'Une erreur est survenue';
  if (e is SocketException) {
    message = '📡 Pas de connexion Internet\nVérifiez votre wifi ou données';
  } else if (e is TimeoutException) {
    message = '⏱️ Le serveur met trop de temps\nRéessayez dans quelques instants';
  } else if (e is ApiException) {
    if (e.statusCode == 401) {
      message = '🔐 Session expirée\nVeuillez vous reconnecter';
    } else if (e.statusCode == 409) {
      message = '⚠️ Cet article n\'existe plus\nRefreshd le menu';
    } else {
      message = e.message; // Custom from server
    }
  }
  showMessage(context, message, error: true);
}
```

### 6. Add Dark Mode Support
**Priority:** 🟡 MEDIUM

```dart
// ✅ NOUVEAU: theme.dart extension
class AppTheme {
  static ThemeData lightTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.red,
        brightness: Brightness.light,
      ),
      // ... rest of light theme
    );
  }

  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.red,
        brightness: Brightness.dark,
      ),
      // ... rest of dark theme
    );
  }
}

// main.dart:
MaterialApp(
  theme: AppTheme.lightTheme(),
  darkTheme: AppTheme.darkTheme(),
  themeMode: ThemeMode.system, // Use system setting
)
```

### 7. Add Image Caching
**Priority:** 🟡 MEDIUM

```dart
// ✅ INSTALLER: pubspec.yaml
cached_network_image: ^3.3.0

// ✅ UTILISER: widgets/common.dart
class ProductImage extends StatelessWidget {
  final String? url;
  const ProductImage({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url == null) return placeholderImage();
    return CachedNetworkImage(
      imageUrl: url!,
      placeholder: (context, url) => Shimmer(...),
      errorWidget: (context, url, error) => placeholderImage(),
      cacheManager: CacheManager(
        Config(
          'products_cache',
          stalePeriod: const Duration(days: 7),
          maxNrOfCacheObjects: 100,
        ),
      ),
    );
  }
}
```

---

## Phase 3: PERFORMANCES (Jour 3-4)

### 8. Add Pagination to Lists
**Priority:** 🟡 MEDIUM

```dart
// ✅ NOUVEAU: utils/pagination.dart
class PaginatedList<T> {
  final List<T> items;
  final bool hasMore;
  final int page;
  final int pageSize;
  
  int get totalLoaded => items.length;
  int get nextPage => page + 1;
}

// ✅ MODIFIER: orders_screen.dart
Future<void> _loadMore() async {
  if (_loading || !_hasMore) return;
  setState(() => _loading = true);
  try {
    final more = await Api.instance.myOrders(
      page: _page + 1,
      limit: 20,
    );
    if (mounted) {
      setState(() {
        _orders!.addAll(more);
        _hasMore = more.length == 20;
        _page++;
      });
    }
  } catch (e) {
    showMessage(context, e, error: true);
  } finally {
    if (mounted) setState(() => _loading = false);
  }
}
```

### 9. Optimize Build Performance
**Priority:** 🟡 MEDIUM

```dart
// ❌ AVANT: Rebuild inutiles
final cartCount = context.select<CartProvider, int>((c) => c.count);
return Scaffold(
  body: FadeIndexedStack(
    children: [
      HomeScreen(),  // Rebuild même si panier change!
      CartScreen(),
    ],
  ),
);

// ✅ APRÈS: Isoler les dépendances
return Scaffold(
  body: FadeIndexedStack(children: [
    const HomeScreen(),  // const = pas rebuild
    const CartScreen(),
  ]),
  // Badge du panier à part
  floatingActionButton: Consumer<CartProvider>(
    builder: (_, cart, __) => Badge(
      label: Text('${cart.count}'),
      child: Icon(...),
    ),
  ),
);
```

### 10. Reduce API Polling
**Priority:** 🟡 MEDIUM

```dart
// ❌ AVANT: Polling inutile toutes les 15s
_timer = Timer.periodic(const Duration(seconds: 15), (_) {
  if (_order != null && !_order!.isFinished) _load();
});

// ✅ APRÈS: Polling intelligent
_timer = Timer.periodic(const Duration(seconds: 30), (_) {
  // Vérifier seulement les commandes "preparing" ou "ready"
  if (_order != null && (_order!.status == 'preparing' || _order!.status == 'ready')) {
    _load();
  }
});

// Ou utiliser WebSocket:
_subscription = ApiSocket.orders.listen((update) {
  if (update.orderId == widget.orderId) {
    setState(() => _order = update.order);
  }
});
```

---

## Phase 4: MODERN DESIGN (Jour 4-5)

### 11. Enhance Visual Design
**Priority:** 💜 DESIGN

```dart
// ✅ NOUVEAU: Material 3 + Animations
// - Utiliser ColorScheme.fromSeed au lieu de couleurs fixes
// - Ajouter transitions 200-300ms entre écrans
// - Utiliser des courbes d'animation (easeInOutCubic, elasticOut)
// - Ajouter des micro-interactions (shake, bounce)

// Exemple:
FilledButton(
  onPressed: () {
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, animation, __) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: animation, child: NextPage()),
        ),
      ),
    );
  },
  child: Text('Continuer'),
)
```

### 12. Add Accessibility
**Priority:** 💜 DESIGN

```dart
// ✅ AJOUTER:
- Semantic tags sur tous les widgets interactifs
- Contrast ratio minimum 4.5:1 pour texte
- Taille minimum des touches: 48x48dp
- Labels descriptifs pour icônes
- Support lecteur d'écran

Semantics(
  label: 'Ajouter au panier',
  enabled: true,
  button: true,
  onTap: _addToCart,
  child: IconButton(...),
)
```

---

## Timeline d'Implémentation

| Phase | Durée | Tasks | Priority |
|-------|-------|-------|----------|
| 1 | 2-3h | Navigation, Auth, API Retry | 🔴 CRITICAL |
| 2 | 4-5h | Skeletons, Errors, Dark Mode, Caching | 🟠 HIGH |
| 3 | 3-4h | Pagination, Performance, Polling | 🟡 MEDIUM |
| 4 | 4-5h | Design Modern, Accessibility | 💜 DESIGN |
| **Total** | **~18h** | **Toutes corrections** | ✅ LIVRABLE |

---

## Métriques de Succès

- ✅ 0 crash sur 100 commandes
- ✅ Temps de réponse <1s même offline
- ✅ Pas de lag de navigation
- ✅ Support dark mode
- ✅ Images en cache
- ✅ Messages d'erreur clairs
- ✅ Accessibility score >85/100

---

**Prochaine Étape:** Attendre rapport d'analyse agent pour obtenir liste complète des bugs.
