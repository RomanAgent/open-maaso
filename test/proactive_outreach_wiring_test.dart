import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('account runtime owns the proactive outreach policy and ledger', () {
    final source = File('lib/main.dart').readAsStringSync();
    final mountStart = source.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime',
    );
    final mountEnd = source.indexOf(
      'final class _MountedAccountRuntime',
      mountStart,
    );

    expect(mountStart, greaterThanOrEqualTo(0));
    expect(mountEnd, greaterThan(mountStart));
    final mount = source.substring(mountStart, mountEnd);

    final database = mount.indexOf('DBService().init(scope: accountScope)');
    final featureFlags = mount.indexOf('MaasoFeatureFlagService(');
    final rollout = mount.indexOf('ProactiveDriveRolloutService(');
    final shadow = mount.indexOf('ProactiveDriveShadowService(');
    final preferences = mount.indexOf('ProactivePreferenceService(');
    final policy = mount.indexOf('ProactivePreferencePolicyAdapter(');
    final ledger = mount.indexOf('ProactiveOutreachLedger(');
    final feedback = mount.indexOf('OutreachFeedbackCollector(');
    final coordinator = mount.indexOf('ProactiveOutreachCoordinator(');
    final bind = mount.indexOf('proactiveNotifications.bindAccountRuntime(');
    final runtimeRegistry = mount.indexOf('AgentRuntimeRegistry(');
    final presence = mount.indexOf('AgentPresenceService(');

    expect(database, greaterThanOrEqualTo(0));
    expect(featureFlags, greaterThan(database));
    expect(rollout, greaterThan(featureFlags));
    expect(shadow, greaterThan(rollout));
    expect(preferences, greaterThan(shadow));
    expect(policy, greaterThan(preferences));
    expect(ledger, greaterThan(policy));
    expect(feedback, greaterThan(ledger));
    expect(coordinator, greaterThan(feedback));
    expect(bind, greaterThan(coordinator));
    expect(runtimeRegistry, greaterThan(coordinator));
    expect(presence, greaterThan(runtimeRegistry));
    expect(mount, contains('accountDatabase: mountedDatabase'));
    expect(mount, contains('accountKey: accountScope.storageNamespace'));
    final executionStart = mount.indexOf(
      'Future<AccountRuntimeLease> _mountAgentExecution',
    );
    expect(executionStart, greaterThan(coordinator));
    final execution = mount.substring(executionStart);
    expect(
      execution,
      contains('coordinator: appServices.find<ProactiveOutreachCoordinator>()'),
    );
    expect(execution, contains('find<ProactivePreferenceService>()'));
    expect(execution, contains('proactivePreferences: appServices'));
    final settings = mount.indexOf('ConversationPreferenceService(');
    expect(settings, greaterThan(database));
    expect(settings, lessThan(runtimeRegistry));
    expect(source, contains("'conversation_preferences'"));
    expect(source, contains('find<ProactiveSystemNotificationScheduler>()'));
    expect(
      source,
      contains('changes: Listenable.merge([accountLifecycle, handoff])'),
    );
  });

  test('proactive outreach dependencies are imported from core services', () {
    final source = File('lib/main.dart').readAsStringSync();

    for (final path in <String>[
      'proactive_companion_policy.dart',
      'proactive_drive_rollout_service.dart',
      'proactive_drive_shadow_service.dart',
      'outreach_feedback_collector.dart',
      'proactive_outreach_coordinator.dart',
      'proactive_outreach_ledger.dart',
      'proactive_preference_service.dart',
      'maaso_feature_flag_service.dart',
    ]) {
      expect(
        source,
        contains("import 'package:maaso/src/core/services/$path';"),
      );
    }
  });
}
