import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('proactive notifications join account prepare and teardown barriers', () {
    final source = File('lib/main.dart').readAsStringSync();
    final schedulerSource = File(
      'lib/src/core/notifications/proactive_system_notification_scheduler.dart',
    ).readAsStringSync();

    expect(
      source,
      matches(
        RegExp(
          r'proactiveNotifications\s*\.prepareAccountScope\(',
          multiLine: true,
        ),
      ),
    );
    expect(
      source,
      contains('proactiveNotifications.acknowledgePlatformSweep('),
    );
    expect(source, contains('proactiveNotifications.bindAccountRuntime('));
    expect(source, contains('final proactiveNotificationMountToken = await'));
    final ownerStart = source.indexOf(
      'Future<AccountRuntimeLease> _mountAgentExecution(',
    );
    final ownerEnd = source.indexOf(
      'Future<void> _drainAgentExecution(',
      ownerStart,
    );
    final owner = source.substring(ownerStart, ownerEnd);
    final shared = source.substring(0, ownerStart);
    expect(
      shared,
      isNot(contains('proactiveNotifications.bindAccountRuntime(')),
    );
    expect(
      RegExp(r'mountToken: token').allMatches(owner),
      hasLength(2),
      reason:
          'Each owner lifetime re-prepares one token shared by sweep and binding.',
    );
    expect(
      owner,
      contains('await proactiveNotifications.prepareAccountScope('),
    );
    expect(owner, contains('requireMountCurrent();'));
    final deferredOwner = source.substring(
      source.indexOf('Future<void> _runAccountPostFrameBootTasks('),
      source.indexOf('bool _isCurrentAccountMount'),
    );
    expect(
      deferredOwner,
      matches(
        RegExp(
          r'maybeFind<ProactiveSystemNotificationScheduler>\(\)\s*\?\.activate\(\)',
        ),
      ),
    );
    expect(deferredOwner, contains('if (!ownerIsCurrent()) return'));
    expect(source, contains("'proactive_notifications'"));
    expect(source, contains("'feature_flags'"));
    expect(source, contains("'proactive_preferences'"));
    expect(source, contains("'outreach_feedback'"));
    expect(source, contains('MaasoFeatureFlagService('));
    expect(source, contains('ProactivePreferenceService('));
    expect(source, contains('OutreachFeedbackCollector('));
    expect(source, contains('proactiveSnapshot.hardMuted'));
    expect(
      source,
      contains('preferenceRevision: proactiveSnapshot.revision'),
      reason: 'A durable mute must be replayed after a crash/remount.',
    );
    expect(source, contains('await outreachFeedback.recordUnmuted('));
    expect(
      source,
      contains('SembastMaasoFeatureFlagAssignmentStore(mountedDatabase)'),
    );
    expect(
      source,
      matches(
        RegExp(
          r'maybeFind<MaasoFeatureFlagService>\(\)\s*\?\.deactivateAndDrain\(\)',
          multiLine: true,
        ),
      ),
    );
    expect(
      source,
      matches(
        RegExp(
          r'maybeFind<ProactivePreferenceService>\(\)\s*\?\.deactivateAndDrain\(\)',
          multiLine: true,
        ),
      ),
    );
    expect(
      source,
      matches(
        RegExp(
          r'Future\.wait<void>\(\s*<Future<void>>\[[\s\S]*featureFlagDrain,',
        ),
      ),
      reason: 'The account teardown barrier must await feature flag drain.',
    );
    expect(
      source,
      matches(
        RegExp(
          r'Future\.wait<void>\(\s*<Future<void>>\[[\s\S]*proactivePreferenceDrain,',
        ),
      ),
      reason: 'The account teardown barrier must await preference drain.',
    );
    expect(
      source,
      matches(
        RegExp(
          r'Future\.wait<void>\(\s*<Future<void>>\[[\s\S]*outreachFeedbackDrain,',
        ),
      ),
      reason: 'The account teardown barrier must await feedback drain.',
    );
    final feedbackDrain = source.substring(
      source.indexOf("barrier.run('outreach_feedback'"),
      source.indexOf("barrier.run('feature_flags'"),
    );
    expect(feedbackDrain, contains('runtimeDrain'));
    expect(feedbackDrain, contains('proactivePreferenceDrain'));
    expect(feedbackDrain, contains('companionVoiceDrain'));
    expect(feedbackDrain, contains('await collector.reconcile('));
    expect(feedbackDrain, contains('await collector.deactivateAndDrain()'));
    expect(source, contains('?.deactivateAccountAndDrain()'));
    expect(
      source,
      isNot(contains('unawaited(proactiveSystemNotifications.activate())')),
    );
    expect(
      schedulerSource,
      contains('_signalScope == prepared'),
      reason: 'Only the matching published session may activate its scope.',
    );
    expect(
      schedulerSource,
      contains('_binding?.scope == prepared'),
      reason: 'A session cannot activate before its account ledger is bound.',
    );
    expect(
      schedulerSource,
      contains('identical(_binding?.mountToken, _preparedMountToken)'),
      reason: 'A stale mount of the same scope must not reactivate scheduling.',
    );
  });

  test(
    'persona owns proactive choices and settings keep system notifications',
    () {
      final retiredBridge = File(
        'lib/src/features/settings/application/agent_settings_controller.dart',
      ).readAsStringSync();
      expect(retiredBridge, isNot(contains('_refreshNotificationView')));
      expect(retiredBridge, isNot(contains('setProactiveHardMuted')));
      final persona = File(
        'lib/src/features/relationship/presentation/proactive_conversation_controls.dart',
      ).readAsStringSync();
      expect(persona, contains('service.setQuietHours('));
      expect(persona, contains('service.setDailyBudget('));
      expect(persona, contains('service.setContactAgreement('));

      final page = File(
        'lib/src/features/settings/presentation/agent_settings_page.dart',
      ).readAsStringSync();
      expect(page, isNot(contains('ProactiveConversationControls')));
      expect(page, isNot(contains('ConversationPreferenceControls')));
      expect(page, contains('consent.setEnabled('));
      expect(page, contains('notifications.setScheduledTasksEnabled'));
    },
  );
}
