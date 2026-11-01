import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'settings delegates persona and memory review to the relationship hub',
    () {
      final page = File(
        'lib/src/features/settings/presentation/agent_settings_page.dart',
      ).readAsStringSync();
      expect(page, isNot(contains("'settings.section_persona'.tr")));
      expect(page, isNot(contains("'skills.my_skills'.tr")));
      expect(page, isNot(contains('AppRouteCatalog.memoryLedger')));
      expect(page, isNot(contains('AppRouteCatalog.skills')));
    },
  );

  test('settings pages mount independent body navigation', () {
    final source = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('appBar: AppGlassAppBar(')));
    expect(RegExp(r'AppSecondaryScaffold\(').allMatches(source).length, 2);
    expect(RegExp(r'AppSecondaryHeader\(').allMatches(source).length, 1);
    expect(source, contains('onBack: () => appNavigation.pop()'));
    expect(source, contains("'settings.advanced_features_page_title'.tr"));
  });

  test(
    'persona owns contact preferences while settings owns device notifications',
    () {
      final page = File(
        'lib/src/features/settings/presentation/agent_settings_page.dart',
      ).readAsStringSync();
      final section = page.substring(
        page.indexOf('class _NotificationSection'),
        page.indexOf('class _LanguageSection'),
      );
      final persona = File(
        'lib/src/features/relationship/presentation/agent_persona_card.dart',
      ).readAsStringSync();
      final controls = File(
        'lib/src/features/relationship/presentation/proactive_conversation_controls.dart',
      ).readAsStringSync();

      expect(page, isNot(contains('ConversationPreferenceControls')));
      expect(page, isNot(contains('ProactiveConversationControls')));
      expect(section, contains('NotificationConsentService'));
      expect(section, contains('NotificationPreferencesService'));
      expect(section, contains('notifications.setScheduledTasksEnabled'));
      expect(section, isNot(contains('AgentSettingsController')));
      for (final key in [
        'notifications_greetings',
        'notifications_check_ins',
        'notifications_pause_proactive',
        'notifications_quiet_hours',
      ]) {
        expect(section, isNot(contains(key)));
      }
      expect(persona, contains('const ConversationPreferenceControls()'));
      expect(persona, contains('const ProactiveConversationControls()'));
      expect(controls, contains('service.setContactAgreement('));
      expect(controls, contains('service.setQuietHours('));
      expect(controls, contains('notifications.setGreetingsEnabled('));
      expect(controls, contains('notifications.setRandomCheckInsEnabled('));
      expect(controls, isNot(contains('notifications_pause_proactive')));
      expect(
        File(
          'lib/src/features/settings/presentation/conversation_preference_controls.dart',
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          'lib/src/features/settings/presentation/proactive_conversation_controls.dart',
        ).existsSync(),
        isFalse,
      );
    },
  );
}
