import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages app theme mode (light, dark, system)
class ThemeProvider extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  /// Initialize theme from saved preferences
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString('theme_mode');

      if (savedMode != null) {
        _themeMode = ThemeMode.values.firstWhere(
          (mode) => mode.toString() == 'ThemeMode.$savedMode',
          orElse: () => ThemeMode.system,
        );
      }
    } catch (e) {
      debugPrint('Error loading theme preference: $e');
    }
    notifyListeners();
  }

  /// Set theme mode and persist to preferences
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode', mode.name);
    } catch (e) {
      debugPrint('Error saving theme preference: $e');
    }
  }

  /// Toggle between light and dark mode
  Future<void> toggleThemeMode() async {
    if (_themeMode == ThemeMode.light) {
      await setThemeMode(ThemeMode.dark);
    } else if (_themeMode == ThemeMode.dark) {
      await setThemeMode(ThemeMode.light);
    } else {
      // If system, switch to light
      await setThemeMode(ThemeMode.light);
    }
  }

  /// Check if using dark mode
  bool get isDarkMode {
    if (_themeMode == ThemeMode.dark) {
      return true;
    } else if (_themeMode == ThemeMode.light) {
      return false;
    } else {
      // System mode - check device brightness
      return WidgetsBinding.instance.window.platformDispatcher.views.first
              .mediumQuery?.platformData.platformBrightness ==
          Brightness.dark;
    }
  }
}
