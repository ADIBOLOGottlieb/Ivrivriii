# Ivrivrii Flutter Modernization Guide

This document describes the modernized UI components and design patterns implemented in the Ivrivrii app following Material 3 and latest Flutter best practices.

## 🎨 Theme System (theme.dart)

### Light & Dark Mode Support

The app now supports full Material 3 themes with light and dark modes:

```dart
// In MaterialApp
themeMode: themeProvider.themeMode, // ThemeMode.light, .dark, or .system
theme: buildLightTheme(),
darkTheme: buildDarkTheme(),
```

#### Color Palette

- **Primary**: Red (#D7182A) - Brand color from logo
- **Secondary**: Yellow (#FFB800) - Accent color
- **Tertiary**: Green (#2E9E5B) - Supporting color

All colors are automatically adapted for dark mode with proper contrast ratios (4.5:1 minimum WCAG AA).

### Theme Provider

Manage theme switching programmatically:

```dart
final themeProvider = context.read<ThemeProvider>();

// Toggle between light/dark
await themeProvider.toggleThemeMode();

// Set specific mode
await themeProvider.setThemeMode(ThemeMode.dark);

// Check if dark mode
bool isDark = themeProvider.isDarkMode;
```

---

## ✨ Animations (widgets/animations.dart)

### Basic Animations

#### FadeSlideIn
Combines fade and slide for list item animations:

```dart
FadeSlideIn(
  delay: Duration(milliseconds: 100),
  offset: Offset(0, 0.12),
  duration: Duration(milliseconds: 450),
  child: YourWidget(),
)
```

**Stagger effect for lists:**
```dart
for (var (i, item) in items.indexed)
  FadeSlideIn(
    delay: FadeSlideIn.stagger(i, stepMs: 55),
    child: ItemWidget(item),
  )
```

#### ScaleInTransition
Scale with fade animation:

```dart
ScaleInTransition(
  delay: Duration(milliseconds: 200),
  begin: 0.85, // Start scale
  curve: Curves.easeOutBack,
  child: YourWidget(),
)
```

#### Pressable
Scale feedback on tap (microinteraction):

```dart
Pressable(
  scale: 0.95,
  onTap: () => print('Tapped!'),
  child: Button(),
)
```

### Micro-Interactions

#### PulseAnimation
Loading indicator pulsing:

```dart
PulseAnimation(
  minOpacity: 0.4,
  duration: Duration(milliseconds: 1500),
  child: Icon(Icons.loading_animation),
)
```

#### FloatingAnimation
Smooth vertical floating effect:

```dart
FloatingAnimation(
  distance: 8,
  duration: Duration(milliseconds: 2000),
  child: YourWidget(),
)
```

#### WiggleAnimation
Attention-grabbing wiggle:

```dart
WiggleAnimation(
  duration: Duration(milliseconds: 400),
  child: WarningWidget(),
)
```

#### ShakeAnimation
Error state feedback:

```dart
ShakeAnimation(
  duration: Duration(milliseconds: 400),
  onEnd: () => print('Shake complete'),
  child: ErrorWidget(),
)
```

---

## 🔄 Route Animations (widgets/route_animations.dart)

### Page Transitions

Replace standard MaterialApp transitions:

```dart
// Fade
Navigator.of(context).push(RouteAnimations.fadeRoute(NextPage()));

// Slide from right
Navigator.of(context).push(RouteAnimations.slideRoute(NextPage()));

// Slide up (modal)
Navigator.of(context).push(RouteAnimations.slideUpRoute(NextPage()));

// Slide + Fade combined
Navigator.of(context).push(RouteAnimations.slideWithFadeRoute(NextPage()));

// Scale with fade
Navigator.of(context).push(RouteAnimations.scaleRoute(NextPage()));
```

### Custom Route Duration
All routes use Material 3 recommended durations (250-350ms).

---

## 💀 Skeleton Loaders (widgets/skeleton_loader.dart)

Show beautiful loading states instead of blank screens.

### Product Card Skeleton

```dart
// Show while loading products
if (isLoading) {
  GridView.builder(
    itemCount: 6,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
    ),
    itemBuilder: (_, __) => ProductCardSkeleton(),
  )
} else {
  // Show actual products
}
```

### Order Card Skeleton

```dart
if (isLoading) {
  ListView.builder(
    itemCount: 3,
    itemBuilder: (_, __) => OrderCardSkeleton(),
  )
} else {
  // Show orders
}
```

### Order Details Skeleton

```dart
if (isLoading) {
  OrderDetailsSkeleton()
} else {
  OrderDetailsView()
}
```

### Custom Skeleton Box

```dart
SkeletonBox(
  width: 200,
  height: 40,
  borderRadius: BorderRadius.circular(8),
)
```

**Shimmer Effect**: All skeletons include automatic shimmer animation for realistic feel.

---

## 🎭 Empty States (widgets/empty_states.dart)

### Enhanced Empty State

Attractive empty state with icon and animations:

```dart
EnhancedEmptyState(
  emoji: '🛍️',
  title: 'Your Cart is Empty',
  description: 'Browse our menu and add some items',
  iconColor: theme.colorScheme.primary,
  action: FilledButton(
    onPressed: () => navigateToMenu(),
    child: Text('Browse Menu'),
  ),
)
```

### No Items State

```dart
NoItemsState(
  emoji: '🛒',
  title: 'Empty Cart',
  description: 'Add items to your cart to get started',
  actionLabel: 'Browse Menu',
  onAction: () => navigateToMenu(),
)
```

### Error State

```dart
ErrorState(
  error: exception,
  onRetry: () => retryLoad(),
  title: 'Something Went Wrong',
)
```

### Network Error State

```dart
NetworkErrorState(
  onRetry: () => retryLoad(),
)
```

### No Results State

```dart
NoResultsState(
  query: 'chicken wings',
  onClear: () => clearSearch(),
)
```

### Unauthorized State

```dart
UnauthorizedState(
  message: 'You need to be logged in',
  actionLabel: 'Sign In',
  onAction: () => navigateToLogin(),
)
```

---

## 🎛️ Material 3 Components (widgets/material3_components.dart)

Pre-styled components following Material 3 design language.

### Card

```dart
Material3Card(
  padding: EdgeInsets.all(16),
  onTap: () => print('Tapped'),
  borderRadius: BorderRadius.circular(12),
  filled: true,
  child: Text('Content'),
)
```

**Outlined variant:**
```dart
Material3Card(
  outlined: true,
  child: Text('Outlined Card'),
)
```

### Button

```dart
Material3Button(
  label: 'Submit',
  onPressed: () => submit(),
  icon: Icons.check,
  fullWidth: true,
  minimumSize: Size.fromHeight(48),
)
```

**Loading state:**
```dart
Material3Button(
  label: 'Uploading...',
  onPressed: () {},
  isLoading: true,
)
```

### Chip

```dart
Material3Chip(
  label: 'Spicy',
  icon: Icons.local_fire_department,
  selected: isSpicy,
  onTap: () => toggleSpicy(),
)
```

### Text Field

```dart
Material3TextField(
  label: 'Email',
  hint: 'Enter your email',
  prefixIcon: Icons.email,
  keyboardType: TextInputType.emailAddress,
  onChanged: (value) => updateEmail(value),
  validator: (value) => validateEmail(value),
)
```

### Progress Indicator

```dart
// Linear progress
Material3ProgressIndicator(
  value: 0.65,
  label: 'Uploading (65%)',
  isLinear: true,
)

// Circular progress
Material3ProgressIndicator(
  value: 0.5, // null = indeterminate
)
```

### List Tile

```dart
Material3ListTile(
  title: 'Orders',
  subtitle: 'View your past orders',
  leading: Icons.receipt,
  onTap: () => navigateToOrders(),
)
```

### Badge

```dart
Material3Badge(
  count: 3,
  backgroundColor: theme.colorScheme.error,
  child: Icon(Icons.shopping_cart),
)
```

---

## ♿ Accessibility Guidelines

### Minimum Touch Target Size
All interactive elements are **48x48dp** (Material 3 standard):

```dart
FilledButton(
  style: FilledButton.styleFrom(
    minimumSize: Size.fromHeight(48), // Height minimum
  ),
  child: Text('Button'),
)
```

### Text Contrast
All text meets **4.5:1 WCAG AA** standard:

```dart
// ✅ Good contrast in light theme
Text(
  'Content',
  style: TextStyle(
    color: AppColors.ink, // Dark color on light background
  ),
)

// ✅ Automatic in dark theme via ColorScheme
Text(
  'Content',
  style: TextStyle(
    color: theme.colorScheme.onSurface,
  ),
)
```

### Semantic Labels
Use semantic labels for screen readers:

```dart
Semantics(
  label: 'Add to cart',
  button: true,
  enabled: true,
  child: IconButton(
    icon: Icon(Icons.add_shopping_cart),
    onPressed: () => addToCart(),
  ),
)
```

### Focus Navigation
Material widgets automatically support keyboard navigation. Test with:
- Tab key to navigate
- Enter/Space to activate
- Arrow keys in lists

---

## 📐 Spacing & Layout

### Material 3 Spacing Scale
- **Compact**: 8dp
- **Standard**: 16dp
- **Large**: 24dp
- **XLarge**: 32dp

```dart
// Good spacing hierarchy
Column(
  children: [
    Title(), // 16dp below
    SizedBox(height: 16),
    Subtitle(), // 8dp below
    SizedBox(height: 8),
    Description(),
  ],
)
```

### Border Radius
Consistent rounded corners for modern look:
- **Input/Cards**: 12-14px
- **Buttons**: 12px
- **Small elements**: 8px
- **Chips**: 20px (pill shape)

---

## 🌙 Dark Mode Checklist

When implementing new features:

- [ ] Use `theme.colorScheme` for all colors (not hardcoded)
- [ ] Test backgrounds in dark theme
- [ ] Check text contrast in dark mode
- [ ] Verify shadows render correctly (lighter in dark mode)
- [ ] Test images/graphics visibility
- [ ] Check status bar icons (light/dark)
- [ ] Verify loading indicators visibility
- [ ] Test all empty states in dark mode

---

## 📱 Responsive Design

### Breakpoints

```dart
// Tablet layout
if (MediaQuery.of(context).size.width > 600) {
  // Wide layout - 2+ columns
} else {
  // Mobile layout - 1 column
}
```

### Safe Area
Always use SafeArea for notched devices:

```dart
SafeArea(
  child: YourContent(),
)
```

---

## Performance Tips

1. **Skeleton Loaders**: Use instead of blank screens
2. **Animation Duration**: Keep 200-350ms for snappy feel
3. **Lazy Loading**: Use ListView.builder for long lists
4. **Image Loading**: Use ProductImage widget with fallbacks
5. **Providers**: Watch only needed data

---

## Testing Checklist

### Visual Testing
- [ ] Light theme appearance
- [ ] Dark theme appearance
- [ ] Animations smooth (60 FPS)
- [ ] Loading states visible
- [ ] Empty states attractive
- [ ] Error states helpful

### Accessibility Testing
- [ ] All buttons 48x48dp minimum
- [ ] Text contrast 4.5:1+
- [ ] Keyboard navigation works
- [ ] Screen reader friendly labels
- [ ] No flashing content (epilepsy safe)

### Device Testing
- [ ] Small phones (320px)
- [ ] Regular phones (375px)
- [ ] Large phones (414px+)
- [ ] Tablets (landscape)
- [ ] Dark mode enabled
- [ ] System settings respected

---

## Resources

- [Material Design 3](https://m3.material.io/)
- [Flutter Material Widgets](https://flutter.dev/docs/development/ui/widgets/material)
- [WCAG 2.1 Guidelines](https://www.w3.org/WAI/WCAG21/quickref/)
- [Flutter Accessibility](https://flutter.dev/docs/development/accessibility-and-localization/accessibility)
