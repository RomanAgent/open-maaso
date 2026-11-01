import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/utils/creation_intent_language.dart';

void main() {
  test('Chinese ability questions are not creation negations', () {
    for (final text in const <String>[
      '能不能创建小游戏',
      '能不能帮我创建一个小游戏',
      '能不能制作一个小程序',
    ]) {
      expect(
        CreationIntentLanguage.isNegatedCreation(text),
        isFalse,
        reason: text,
      );
    }
  });

  test('actual Chinese creation negations remain blocked', () {
    for (final text in const <String>[
      '不能创建小游戏',
      '不能帮我创建小游戏',
      '不要创建小游戏',
      '能不能不要创建小游戏',
      '能不能不能创建小游戏',
    ]) {
      expect(
        CreationIntentLanguage.isNegatedCreation(text),
        isTrue,
        reason: text,
      );
    }
  });
}
