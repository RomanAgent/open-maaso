import 'dart:ui';

import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';

class AppLocalization {
  AppLocalization._();

  static Locale _locale = PlatformDispatcher.instance.locale;
  static final Map<String, Map<String, String>> _translations = {
    'en': enUS,
    'zh': zhCH,
  };

  static Locale get locale => _locale;

  static Locale get deviceLocale => PlatformDispatcher.instance.locale;

  /// Locales currently exposed by the app. A new language only needs a
  /// translation bundle registration and a Settings option.
  static List<Locale> get supportedLocales =>
      _translations.keys.map(_localeFromTag).toSet().toList(growable: false);

  static void registerTranslations(
    Locale locale,
    Map<String, String> translations,
  ) {
    final tag = locale.toLanguageTag().toLowerCase();
    _translations[tag] = Map.unmodifiable(translations);
  }

  static void updateLocale(Locale locale) {
    _locale = locale;
  }

  static String translate(String key) {
    final tag = _locale.toLanguageTag().toLowerCase();
    final languageCode = _locale.languageCode.toLowerCase();
    final values = _translations[tag] ?? _translations[languageCode] ?? enUS;
    return values[key] ?? enUS[key] ?? key;
  }

  static Locale _localeFromTag(String tag) {
    final parts = tag.replaceAll('_', '-').split('-');
    final languageCode = parts.first.toLowerCase();
    String? scriptCode;
    String? countryCode;
    for (final part in parts.skip(1)) {
      if (part.length == 4 && scriptCode == null) {
        scriptCode =
            '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}';
      } else if ((part.length == 2 || part.length == 3) &&
          countryCode == null) {
        countryCode = part.toUpperCase();
      }
    }
    return Locale.fromSubtags(
      languageCode: languageCode,
      scriptCode: scriptCode,
      countryCode: countryCode,
    );
  }
}

extension AppTranslationExtension on String {
  String get tr => AppLocalization.translate(this);

  String trParams(Map<String, String> params) {
    var translated = tr;
    for (final entry in params.entries) {
      translated = translated.replaceAll('@${entry.key}', entry.value);
    }
    return translated;
  }
}
