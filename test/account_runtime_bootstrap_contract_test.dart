import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup mounts account persistence only after authentication', () {
    final source = File('lib/main.dart').readAsStringSync();

    final instanceAcquire = source.indexOf(
      '_tryAcquireApplicationRuntimeInstance(',
    );
    final bootstrapCall = source.indexOf(
      'await _bootstrapApplication(coldStartStopwatch)',
    );
    final bootstrapStart = source.indexOf('Future<void> _bootstrapApplication');
    final secureStorageInitialization = source.indexOf(
      'SecureStorageService().init()',
    );
    final notificationInitialization = source.indexOf(
      'await notificationDelivery.initialize()',
    );
    final scheduledInitialization = source.indexOf(
      'ScheduledTaskService(executionAllowed: () => false).init()',
    );
    final lifecycleRegistration = source.indexOf(
      'AccountSessionLifecycleService(',
    );
    final initialRouteResolution = source.indexOf('resolveInitialRoute()');
    final scopedDatabaseOpen = source.indexOf(
      'DBService().init(scope: accountScope)',
    );

    expect(instanceAcquire, greaterThanOrEqualTo(0));
    expect(bootstrapCall, greaterThan(instanceAcquire));
    expect(bootstrapStart, greaterThan(bootstrapCall));
    expect(secureStorageInitialization, greaterThan(bootstrapStart));
    expect(notificationInitialization, greaterThan(bootstrapStart));
    expect(scheduledInitialization, greaterThan(bootstrapStart));
    expect(lifecycleRegistration, greaterThan(scheduledInitialization));
    expect(initialRouteResolution, greaterThan(lifecycleRegistration));
    expect(scopedDatabaseOpen, greaterThan(initialRouteResolution));
    expect(source, isNot(contains('DBService().init());')));
    expect(source, contains("final agentScope = accountScope.agent('self');"));
    expect(source, contains('putOwnedAsync<SoulService>'));
    expect(source, contains('SoulService().init(scope: agentScope)'));
    expect(source, contains('putOwnedAsync<MasterProfileService>'));
    expect(
      source,
      contains('MasterProfileService().init(scope: accountScope)'),
    );
    expect(source, contains('putOwnedAsync<WorldKBService>'));
    expect(source, contains('WorldKBService().init(scope: agentScope)'));
    expect(source, isNot(contains('putOwnedAsync(() => SoulService().init')));
    expect(source, contains('await agentCore.ensureLoaded()'));
    expect(source, contains('if (acquireError != null) {'));
    expect(source, contains('_AccountRuntimeInstanceBlockedApp('));
  });

  test('account mount cannot acquire or release the app lifetime lease', () {
    final source = File('lib/main.dart').readAsStringSync();
    final mountStart = source.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime',
    );
    final mountEnd = source.indexOf(
      'Future<void> _disposeAccountRuntime',
      mountStart,
    );
    final mountBody = source.substring(mountStart, mountEnd);

    expect(mountBody, isNot(contains('runtimeInstanceLeaseGate')));
    expect(mountBody, isNot(contains('.acquire()')));
    expect(mountBody, isNot(contains('.release()')));
  });

  test('World governance binds and rehydrates before prompt consumers', () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime(',
    );
    final end = source.indexOf(
      'Future<AccountRuntimeLease> _mountAgentExecution(',
      start,
    );
    final mount = source.substring(start, end);
    final load = mount.indexOf('WorldKBService().init(scope: agentScope)');
    final coordinator = mount.indexOf('MemoryWriteCoordinator(');
    final bind = mount.indexOf('worldNotes.bindGovernance(');
    final refresh = mount.indexOf('await worldNotes.refresh()');
    final facts = mount.indexOf('await conversationMemory.refresh()');
    final runtime = mount.indexOf('AgentRuntimeRegistry(');
    expect(load, greaterThanOrEqualTo(0));
    expect(coordinator, greaterThan(load));
    expect(mount.substring(coordinator, bind), contains('worldNotes,'));
    expect(bind, greaterThan(coordinator));
    expect(refresh, greaterThan(bind));
    expect(facts, greaterThan(refresh));
    expect(runtime, greaterThan(facts));

    final drain = source.substring(
      source.indexOf('Future<void> _drainAccountRuntimeProducers()'),
      source.indexOf('void _registerDefaultVadServices()'),
    );
    expect(
      drain,
      contains('maybeFind<WorldKBService>()?.deactivateAndDrain()'),
    );
    final writer = drain.indexOf("barrier.run('memory_write_coordinator'");
    final world = drain.indexOf('await worldNotesDrain;', writer);
    final seal = drain.indexOf(
      'maybeFind<MemoryWriteCoordinator>()?.deactivateAndDrain()',
      writer,
    );
    expect(writer, greaterThanOrEqualTo(0));
    expect(world, greaterThan(writer));
    expect(seal, greaterThan(world));
    expect(drain, contains('worldNotesDrain,'));
  });

  test('account teardown fences tasks and closes database last', () {
    final source = File('lib/main.dart').readAsStringSync();
    final disposeStart = source.indexOf('Future<void> _disposeAccountRuntime');
    final producerDrainStart = source.indexOf(
      'Future<void> _drainAccountRuntimeProducers',
      disposeStart,
    );
    final producerDrainEnd = source.indexOf(
      'void _registerDefaultVadServices',
      producerDrainStart,
    );
    final disposeBody = source.substring(disposeStart, producerDrainStart);
    final producerDrainBody = source.substring(
      producerDrainStart,
      producerDrainEnd,
    );

    final producerFence = disposeBody.indexOf(
      'await _drainAccountRuntimeProducers()',
    );
    final deleteConsumers = disposeBody.indexOf('for (final type');
    final closeDatabase = disposeBody.indexOf('await database?.close()');
    final deleteDatabase = disposeBody.indexOf(
      'await appServices.delete<DBService>',
    );

    expect(producerFence, greaterThanOrEqualTo(0));
    expect(deleteConsumers, greaterThanOrEqualTo(0));
    expect(producerFence, lessThan(deleteConsumers));
    expect(
      producerDrainBody,
      contains('maybeFind<AgentSpaceController>()?.deactivateAndDrain()'),
    );
    expect(producerDrainBody, isNot(contains('WorldRuntime')));
    expect(
      producerDrainBody,
      isNot(contains('WorldAvatarSelectionFenceRuntime')),
    );
    final runtimeDrain = producerDrainBody.indexOf("'agent_runtime'");
    final recallDrain = producerDrainBody.indexOf("'memory_recall'");
    final episodeDrain = producerDrainBody.indexOf("'episode_store'");
    final agentSpaceDrain = producerDrainBody.indexOf("'agent_space'");
    final avatarConfigDrain = producerDrainBody.indexOf("'avatar_config'");
    final avatarSelectionDrain = producerDrainBody.indexOf(
      "'avatar_selection'",
    );
    final avatarResetDrain = producerDrainBody.indexOf("'avatar_reset'");
    final avatarResetEnd = producerDrainBody.indexOf(
      'final realtimeSessionDrain',
      avatarResetDrain,
    );
    expect(runtimeDrain, greaterThanOrEqualTo(0));
    expect(recallDrain, greaterThan(runtimeDrain));
    expect(episodeDrain, greaterThan(recallDrain));
    expect(agentSpaceDrain, greaterThanOrEqualTo(0));
    expect(avatarConfigDrain, greaterThan(agentSpaceDrain));
    expect(avatarConfigDrain, greaterThanOrEqualTo(0));
    expect(avatarSelectionDrain, greaterThan(avatarConfigDrain));
    expect(avatarSelectionDrain, greaterThanOrEqualTo(0));
    expect(avatarResetDrain, greaterThan(avatarSelectionDrain));
    expect(avatarResetEnd, greaterThan(avatarResetDrain));
    expect(
      producerDrainBody.substring(avatarConfigDrain, avatarSelectionDrain),
      contains('await agentSpaceDrainAttempt'),
    );
    expect(
      producerDrainBody.substring(avatarSelectionDrain, avatarResetDrain),
      contains('await agentSpaceDrainAttempt'),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains('agentSpaceDrain'),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains('avatarConfigDrain'),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains('avatarSelectionDrain'),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains('runtimeDrain'),
    );
    expect(
      producerDrainBody,
      contains('maybeFind<AvatarSelectionCoordinator>()'),
    );
    expect(
      producerDrainBody,
      contains('maybeFind<AvatarConfigService>()?.deactivateAndDrain('),
    );
    expect(producerDrainBody, contains('timeout: const Duration(seconds: 20)'));
    expect(
      producerDrainBody,
      contains("throw StateError('avatar_selection_drain_incomplete')"),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains('if (!agentSpaceFullyDrained)'),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains("throw StateError('avatar_reset_blocked_by_agent_space_drain')"),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains('if (!avatarSelectionFullyDrained)'),
    );
    expect(
      producerDrainBody.substring(avatarResetDrain, avatarResetEnd),
      contains('if (!avatarConfigFullyDrained)'),
    );
    expect(producerDrainBody, contains('maybeFind<MemoryRecallSafetyGate>()'));
    expect(producerDrainBody, contains('memoryRecallDrain'));
    expect(closeDatabase, greaterThan(deleteConsumers));
    expect(deleteDatabase, greaterThan(closeDatabase));
    expect(
      producerDrainBody,
      contains('maybeFind<LiveCompanionSyncService>()?.shutdown()'),
    );
    expect(source, contains('_isCurrentAccountMount(mount)'));
    expect(source, contains('AccountStorageScopeMount mount'));
    expect(source, isNot(contains('gateway: agentWorldService')));
    expect(source, contains('avatarRuntime: activeAvatarRuntime'));
  });

  test(
    'device renderer stays global while avatar selection and space are account scoped',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final globalRenderer = source.indexOf('ActiveAvatarRuntime()');
      final lifecycleRegistration = source.indexOf(
        'AccountSessionLifecycleService(',
      );
      final scopedAvatar = source.indexOf('AvatarConfigService(');
      final agentSpace = source.indexOf('AgentSpaceController(');
      final agentSpaceEnd = source.indexOf(
        'putOwned(SurfaceRuntime())',
        agentSpace,
      );

      expect(globalRenderer, greaterThanOrEqualTo(0));
      expect(globalRenderer, lessThan(lifecycleRegistration));
      expect(scopedAvatar, greaterThan(lifecycleRegistration));
      expect(agentSpace, greaterThan(scopedAvatar));
      expect(agentSpaceEnd, greaterThan(agentSpace));
      expect(source, matches(RegExp(r'putOwned\(\s*AgentSpaceController\(')));
      final agentSpaceRegistration = source.substring(
        agentSpace,
        agentSpaceEnd,
      );
      expect(agentSpaceRegistration, contains('avatar: activeAvatarRuntime'));
      expect(
        agentSpaceRegistration,
        contains('isCurrent: () => _isCurrentAccountMount(mount)'),
      );
      final prepareAvatar = agentSpaceRegistration.indexOf('prepareAvatar:');
      final firstMountFence = agentSpaceRegistration.indexOf(
        'requireMountCurrent()',
        prepareAvatar,
      );
      final selectedDisplay = agentSpaceRegistration.indexOf(
        'await avatarConfig.ensureSelectedDisplayReady()',
      );
      final secondMountFence = agentSpaceRegistration.indexOf(
        'requireMountCurrent()',
        selectedDisplay,
      );
      final currentSelection = agentSpaceRegistration.indexOf(
        'if (!avatarConfig.selectionDisplayCurrent)',
      );
      expect(prepareAvatar, greaterThanOrEqualTo(0));
      expect(firstMountFence, greaterThan(prepareAvatar));
      expect(selectedDisplay, greaterThan(firstMountFence));
      expect(secondMountFence, greaterThan(selectedDisplay));
      expect(currentSelection, greaterThan(secondMountFence));
      for (final retired in [
        'WorldRuntime(',
        'WorldAvatarSelectionFenceRuntime',
        'WorldCapabilityAuthority(',
      ]) {
        expect(source, isNot(contains(retired)));
      }
      expect(source, contains('storageKeyPrefix: agentScope.storageNamespace'));
      expect(
        source,
        matches(
          RegExp(
            r'selectionCoordinator: kOpenMaasoLocalEdition\s*\? null\s*: avatarSelectionCoordinator',
          ),
        ),
      );
      expect(source, contains('AvatarConfigService.builtInCatalog.first'));
    },
  );

  test(
    'each account mount owns local dialogue while shared execution remains leased',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final baseStart = source.indexOf(
        'Future<AccountRuntimeLease> _mountAccountRuntime(',
      );
      final ownerStart = source.indexOf(
        'Future<AccountRuntimeLease> _mountAgentExecution(',
      );
      final ownerDrainStart = source.indexOf(
        'Future<void> _drainAgentExecution(',
      );
      final base = source.substring(baseStart, ownerStart);
      final owner = source.substring(ownerStart, ownerDrainStart);
      expect(
        source,
        matches(
          RegExp(
            r'mountCompanionRuntime: kOpenMaasoLocalEdition\s*\? null\s*: \(mount\) =>\s*_mountAccountRuntime\(',
          ),
        ),
      );
      expect(
        source,
        matches(
          RegExp(
            r'mountRuntime: \(mount\) => kOpenMaasoLocalEdition\s*\? _mountAccountRuntime\([\s\S]*?: _mountAgentExecution\(',
          ),
        ),
      );
      expect(base, contains('DBService().init(scope: accountScope)'));
      expect(base, contains('AgentRuntimeRegistry('));
      expect(base, contains('hostExecutionEnabled: true'));
      expect(base, contains('AvatarConfigService('));
      expect(base, contains('AgentSpaceController('));
      expect(base, isNot(contains('WorldRuntime(')));
      expect(base, isNot(contains('WorldAvatarSelectionFenceRuntime')));
      expect(base, isNot(contains('createRuntimeChatRelay(')));
      expect(base, contains('LiveCompanionSyncService('));
      expect(base, isNot(contains('producerFence.install(')));
      expect(base, contains('AvatarProjectionProductionAuthority('));
      expect(base, contains('AgentBootController('));
      expect(base, contains('AgentPresenceService('));
      expect(base, isNot(contains('_registerRealtimeAgent(')));
      expect(owner, isNot(contains('activateHostedExecution()')));
      expect(owner, contains('lifecycle.ownerActivationInProgress'));
      expect(owner, contains('ownerActive = false'));
      expect(owner, contains('return _drainAgentExecution()'));
      expect(owner, isNot(contains('AvatarProjectionProductionAuthority(')));
      expect(owner, isNot(contains('AgentBootController(')));
      expect(owner, isNot(contains('AgentSpaceController(')));
      expect(owner, contains('_registerRealtimeAgent('));
      expect(owner, contains('lifecycle.canExecuteAgent'));
      expect(base, contains('lifecycle.canChatLocally'));
      expect(owner, isNot(contains('DBService().init(')));
    },
  );

  test(
    'owner demotion drains execution without sealing shared page services',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final start = source.indexOf('Future<void> _drainAgentExecution(');
      final end = source.indexOf('final class _MountedAccountRuntime', start);
      final drain = source.substring(start, end);
      expect(drain, isNot(contains('suspendHostedExecution()')));
      expect(
        drain,
        isNot(
          contains('maybeFind<AgentBootController>()?.deactivateAndDrain()'),
        ),
      );
      expect(
        drain,
        isNot(contains("MaasoTtsPlugin.stopAllStrict(agentId: 'self')")),
      );
      for (final shared in [
        '_drainAccountRuntimeProducers',
        'AvatarConfigService',
        'AvatarSelectionCoordinator',
        'AgentSpaceController',
        'MemoryWriteCoordinator',
        'MemoryLedgerService',
        'WorldKBService',
        'LocationService',
        'NetworkRegionService',
        'WebSearchDiagnosticsService',
        'DBService',
        'CompanionVoiceSessionBoundary',
      ]) {
        expect(
          drain,
          isNot(contains(shared)),
          reason: '$shared survives owner demotion',
        );
      }
      expect(
        drain,
        contains('if (barrier.errors.isNotEmpty) barrier.throwFirst()'),
      );
    },
  );

  test(
    'public network region mounts before skills and drains with its account',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final start = source.indexOf(
        'Future<AccountRuntimeLease> _mountAccountRuntime(',
      );
      final end = source.indexOf(
        'Future<AccountRuntimeLease> _mountAgentExecution(',
        start,
      );
      final mount = source.substring(start, end);
      final location = mount.indexOf('final locationService =');
      final region = mount.indexOf('NetworkRegionService(');
      final runtime = mount.indexOf('AgentRuntimeRegistry(');
      final diagnostics = mount.indexOf('WebSearchDiagnosticsService(');
      expect(location, greaterThanOrEqualTo(0));
      expect(region, greaterThan(location));
      expect(runtime, greaterThan(region));
      expect(diagnostics, greaterThan(region));
      expect(runtime, greaterThan(diagnostics));
      expect(
        mount.substring(region, runtime),
        contains(
          'countryCodeSupplier: () => locationService.cachedCountryCode',
        ),
      );
      expect(
        mount.substring(region, runtime),
        contains('isOwnerCurrent: () => storageScopes.isCurrent(mount)'),
      );
      expect(
        mount.substring(region, runtime),
        contains(').init(scope: accountScope)'),
      );
      final drain = source.substring(
        source.indexOf('Future<void> _drainAccountRuntimeProducers()'),
        source.indexOf('void _registerDefaultVadServices()'),
      );
      expect(
        drain,
        contains('maybeFind<NetworkRegionService>()?.deactivateAndDrain()'),
      );
      expect(drain, contains('networkRegionDrain,'));
      expect(drain, contains('maybeFind<WebSearchDiagnosticsService>()'));
      expect(drain, contains('searchDiagnosticsDrain,'));
    },
  );

  test(
    'late owner startup keeps a lifetime guard beyond the shared account mount',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final start = source.indexOf('void _scheduleAccountPostFrameBootTasks(');
      final end = source.indexOf('bool _isCurrentAccountMount', start);
      final boot = source.substring(start, end);
      expect(boot, contains('required bool Function() ownerIsCurrent'));
      expect(
        boot,
        contains('!lifecycle.canExecuteAgent || handoff?.isBusy == true'),
      );
      expect(boot, contains('isAccountCurrent: ownerIsCurrent'));
      expect(boot, contains('if (!ownerIsCurrent()) return'));
      expect(boot, contains('ownerIsCurrent: ownerIsCurrent'));
    },
  );

  test(
    'every mounted account reconciles its avatar independently of execution boot',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final mountStart = source.indexOf(
        'Future<AccountRuntimeLease> _mountAccountRuntime(',
      );
      final mountEnd = source.indexOf(
        'Future<AccountRuntimeLease> _mountAgentExecution(',
      );
      final sharedMount = source.substring(mountStart, mountEnd);
      final displayBoot = sharedMount.substring(
        sharedMount.indexOf(
          '// Every mounted device owns its local presentation',
        ),
      );
      expect(displayBoot, contains('addPostFrameCallback'));
      expect(
        displayBoot,
        contains('if (!storageScopes.isCurrent(mount)) return'),
      );
      expect(displayBoot, contains('.runAccountOperation('));
      expect(
        displayBoot,
        contains('_restorePersistedReviewedAvatar(mount: mount)'),
      );
      expect(displayBoot, isNot(contains('canExecuteAgent')));
      final ownerStart = source.indexOf(
        'Future<void> _runAccountPostFrameBootTasks(',
      );
      final ownerEnd = source.indexOf(
        'bool _isCurrentAccountMount',
        ownerStart,
      );
      expect(
        source.substring(ownerStart, ownerEnd),
        isNot(contains('_restorePersistedReviewedAvatar')),
      );
      final drain = source.substring(
        source.indexOf('Future<void> _drainAccountRuntimeProducers()'),
        source.indexOf('void _registerDefaultVadServices()'),
      );
      expect(drain, isNot(contains('remote_chat_phone_observer')));
      expect(drain, contains("'live_companion_sync'"));
      expect(drain, contains('liveSyncDrain,'));
    },
  );

  test(
    'scheduled Agent execution waits for the owner role and handoff presentation',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      expect(
        source,
        contains('ScheduledTaskService(executionAllowed: () => false)'),
      );
      final bind = source.indexOf('bindExecutionAuthority(');
      expect(
        bind,
        greaterThan(source.indexOf('AccountSessionLifecycleService(')),
      );
      expect(bind, lessThan(source.indexOf('resolveInitialRoute()')));
      expect(
        source,
        contains(
          'allowed: () => accountLifecycle.canExecuteAgent && !handoff.isBusy',
        ),
      );
      expect(
        source,
        contains('changes: Listenable.merge([accountLifecycle, handoff])'),
      );
    },
  );
}
