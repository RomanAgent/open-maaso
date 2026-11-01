import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';

void main() {
  tearDown(() => AppLocalization.updateLocale(const Locale('en', 'US')));

  test('English and Chinese bundles have matching keys', () {
    expect(enUS.keys.toSet(), zhCH.keys.toSet());
  });

  test('English and Chinese placeholders match for every interface key', () {
    final placeholder = RegExp(r'@[A-Za-z][A-Za-z0-9_]*');
    final mismatches = <String>[];

    for (final key in enUS.keys) {
      final english = placeholder
          .allMatches(enUS[key]!)
          .map((match) => match.group(0)!)
          .toSet();
      final chinese = placeholder
          .allMatches(zhCH[key]!)
          .map((match) => match.group(0)!)
          .toSet();
      if (!english.containsAll(chinese) || !chinese.containsAll(english)) {
        mismatches.add('$key: en=$english, zh=$chinese');
      }
    }

    expect(mismatches, isEmpty);
  });

  test('interface translations are never empty', () {
    final emptyKeys = <String>{
      for (final entry in enUS.entries)
        if (entry.value.trim().isEmpty) entry.key,
      for (final entry in zhCH.entries)
        if (entry.value.trim().isEmpty) entry.key,
    };

    expect(emptyKeys, isEmpty);
  });

  test('English bundle does not contain Chinese interface copy', () {
    final chinese = RegExp(r'[\u3400-\u9fff]');
    final mixedEntries = enUS.entries
        .where((entry) => chinese.hasMatch(entry.value))
        .map((entry) => entry.key)
        .toList(growable: false);

    expect(mixedEntries, isEmpty);
  });

  test('switching locales translates secondary feature copy', () {
    AppLocalization.updateLocale(const Locale('en', 'US'));
    expect('skill_store.title'.tr, 'Skill Store');
    expect('agent_space.exit'.tr, 'Exit space');
    expect('live.start'.tr, 'Start live');
    expect(
      'agent_runtime.background_game_started'.tr,
      'I’ll write a little game for you, then open it so you can play.',
    );

    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    expect('skill_store.title'.tr, 'Skill 商店');
    expect('agent_space.exit'.tr, '退出空间');
    expect('live.start'.tr, '开始直播');
    expect('agent_runtime.background_game_started'.tr, '我给你写一个小游戏出来，写好就打开给你玩。');
  });

  test(
    'a future locale can register without changing the translation engine',
    () {
      AppLocalization.registerTranslations(const Locale('es', 'MX'), const {
        'skill_store.title': 'Tienda de Skills',
      });
      AppLocalization.updateLocale(const Locale('es', 'MX'));

      expect('skill_store.title'.tr, 'Tienda de Skills');
      expect('agent_space.exit'.tr, 'Exit space');
      expect(
        AppLocalization.supportedLocales,
        contains(const Locale('es', 'MX')),
      );
    },
  );
}
