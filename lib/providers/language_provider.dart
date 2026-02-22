import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_translations.dart';

class LanguageProvider with ChangeNotifier {
  static const String _languageKey = 'app_language_code';

  // default to 'system'
  String _currentLanguageCode = 'system';

  // The actual resolved code based on system if 'system' is selected
  String _resolvedLanguageCode = 'en';

  String get currentLanguageCode => _currentLanguageCode;
  String get resolvedLanguageCode => _resolvedLanguageCode;

  LanguageProvider() {
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCode = prefs.getString(_languageKey);

    if (savedCode != null) {
      _currentLanguageCode = savedCode;
    } else {
      _currentLanguageCode = 'system';
    }

    _resolveSystemLanguage();
  }

  void _resolveSystemLanguage() {
    if (_currentLanguageCode == 'system') {
      if (!kIsWeb) {
        try {
          final platformLocaleName = Platform.localeName;
          final code = platformLocaleName.split('_').first;
          _resolvedLanguageCode = _isSupported(code) ? code : 'en';
        } catch (e) {
          _resolvedLanguageCode = 'en';
        }
      } else {
        _resolvedLanguageCode = 'en';
      }
    } else {
      _resolvedLanguageCode = _currentLanguageCode;
    }
    notifyListeners();
  }

  bool _isSupported(String code) {
    return ['en', 'it', 'es', 'fr', 'de'].contains(code);
  }

  Future<void> setLanguage(String languageCode) async {
    if (_currentLanguageCode == languageCode) return;

    _currentLanguageCode = languageCode;
    final prefs = await SharedPreferences.getInstance();

    if (languageCode == 'system') {
      await prefs.remove(_languageKey);
    } else {
      await prefs.setString(_languageKey, languageCode);
    }

    _resolveSystemLanguage();
  }

  String translate(String key) {
    return AppTranslations.translations[_resolvedLanguageCode]?[key] ??
        AppTranslations.translations['en']![key] ??
        key;
  }
}
