import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';

enum ThemeModePreference {
  system('system'),
  light('light'),
  dark('dark');

  const ThemeModePreference(this.key);
  final String key;

  /// Stable user-selection order, independent of the resolved system theme.
  ThemeModePreference get next => switch (this) {
    ThemeModePreference.system => ThemeModePreference.light,
    ThemeModePreference.light => ThemeModePreference.dark,
    ThemeModePreference.dark => ThemeModePreference.system,
  };

  static ThemeModePreference fromKey(String? key) {
    switch (key) {
      case 'system':
        return ThemeModePreference.system;
      case 'dark':
        return ThemeModePreference.dark;
      case 'light':
        return ThemeModePreference.light;
      default:
        return ThemeModePreference.system;
    }
  }
}

/// App-wide holder for the *active* theme: brightness (light/dark) + accent.
///
/// Kept in sync from the active profile by [AgentCoreController] (on load and
/// on every `updateProfile`) and by the appearance settings. [MaasoApp] rebuilds
/// its `MaterialApp` reactively off [palette], and any custom surface can
/// read the live colours through [ThemeBuilder].
class ThemeService extends AppService with WidgetsBindingObserver {
  final Rx<ThemeModePreference> mode = ThemeModePreference.system.obs;
  final Rx<Brightness> brightness = Brightness.light.obs;
  final Rx<Brightness> systemBrightness = Brightness.light.obs;
  final Rx<AppAccent> accent = AppAccent.blue.obs;

  /// The fully-resolved colour set for the current (brightness, accent).
  AppPalette get palette => AppPalette.of(brightness.value, accent.value);

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _readPlatformBrightness();
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }

  @override
  void didChangePlatformBrightness() {
    _readPlatformBrightness();
  }

  void _readPlatformBrightness() {
    final binding = WidgetsBinding.instance;
    systemBrightness.value = binding.platformDispatcher.platformBrightness;
    _resolveBrightness();
  }

  void setBrightness(Brightness b) {
    mode.value = b == Brightness.dark
        ? ThemeModePreference.dark
        : ThemeModePreference.light;
    _resolveBrightness();
  }

  void setMode(ThemeModePreference next) {
    mode.value = next;
    _resolveBrightness();
  }

  void setAccent(AppAccent a) => accent.value = a;

  /// Convenience for callers holding persisted string keys.
  void setBrightnessKey(String? key) => setMode(
    key == 'dark' ? ThemeModePreference.dark : ThemeModePreference.light,
  );

  void setModeKey(String? key) => setMode(ThemeModePreference.fromKey(key));

  void setAccentKey(String? key) => accent.value = AppAccent.fromKey(key);

  void setSystemBrightnessForTest(Brightness next) {
    systemBrightness.value = next;
    _resolveBrightness();
  }

  /// Push a profile's persisted theme fields into the live service.
  void setFromProfile(AgentProfile p) {
    setModeKey(p.themeMode ?? p.themeBrightness);
    setAccentKey(p.themeAccent);
  }

  void _resolveBrightness() {
    final resolvedBrightness = switch (mode.value) {
      ThemeModePreference.system => systemBrightness.value,
      ThemeModePreference.light => Brightness.light,
      ThemeModePreference.dark => Brightness.dark,
    };
    brightness.value = resolvedBrightness;
  }
}

/// Rebuilds [builder] whenever the active [AppPalette] changes.
///
/// Use this inside custom surfaces (scaffold backgrounds, gradients) so they
/// flip with light/dark instead of staying pinned to the static
/// [ColorConstant] light values.  Falls back to the default light palette when
/// the service isn't registered (e.g. widget tests).
class ThemeBuilder extends StatelessWidget {
  const ThemeBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, AppPalette palette) builder;

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<ThemeService>()) {
      return builder(context, AppPalette.of(Brightness.light, AppAccent.blue));
    }
    final svc = appServices.find<ThemeService>();
    return AppReactiveBuilder(() => builder(context, svc.palette));
  }
}
