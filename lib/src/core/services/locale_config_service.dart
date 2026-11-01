import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

/// Supported app locales — controls brain system-prompt language, UI hint
/// strings ("Talk to me…" vs "Say something…"), and TTS preferred language.
enum AppLocale { system, en, zh }

extension AppLocaleX on AppLocale {
  String get code {
    switch (this) {
      case AppLocale.system:
        return 'system';
      case AppLocale.en:
        return 'en';
      case AppLocale.zh:
        return 'zh';
    }
  }

  String get displayName {
    switch (this) {
      case AppLocale.system:
        return 'locale.system'.tr;
      case AppLocale.en:
        return 'locale.english'.tr;
      case AppLocale.zh:
        return 'locale.simplified_chinese'.tr;
    }
  }

  static AppLocale fromCode(String? code) {
    switch (code) {
      case 'zh_CN':
      case 'zh-CN':
      case 'zh':
        return AppLocale.zh;
      case 'en':
        return AppLocale.en;
      case 'system':
      case null:
      default:
        return AppLocale.system;
    }
  }
}

/// Reactive locale service.  Any widget / brain prompt that wants
/// localization can `appServices.find<LocaleConfigService>().locale.value` —
/// changes propagate via AppReactiveBuilder subscribers.
///
/// Default follows the device language and falls back to English when the
/// device language is unsupported (override via Settings → Language).
class LocaleConfigService extends AppService {
  final SecureStorageService _storage = appServices
      .find<SecureStorageService>();

  final Rx<AppLocale> locale = AppLocale.system.obs;

  Future<LocaleConfigService> init() async {
    final saved = await _storage.read(GlobalConstant.keyAppLocale);
    locale.value = AppLocaleX.fromCode(saved);
    return this;
  }

  Future<void> setLocale(AppLocale next) async {
    locale.value = next;
    await _storage.write(GlobalConstant.keyAppLocale, next.code);
    AppLocalization.updateLocale(resolvedFlutterLocale);
  }

  AppLocale get resolvedAppLocale {
    final selected = locale.value;
    if (selected != AppLocale.system) return selected;
    final device = AppLocalization.deviceLocale;
    return device.languageCode.toLowerCase().startsWith('zh')
        ? AppLocale.zh
        : AppLocale.en;
  }

  Locale get resolvedFlutterLocale => resolvedAppLocale == AppLocale.zh
      ? const Locale('zh', 'CN')
      : const Locale('en', 'US');

  String get chatInputHint => 'chat.input_hint'.tr;

  String get historyLabel => 'chat.history'.tr;

  String get thinkingLabel => 'chat.thinking'.tr;
}
