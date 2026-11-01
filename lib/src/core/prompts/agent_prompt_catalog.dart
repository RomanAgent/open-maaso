import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/bundles/app_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/app_prompts_zh.dart';
import 'package:maaso/src/core/prompts/bundles/legacy_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/legacy_prompts_zh.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/runtime_prompts_zh.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_en.dart';
import 'package:maaso/src/core/prompts/bundles/skill_prompts_zh.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

/// Locale-aware source of every fixed, model-visible prompt in the app.
///
/// Prompt resources deliberately live outside the UI translation maps. A
/// missing translated prompt is an error instead of silently falling back to
/// English and producing a mixed-language system message.
class AgentPromptCatalog {
  const AgentPromptCatalog._();

  static final Object _localeZoneKey = Object();

  static final Map<String, String> _en = Map.unmodifiable({
    ...runtimePromptsEn,
    ...appPromptsEn,
    ...legacyPromptsEn,
    ...skillPromptsEn,
  });

  static final Map<String, String> _zh = Map.unmodifiable({
    ...runtimePromptsZh,
    ...appPromptsZh,
    ...legacyPromptsZh,
    ...skillPromptsZh,
  });

  static AppLocale get currentLocale {
    final scoped = Zone.current[_localeZoneKey];
    if (scoped is AppLocale) return scoped;
    if (appServices.isRegistered<LocaleConfigService>()) {
      return appServices.find<LocaleConfigService>().resolvedAppLocale;
    }
    return _fromFlutterLocale(AppLocalization.deviceLocale);
  }

  /// Runs one Agent turn or tool execution with a stable locale.
  ///
  /// Async callbacks retain the Zone value across `await` boundaries, so
  /// host-owned Skill handlers cannot switch language halfway through a turn
  /// when the user changes the app locale concurrently.
  static R runWithLocale<R>(AppLocale locale, R Function() body) {
    final resolved = locale == AppLocale.system ? currentLocale : locale;
    return runZoned(
      body,
      zoneValues: <Object, Object>{_localeZoneKey: resolved},
    );
  }

  static String text(
    String key, {
    AppLocale? locale,
    Map<String, Object?> params = const <String, Object?>{},
  }) {
    final resolved = _resolve(locale ?? currentLocale);
    final values = resolved == AppLocale.zh ? _zh : _en;
    final template = values[key];
    if (template == null) {
      throw StateError('Missing ${resolved.code} Agent prompt resource: $key');
    }
    final placeholder = RegExp(r'@([A-Za-z][A-Za-z0-9_]*)');
    final missing = placeholder
        .allMatches(template)
        .map((match) => match.group(1)!)
        .where((name) => !params.containsKey(name))
        .toSet();
    if (missing.isNotEmpty) {
      throw StateError(
        'Missing Agent prompt parameters for $key: ${missing.join(', ')}',
      );
    }
    return template.replaceAllMapped(
      placeholder,
      (match) => '${params[match.group(1)!] ?? ''}',
    );
  }

  /// Returns a localized prompt when [key] exists in the selected bundle.
  ///
  /// This is reserved for author-extensible metadata such as third-party
  /// Skills. Built-in prompt keys must use [text] so missing translations fail
  /// closed instead of leaking a different language into the model context.
  static String? maybeText(
    String key, {
    AppLocale? locale,
    Map<String, Object?> params = const <String, Object?>{},
  }) {
    final resolved = _resolve(locale ?? currentLocale);
    final values = resolved == AppLocale.zh ? _zh : _en;
    if (!values.containsKey(key)) return null;
    return text(key, locale: resolved, params: params);
  }

  static Set<String> keysFor(AppLocale locale) =>
      Set.unmodifiable(_resolve(locale) == AppLocale.zh ? _zh.keys : _en.keys);

  static Map<String, String> resourcesFor(AppLocale locale) =>
      Map.unmodifiable(_resolve(locale) == AppLocale.zh ? _zh : _en);

  static AppLocale _resolve(AppLocale locale) {
    if (locale != AppLocale.system) return locale;
    if (appServices.isRegistered<LocaleConfigService>()) {
      return appServices.find<LocaleConfigService>().resolvedAppLocale;
    }
    return _fromFlutterLocale(AppLocalization.deviceLocale);
  }

  static AppLocale _fromFlutterLocale(Locale locale) =>
      locale.languageCode.toLowerCase().startsWith('zh')
      ? AppLocale.zh
      : AppLocale.en;
}
