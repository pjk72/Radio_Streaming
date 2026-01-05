import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';

class ThemePreset {
  final String id;
  final String name;
  final Brightness brightness;
  final Color primaryColor;
  final Color secondaryColor;
  final Color backgroundColor;
  final Color surfaceColor;
  final Color cardColor;

  const ThemePreset({
    required this.id,
    required this.name,
    required this.brightness,
    required this.primaryColor,
    required this.secondaryColor,
    required this.backgroundColor,
    required this.surfaceColor,
    required this.cardColor,
  });
}

class ThemeProvider with ChangeNotifier {
  static const String _keyThemeId = 'theme_id';

  // --- Predefined Dark Themes ---
  static const ThemePreset _darkDefault = ThemePreset(
    id: 'dark_default',
    name: 'Cosmic Purple',
    brightness: Brightness.dark,
    primaryColor: Color(0xFF6c5ce7),
    secondaryColor: Color(0xFFa29bfe),
    backgroundColor: Color(0xFF0a0a0f),
    surfaceColor: Color(0xFF13131f),
    cardColor: Color(0xFF1e1e2e),
  );

  static const ThemePreset _darkOcean = ThemePreset(
    id: 'dark_ocean',
    name: 'Abyssal Blue',
    brightness: Brightness.dark,
    primaryColor: Color(0xFF0984e3),
    secondaryColor: Color(0xFF74b9ff),
    backgroundColor: Color(0xFF05101a),
    surfaceColor: Color(0xFF0a1929),
    cardColor: Color(0xFF102840),
  );

  static const ThemePreset _darkForest = ThemePreset(
    id: 'dark_forest',
    name: 'Deep Forest',
    brightness: Brightness.dark,
    primaryColor: Color(0xFF00b894),
    secondaryColor: Color(0xFF55efc4),
    backgroundColor: Color(0xFF0b140e),
    surfaceColor: Color(0xFF112217),
    cardColor: Color(0xFF1a3324),
  );

  static const ThemePreset _darkCrimson = ThemePreset(
    id: 'dark_crimson',
    name: 'Crimson Night',
    brightness: Brightness.dark,
    primaryColor: Color(0xFFd63031),
    secondaryColor: Color(0xFFff7675),
    backgroundColor: Color(0xFF120404),
    surfaceColor: Color(0xFF210808),
    cardColor: Color(0xFF330c0c),
  );

  static const ThemePreset _darkOled = ThemePreset(
    id: 'dark_oled',
    name: 'True Black',
    brightness: Brightness.dark,
    primaryColor: Color(0xFFffffff),
    secondaryColor: Color(0xFFb2bec3),
    backgroundColor: Color(0xFF000000),
    surfaceColor: Color(0xFF111111),
    cardColor: Color(0xFF1e1e1e),
  );

  static const ThemePreset _darkMidnight = ThemePreset(
    id: 'dark_midnight',
    name: 'Midnight Blue',
    brightness: Brightness.dark,
    primaryColor: Color(0xFF341f97),
    secondaryColor: Color(0xFF5f27cd),
    backgroundColor: Color(0xFF130f40),
    surfaceColor: Color(0xFF30336b),
    cardColor: Color(0xFF130f40),
  );

  static const ThemePreset _darkSunset = ThemePreset(
    id: 'dark_sunset',
    name: 'Dark Sunset',
    brightness: Brightness.dark,
    primaryColor: Color(0xFFff9f43),
    secondaryColor: Color(0xFFfeca57),
    backgroundColor: Color(0xFF222f3e),
    surfaceColor: Color(0xFF2f3542),
    cardColor: Color(0xFF57606f),
  );

  // --- Predefined Light Themes ---
  static const ThemePreset _lightDefault = ThemePreset(
    id: 'light_default',
    name: 'Clean Lilac',
    brightness: Brightness.light,
    primaryColor: Color(0xFF6c5ce7),
    secondaryColor: Color(0xFFa29bfe),
    backgroundColor: Color(0xFFf5f6fa),
    surfaceColor: Color(0xFFffffff),
    cardColor: Color(0xFFffffff),
  );

  static const ThemePreset _lightSky = ThemePreset(
    id: 'light_sky',
    name: 'Morning Sky',
    brightness: Brightness.light,
    primaryColor: Color(0xFF0984e3),
    secondaryColor: Color(0xFF74b9ff),
    backgroundColor: Color(0xFFeaf6ff),
    surfaceColor: Color(0xFFffffff),
    cardColor: Color(0xFFf0f9ff),
  );

  static const ThemePreset _lightMint = ThemePreset(
    id: 'light_mint',
    name: 'Fresh Mint',
    brightness: Brightness.light,
    primaryColor: Color(0xFF00b894),
    secondaryColor: Color(0xFF55efc4),
    backgroundColor: Color(0xFFedfffa),
    surfaceColor: Color(0xFFffffff),
    cardColor: Color(0xFFf5fffa),
  );

  static const ThemePreset _lightSunset = ThemePreset(
    id: 'light_sunset',
    name: 'Warm Sunset',
    brightness: Brightness.light,
    primaryColor: Color(0xFFe17055),
    secondaryColor: Color(0xFFfab1a0),
    backgroundColor: Color(0xFFfff5f2),
    surfaceColor: Color(0xFFffffff),
    cardColor: Color(0xFFfff9f7),
  );

  static const ThemePreset _lightRose = ThemePreset(
    id: 'light_rose',
    name: 'Soft Rose',
    brightness: Brightness.light,
    primaryColor: Color(0xFFe84393),
    secondaryColor: Color(0xFFfd79a8),
    backgroundColor: Color(0xFFfff0f6),
    surfaceColor: Color(0xFFffffff),
    cardColor: Color(0xFFfff0f5),
  );

  static const ThemePreset _lightLavender = ThemePreset(
    id: 'light_lavender',
    name: 'Lavender Mist',
    brightness: Brightness.light,
    primaryColor: Color(0xFF8e44ad),
    secondaryColor: Color(0xFF9b59b6),
    backgroundColor: Color(0xFFfcf4ff),
    surfaceColor: Color(0xFFffffff),
    cardColor: Color(0xFFf8f0ff),
  );

  final List<ThemePreset> _presets = [
    _darkDefault,
    _darkOcean,
    _darkForest,
    _darkCrimson,
    _darkOled,
    _darkMidnight,
    _darkSunset,
    _lightDefault,
    _lightSky,
    _lightMint,
    _lightSunset,
    _lightRose,
    _lightLavender,
  ];

  ThemePreset _currentPreset = _darkDefault;

  // Custom Overrides
  Color? _customPrimaryColor;
  Color? _customBackgroundColor;
  Color? _customCardColor;
  Color? _customSurfaceColor;

  ThemePreset get currentPreset => _currentPreset;
  List<ThemePreset> get presets => [..._presets];

  // Helper getters to filter by brightness for the UI
  List<ThemePreset> get darkPresets =>
      _presets.where((p) => p.brightness == Brightness.dark).toList();
  List<ThemePreset> get lightPresets =>
      _presets.where((p) => p.brightness == Brightness.light).toList();

  // Getters for current active colors (either custom or preset)
  Color get activePrimaryColor =>
      _customPrimaryColor ?? _currentPreset.primaryColor;
  Color get activeBackgroundColor =>
      _customBackgroundColor ?? _currentPreset.backgroundColor;
  Color get activeCardColor => _customCardColor ?? _currentPreset.cardColor;
  Color get activeSurfaceColor =>
      _customSurfaceColor ?? _currentPreset.surfaceColor;

  bool get hasCustomColors =>
      _customPrimaryColor != null ||
      _customBackgroundColor != null ||
      _customCardColor != null ||
      _customSurfaceColor != null;

  ThemeProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final themeId = prefs.getString(_keyThemeId);

    if (themeId != null) {
      _currentPreset = _presets.firstWhere(
        (p) => p.id == themeId,
        orElse: () => _darkDefault,
      );
    }

    // Load custom overrides
    final int? primary = prefs.getInt('custom_primary');
    if (primary != null) _customPrimaryColor = Color(primary);

    final int? bg = prefs.getInt('custom_bg');
    if (bg != null) _customBackgroundColor = Color(bg);

    final int? card = prefs.getInt('custom_card');
    if (card != null) _customCardColor = Color(card);

    final int? surface = prefs.getInt('custom_surface');
    if (surface != null) _customSurfaceColor = Color(surface);

    notifyListeners();
  }

  Future<void> setPreset(String id) async {
    _currentPreset = _presets.firstWhere(
      (p) => p.id == id,
      orElse: () => _currentPreset,
    );
    // Setting a preset clears custom overrides usually, but user might want to keep them?
    // "Modify manually the colors that are normally modified by the palettes" suggests overriding the palette.
    // Usually picking a palette resets the base.
    _customPrimaryColor = null;
    _customBackgroundColor = null;
    _customCardColor = null;
    _customSurfaceColor = null;

    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeId, id);

    // Clear custom prefs
    await prefs.remove('custom_primary');
    await prefs.remove('custom_bg');
    await prefs.remove('custom_card');
    await prefs.remove('custom_surface');
  }

  Future<void> setCustomPrimaryColor(Color color) async {
    _customPrimaryColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('custom_primary', color.value);
  }

  Future<void> setCustomBackgroundColor(Color color) async {
    _customBackgroundColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('custom_bg', color.value);
  }

  Future<void> setCustomCardColor(Color color) async {
    _customCardColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('custom_card', color.value);
  }

  Future<void> setCustomSurfaceColor(Color color) async {
    _customSurfaceColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('custom_surface', color.value);
  }

  Future<void> resetCustomColors() async {
    _customPrimaryColor = null;
    _customBackgroundColor = null;
    _customCardColor = null;
    _customSurfaceColor = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('custom_primary');
    await prefs.remove('custom_bg');
    await prefs.remove('custom_card');
    await prefs.remove('custom_surface');
  }

  // Generate ThemeData from the current preset
  ThemeData get themeData {
    final effectivePrimary = activePrimaryColor;
    final effectiveBg = activeBackgroundColor;
    final effectiveSurface = activeSurfaceColor;
    final effectiveCard = activeCardColor;

    return ThemeData(
      brightness: _currentPreset.brightness,
      scaffoldBackgroundColor: effectiveBg,
      primaryColor: effectivePrimary,
      canvasColor: effectiveSurface, // Sidebar/Drawer color
      cardColor: effectiveCard,

      colorScheme: ColorScheme(
        brightness: _currentPreset.brightness,
        primary: effectivePrimary,
        onPrimary: _currentPreset.brightness == Brightness.dark
            ? Colors.black
            : Colors.white,
        secondary: _currentPreset
            .secondaryColor, // Secondary might clash if primary changes, but acceptable for now
        onSecondary: Colors.black,
        error: Colors.redAccent,
        onError: Colors.white,
        surface: effectiveSurface,
        onSurface: _currentPreset.brightness == Brightness.dark
            ? Colors.white
            : Colors.black87,
      ),

      textTheme:
          GoogleFonts.interTextTheme(
            ThemeData(brightness: _currentPreset.brightness).textTheme,
          ).apply(
            bodyColor: _currentPreset.brightness == Brightness.dark
                ? Colors.white
                : Colors.black87,
            displayColor: _currentPreset.brightness == Brightness.dark
                ? Colors.white
                : Colors.black87,
          ),

      appBarTheme: AppBarTheme(
        backgroundColor: effectiveSurface,
        foregroundColor: _currentPreset.brightness == Brightness.dark
            ? Colors.white
            : Colors.black87,
        elevation: 0,
      ),

      cardTheme: CardThemeData(
        color: effectiveCard,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),

      useMaterial3: true,
    );
  }
}
