import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/skills/application/skills_controller.dart';
import 'package:maaso/src/features/skills/application/skill_user_groups.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _IdleAgentCoreController extends AgentCoreController {
  @override
  // Test double intentionally suppresses async profile bootstrap.
  // ignore: must_call_super
  void onInit() {}
}

class _RecordingRegistry extends AgentRuntimeRegistry {
  _RecordingRegistry({super.storageKeyPrefix});

  final saved = <Set<String>>[];
  bool fail = false;
  bool failAfterWrite = false;
  bool failRead = false;
  int readCalls = 0;
  Completer<Set<String>>? initialRead;
  @override
  Future<Set<String>> readEnabledSkills(String agentId) async {
    readCalls++;
    if (failRead) throw StateError('Unable to read');
    return initialRead?.future ?? super.readEnabledSkills(agentId);
  }

  @override
  Future<void> setEnabledSkills(String agentId, Set<String> ids) async {
    saved.add({...ids});
    if (fail) throw StateError('Unable to persist');
    await super.setEnabledSkills(agentId, ids);
    if (failAfterWrite) throw StateError('Unable to reload');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'skills-controller-capability.db',
    );
    appServices.put<DBService>(database);
    appServices.put<AgentRuntimeRegistry>(_RecordingRegistry());
    appServices.put<AgentCoreController>(_IdleAgentCoreController());
  });

  tearDown(() async {
    await appServices.reset();
  });

  test('unavailable skill cannot be enabled through the controller', () async {
    appServices.put(_snapshots(AppHostPlatform.web));
    final controller = SkillsController();

    await controller.toggle('bluetooth', true);

    expect(controller.enabled, isNot(contains('bluetooth')));
  });

  test('an already-enabled unavailable skill can still be disabled', () async {
    appServices.put(_snapshots(AppHostPlatform.web));
    final controller = SkillsController();
    controller.enabled.assignAll(<String>{'bluetooth'});

    await controller.toggle('bluetooth', false);

    expect(controller.enabled, isNot(contains('bluetooth')));
    expect(
      await appServices.find<AgentRuntimeRegistry>().readEnabledSkills('self'),
      isNot(contains('bluetooth')),
    );
  });

  test('projection writes both optional IDs in one persisted set', () async {
    appServices.put(_snapshots(AppHostPlatform.ios));
    final controller = SkillsController();
    controller.enabled.assignAll({'web_search', ...SkillCatalog.coreIds});
    final registry =
        appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
    await controller.toggleGroup('projection', true);
    final ids = SkillUserGroupCatalog.byId('projection')!.skillIds;
    expect(registry.saved, hasLength(1));
    expect(registry.saved.single, containsAll(ids));
    expect(registry.saved.single, contains('web_search'));
    expect(controller.isGroupEnabled('projection'), isTrue);
    await controller.toggleGroup('projection', false);
    expect(registry.saved, hasLength(2));
    expect(registry.saved.last.intersection(ids.toSet()), isEmpty);
    expect(registry.saved.last, containsAll(SkillCatalog.coreIds));
    expect(controller.isGroupEnabled('projection'), isFalse);
    expect(
      await registry.readEnabledSkills('self'),
      isNot(contains(ids.first)),
    );
  });

  test(
    'group enable fails closed while unavailable partial state can turn off',
    () async {
      appServices.put(_snapshots(AppHostPlatform.web));
      final controller = SkillsController();
      final registry =
          appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
      controller.enabled.assignAll({'bluetooth', 'web_search'});
      await controller.toggleGroup('projection', true);
      expect(registry.saved, isEmpty);
      expect(controller.enabled, isNot(contains('ble_yoturetoys_projector')));
      await controller.toggleGroup('projection', false);
      expect(registry.saved, hasLength(1));
      expect(controller.enabled, {'web_search'});
    },
  );

  test('core and unknown groups cannot be disabled or persisted', () async {
    final controller = SkillsController();
    controller.enabled.assignAll(SkillCatalog.coreIds);
    final registry =
        appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
    await controller.toggleGroup('creation', false);
    await controller.toggleGroup('memory', false);
    await controller.toggleGroup('persona', false);
    await controller.toggleGroup('unknown', true);
    await controller.toggle('freeform_surface', false);
    expect(registry.saved, isEmpty);
    expect(controller.enabled, SkillCatalog.coreIds);
  });

  test('failed group write restores the previous preference set', () async {
    final registry =
        appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
    await registry.setEnabledSkills('self', {'web_search'});
    final previous = await registry.readEnabledSkills('self');
    final controller = SkillsController()..enabled.assignAll(previous);
    registry.fail = true;
    await expectLater(
      controller.toggleGroup('projection', true),
      throwsStateError,
    );
    expect(controller.enabled, previous);
    expect(controller.isApplying.value, isFalse);
  });

  test(
    'reload failure retains committed preferences for subsequent changes',
    () async {
      final registry =
          appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
      await registry.setEnabledSkills('self', {'web_search'});
      final controller = SkillsController()
        ..enabled.assignAll(await registry.readEnabledSkills('self'));
      registry.failAfterWrite = true;
      await expectLater(
        controller.toggleGroup('projection', true),
        throwsStateError,
      );
      final actual = await registry.readEnabledSkills('self');
      expect(
        actual,
        containsAll({'web_search', 'bluetooth', 'ble_yoturetoys_projector'}),
      );
      expect(controller.enabled, actual);
      expect(controller.isApplying.value, isFalse);
      registry.failAfterWrite = false;
      await controller.toggleGroup('web_search', false);
      expect(
        controller.enabled,
        containsAll({'bluetooth', 'ble_yoturetoys_projector'}),
      );
      expect(
        await registry.readEnabledSkills('self'),
        isNot(contains('web_search')),
      );
      expect(
        registry.saved.last,
        containsAll({'bluetooth', 'ble_yoturetoys_projector'}),
      );
    },
  );

  test(
    'write and recovery read failure retain the last known preference set',
    () async {
      final registry =
          appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
      final previous = {'web_search', ...SkillCatalog.coreIds};
      final controller = SkillsController()..enabled.assignAll(previous);
      registry.fail = true;
      registry.failRead = true;
      await expectLater(
        controller.toggleGroup('projection', true),
        throwsStateError,
      );
      expect(registry.readCalls, 1);
      expect(controller.enabled, previous);
      expect(controller.isApplying.value, isFalse);
    },
  );

  for (final readFails in [false, true]) {
    test(
      'account replacement fences late recovery when readFails=$readFails',
      () async {
        final oldRegistry =
            appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
        final oldController = SkillsController()
          ..enabled.assignAll({'web_search', ...SkillCatalog.coreIds});
        final recovery = Completer<Set<String>>();
        oldRegistry.initialRead = recovery;
        oldRegistry.failAfterWrite = true;
        final pending = oldController.toggleGroup('projection', true);
        final observedFailure = expectLater(pending, throwsStateError);
        // Wait for the persisted write to fail and enter the asynchronous re-read.
        while (oldRegistry.readCalls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        final admitted = {...oldController.enabled};
        final replacement =
            appServices.put<AgentRuntimeRegistry>(
                  _RecordingRegistry(storageKeyPrefix: 'replacement'),
                  overrideAbstract: true,
                )
                as _RecordingRegistry;
        final currentController = SkillsController()
          ..enabled.assignAll({'bluetooth'});
        if (readFails) {
          recovery.completeError(StateError('Retired account read failed'));
        } else {
          recovery.complete({'web_search'});
        }
        await observedFailure;
        expect(oldController.enabled, admitted);
        expect(currentController.enabled, {'bluetooth'});
        expect(replacement.saved, isEmpty);
        await oldController.toggleGroup('web_search', false);
        expect(oldRegistry.saved, hasLength(1));
        expect(replacement.saved, isEmpty);
      },
    );
  }

  test('closed controller ignores a late recovery read', () async {
    final registry =
        appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
    final recovery = Completer<Set<String>>();
    registry.initialRead = recovery;
    registry.failAfterWrite = true;
    final controller = SkillsController()..enabled.assignAll({'web_search'});
    final pending = controller.toggleGroup('projection', true);
    final observedFailure = expectLater(pending, throwsStateError);
    while (registry.readCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final admitted = {...controller.enabled};
    controller.closeLifecycle();
    recovery.complete({'web_search'});
    await observedFailure;
    expect(controller.enabled, admitted);
  });

  test(
    'initial loading cannot overwrite a fast group toggle or old preferences',
    () async {
      final registry =
          appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
      final initial = Completer<Set<String>>();
      registry.initialRead = initial;
      final controller = appServices.put(SkillsController());
      expect(controller.isApplying.value, isTrue);
      await controller.toggleGroup('projection', true);
      expect(registry.saved, isEmpty);
      initial.complete({'web_search', ...SkillCatalog.coreIds});
      await Future<void>.delayed(Duration.zero);
      expect(controller.isApplying.value, isFalse);
      expect(controller.enabled, contains('web_search'));
      await controller.toggleGroup('projection', true);
      expect(registry.saved, hasLength(1));
      expect(
        registry.saved.single,
        containsAll({'web_search', 'bluetooth', 'ble_yoturetoys_projector'}),
      );
    },
  );

  test('retired controller rejects late loading and grouped writes', () async {
    final registry =
        appServices.find<AgentRuntimeRegistry>() as _RecordingRegistry;
    final initial = Completer<Set<String>>();
    registry.initialRead = initial;
    final controller = SkillsController()..initializeLifecycle();
    controller.closeLifecycle();
    initial.complete({'web_search'});
    await Future<void>.delayed(Duration.zero);
    expect(controller.enabled, isEmpty);
    await controller.toggleGroup('projection', true);
    expect(registry.saved, isEmpty);
  });
}

AppCapabilitySnapshotService _snapshots(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: AppRouteCatalog.destinations.map(
          (destination) => destination.id,
        ),
        skillIds: SkillCatalog.all.map((spec) => spec.id),
        skillRequirements: SkillCatalog.capabilityRequirements,
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );
