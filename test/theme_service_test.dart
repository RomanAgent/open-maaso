import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/theme_service.dart';

void main() {
  test('unselected appearance follows system brightness by default', () {
    final service = ThemeService();
    expect(service.mode.value, ThemeModePreference.system);
    service.setSystemBrightnessForTest(Brightness.dark);
    expect(service.brightness.value, Brightness.dark);
    service.setSystemBrightnessForTest(Brightness.light);
    expect(service.brightness.value, Brightness.light);
    expect(ThemeModePreference.fromKey(null), ThemeModePreference.system);
    expect(ThemeModePreference.fromKey('invalid'), ThemeModePreference.system);
  });

  test('mode cycles by preference instead of resolved system brightness', () {
    final service = ThemeService();
    for (final systemBrightness in Brightness.values) {
      service.setSystemBrightnessForTest(systemBrightness);
      service.setMode(ThemeModePreference.system);
      service.setMode(service.mode.value.next);
      expect(service.mode.value, ThemeModePreference.light);
      service.setMode(service.mode.value.next);
      expect(service.mode.value, ThemeModePreference.dark);
      service.setMode(service.mode.value.next);
      expect(service.mode.value, ThemeModePreference.system);
      expect(service.brightness.value, systemBrightness);
    }
  });

  test('new profiles and rows without appearance default to system', () {
    final profile = _profile();
    expect(profile.themeMode, 'system');
    expect(AgentProfile.fromJson(profile.toJson()).themeMode, 'system');
    final service = ThemeService();
    service.setSystemBrightnessForTest(Brightness.dark);
    service.setFromProfile(AgentProfile.fromJson(const <String, Object?>{}));
    expect(service.mode.value, ThemeModePreference.system);
    expect(service.brightness.value, Brightness.dark);
  });

  test('legacy explicit brightness survives a profile round trip', () {
    for (final mode in [ThemeModePreference.light, ThemeModePreference.dark]) {
      final legacy = _profile().toJson()
        ..remove('themeMode')
        ..['themeBrightness'] = mode.key;
      final decoded = AgentProfile.fromJson(legacy);
      final reopened = AgentProfile.fromJson(decoded.toJson());
      final service = ThemeService()..setFromProfile(reopened);
      expect(service.mode.value, mode);
    }
  });

  test('explicit mode takes precedence over compatibility brightness', () {
    final service = ThemeService();
    service.setSystemBrightnessForTest(Brightness.dark);
    service.setFromProfile(
      _profile().copyWith(themeMode: 'system', themeBrightness: 'light'),
    );
    expect(service.mode.value, ThemeModePreference.system);
    expect(service.brightness.value, Brightness.dark);
    service.setFromProfile(
      _profile().copyWith(themeMode: 'light', themeBrightness: 'dark'),
    );
    expect(service.mode.value, ThemeModePreference.light);
    expect(service.brightness.value, Brightness.light);
  });

  test('theme mode can be light, dark, or system-following', () {
    final service = ThemeService();

    service.setSystemBrightnessForTest(Brightness.dark);
    service.setModeKey('light');
    expect(service.brightness.value, Brightness.light);
    expect(service.palette.isDark, isFalse);

    service.setModeKey('dark');
    expect(service.brightness.value, Brightness.dark);
    expect(service.palette.isDark, isTrue);

    service.setModeKey('system');
    expect(service.brightness.value, Brightness.dark);
    expect(service.palette.isDark, isTrue);

    service.setSystemBrightnessForTest(Brightness.light);
    expect(service.brightness.value, Brightness.light);
    expect(service.palette.isDark, isFalse);
  });
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Maaso',
  avatar: '',
  bio: '',
  personalityTraits: const [],
  catchphrase: '',
);
