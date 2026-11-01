import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/conversation/natural_conversation_quality_catalog.dart';

void main() {
  test('catalog covers every quality dimension in both languages', () {
    expect(naturalConversationQualityScenarios, hasLength(24));
    for (final locale in NaturalConversationQualityLocale.values) {
      final localized = naturalConversationQualityScenarios
          .where((scenario) => scenario.locale == locale)
          .toList();
      expect(localized, hasLength(12));
      expect(
        localized.map((scenario) => scenario.category).toSet(),
        NaturalConversationQualityCategory.values.toSet(),
      );
      expect(
        localized.expand((scenario) => scenario.focuses).toSet(),
        NaturalConversationQualityFocus.values.toSet(),
      );
    }
    expect(
      naturalConversationQualityScenarios
          .singleWhere((scenario) => scenario.id == 'zh.everyday_choice')
          .userText,
      '今天吃啥好呢？',
    );
  });

  test('users speak naturally and never issue Avatar action commands', () {
    final forbidden = RegExp(
      r'(低头|点头|挥手|做个动作|想一想动作|look down|nod|wave|animate|gesture)',
      caseSensitive: false,
    );
    for (final scenario in naturalConversationQualityScenarios) {
      expect(scenario.userText, isNot(matches(forbidden)), reason: scenario.id);
      for (final turn in scenario.history) {
        expect(turn.text, isNot(matches(forbidden)), reason: scenario.id);
      }
    }
  });
}
