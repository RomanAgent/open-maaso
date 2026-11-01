import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAvatarRuntime extends AvatarRuntime {
  FakeAvatarRuntime(this.backendKind);

  @override
  final AvatarBackendKind backendKind;

  @override
  final isReady = false.obs;

  int expressions = 0;
  String? failingModelUrl;
  final loadFailuresRemaining = <String, int>{};
  final loadAttempts = <String>[];
  final loadBarriers = <String, Completer<void>>{};
  final loadedAvatars = <String>[];
  final loadedConfigs = <Map<String, dynamic>>[];

  @override
  Future<void> clearGaze() async {}

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {
    loadAttempts.add(modelUrl);
    await loadBarriers[modelUrl]?.future;
    final remainingFailures = loadFailuresRemaining[modelUrl] ?? 0;
    if (remainingFailures > 0) {
      loadFailuresRemaining[modelUrl] = remainingFailures - 1;
      throw StateError('Failed to load $modelUrl');
    }
    if (modelUrl == failingModelUrl) {
      throw StateError('Failed to load $modelUrl');
    }
    loadedAvatars.add(modelUrl);
    loadedConfigs.add(config);
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> playAnimationClip(
    String id, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {}

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {}

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {
    expressions++;
  }

  @override
  Future<void> setFraming(String mode) async {}

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async {}

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {}

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) async {}

  @override
  Future<void> setGaze(AvatarGaze gaze) async {}

  @override
  Future<void> setMouthOpen(double value) async {}

  @override
  Future<void> startLipSync(
    List<double> envelope, {
    int frameRate = 30,
  }) async {}

  @override
  Future<void> stopLipSync() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(appServices.reset);

  test('active runtime defaults to Unity when registered', () {
    final active = ActiveAvatarRuntime();
    final unity = FakeAvatarRuntime(AvatarBackendKind.unity);

    active.register(unity);

    expect(active.backend.value, AvatarBackendKind.unity);
    expect(active.current, same(unity));
  });

  test('active runtime keeps Unity selected when reselected', () {
    final active = ActiveAvatarRuntime();
    final unity = FakeAvatarRuntime(AvatarBackendKind.unity);

    active.register(unity);
    active.select(AvatarBackendKind.unity);

    expect(active.backend.value, AvatarBackendKind.unity);
    expect(active.current, same(unity));
  });

  test(
    'avatar config defaults selected id to the bundled Unity agent',
    () async {
      SharedPreferences.setMockInitialValues({});
      await SpUtils.init();

      final active = appServices.put(ActiveAvatarRuntime());
      final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
      active.register(unity);

      final service = AvatarConfigService().init();

      expect(service.selectedId.value, 'agent');
      expect(service.selected.id, 'agent');
      expect(active.backend.value, AvatarBackendKind.unity);
      expect(active.current, same(unity));
    },
  );

  for (final legacyId in const [
    'sapphy',
    'sapphy_vrm',
    'unity_sapphy',
    'hiyori',
    'mark',
  ]) {
    test(
      'saved retired avatar selection $legacyId falls back to the default Unity agent',
      () async {
        SharedPreferences.setMockInitialValues({
          'avatar.selected_id': legacyId,
        });
        await SpUtils.init();

        final active = appServices.put(ActiveAvatarRuntime());
        final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
        active.register(unity);

        final service = AvatarConfigService().init();

        expect(service.selectedId.value, 'agent');
        expect(service.selected.id, 'agent');
        expect(service.selected.backend, AvatarBackendKind.unity);
        expect(active.backend.value, AvatarBackendKind.unity);
        expect(active.current, same(unity));
      },
    );
  }

  test('default agent option points at the VRM1 companion Unity scene', () {
    final service = AvatarConfigService();
    final agent = service.catalog.singleWhere((option) => option.id == 'agent');

    expect(agent.id, 'agent');
    expect(agent.name, 'Agent');
    expect(agent.backend, AvatarBackendKind.unity);
    expect(agent.modelUrl, 'unity://masso/avatar_agent');
    expect(agent.config, containsPair('scene', 'MaasoAvatar/Scenes/Companion'));
    expect(agent.config, containsPair('avatar', 'agent'));
    expect(agent.config, containsPair('background', 'transparent'));
    expect(agent.config, containsPair('framing', 'front_full_body'));
    expect(agent.config, isNot(contains('resource')));
    expect(agent.isDefault, isTrue);
  });

  test('avatar catalog is Unity-only', () {
    final service = AvatarConfigService();

    expect(service.catalog, hasLength(1));
    expect(service.catalog.map((a) => a.backend).toSet(), {
      AvatarBackendKind.unity,
    });
  });

  test(
    'renderer-specific initial apply sends the VRM1 companion scene',
    () async {
      SharedPreferences.setMockInitialValues({'avatar.selected_id': 'agent'});
      await SpUtils.init();

      final active = appServices.put(ActiveAvatarRuntime());
      final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
      active.register(unity);

      final service = AvatarConfigService().init();

      await service.applyForBackend(AvatarBackendKind.unity);
      expect(unity.loadedAvatars, ['unity://masso/avatar_agent']);
      expect(
        unity.loadedConfigs.single,
        containsPair('scene', 'MaasoAvatar/Scenes/Companion'),
      );
      expect(unity.loadedConfigs.single, containsPair('avatar', 'agent'));
      expect(
        unity.loadedConfigs.single,
        containsPair('framing', 'front_full_body'),
      );
    },
  );

  test(
    'failed avatar switch preserves the working selection and Unity runtime',
    () async {
      SharedPreferences.setMockInitialValues({});
      await SpUtils.init();

      final active = appServices.put(ActiveAvatarRuntime());
      final unity = FakeAvatarRuntime(AvatarBackendKind.unity)
        ..failingModelUrl = 'unity://masso/avatar_creator';
      active.register(unity);
      final service = AvatarConfigService(
        initialCatalog: const [
          AvatarOption(
            id: 'agent',
            name: 'Agent',
            backend: AvatarBackendKind.unity,
            modelUrl: 'unity://masso/avatar_agent',
            isDefault: true,
          ),
          AvatarOption(
            id: 'creator',
            name: 'Creator',
            backend: AvatarBackendKind.unity,
            modelUrl: 'unity://masso/avatar_creator',
          ),
        ],
      ).init();

      await expectLater(service.select('creator'), throwsStateError);

      expect(service.selectedId.value, 'agent');
      expect(SpUtils.getString('avatar.selected_id'), isEmpty);
      expect(active.backend.value, AvatarBackendKind.unity);
      expect(active.current, same(unity));
    },
  );

  test(
    'reviewed models replace stale remote entries but retain the built-in',
    () {
      final service = AvatarConfigService();

      service.replaceReviewedOptions(const [
        AvatarOption(
          id: 'reviewed-model-24',
          name: 'Creator',
          backend: AvatarBackendKind.unity,
          modelUrl: 'https://cdn.example.com/creator.bundle',
          remoteModelId: 24,
          modelSource: 'community',
        ),
      ]);
      service.replaceReviewedOptions(const [
        AvatarOption(
          id: 'reviewed-model-25',
          name: 'Performer',
          backend: AvatarBackendKind.unity,
          modelUrl: 'https://cdn.example.com/performer.bundle',
          remoteModelId: 25,
          modelSource: 'community',
        ),
      ]);

      expect(service.catalog.map((option) => option.id), [
        'agent',
        'reviewed-model-25',
      ]);
    },
  );

  test('saved reviewed selection rehydrates after catalog loading', () async {
    SharedPreferences.setMockInitialValues({
      'avatar.selected_id': 'reviewed-model-25',
    });
    await SpUtils.init();

    final active = appServices.put(ActiveAvatarRuntime());
    final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
    active.register(unity);
    final service = AvatarConfigService().init();

    expect(service.selectedId.value, 'agent');

    final restored = service.replaceReviewedOptions(const [
      AvatarOption(
        id: 'reviewed-model-25',
        name: 'Performer',
        backend: AvatarBackendKind.unity,
        modelUrl: 'https://cdn.example.com/performer.bundle',
        remoteModelId: 25,
        modelSource: 'official',
      ),
    ]);

    expect(restored, isTrue);
    expect(service.selectedId.value, 'reviewed-model-25');
    expect(service.selected.remoteModelId, 25);

    await service.applyInitial();

    expect(unity.loadedAvatars, ['https://cdn.example.com/performer.bundle']);
  });

  test(
    'coordinator-null reviewed selection fails closed before local effects',
    () async {
      SharedPreferences.setMockInitialValues({});
      await SpUtils.init();

      final active = appServices.put(ActiveAvatarRuntime());
      final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
      active.register(unity);
      var persistenceCalls = 0;
      final service = AvatarConfigService(
        initialCatalog: _remoteAvatarCatalog,
        persistSelection: (key, selectedId) async {
          persistenceCalls++;
          return true;
        },
      ).init();

      await expectLater(
        service.select(_remoteA.id),
        throwsA(
          isA<AvatarAuthoritativeSelectionUnavailableException>().having(
            (error) => error.code,
            'code',
            'avatar_selection_coordinator_required',
          ),
        ),
      );

      expect(unity.loadAttempts, isEmpty);
      expect(persistenceCalls, 0);
      expect(service.selectedId.value, _bundledAvatar.id);
      expect(service.isSwitching.value, isFalse);
    },
  );

  group('persisted remote avatar capability snapshot gate', () {
    test(
      'denied persisted remote apply skips the remote load and restores default',
      () async {
        SharedPreferences.setMockInitialValues({
          'avatar.selected_id': _remoteA.id,
        });
        await SpUtils.init();
        final snapshots = _capabilitySnapshots(AppHostPlatform.web);
        final active = appServices.put(ActiveAvatarRuntime());
        final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
        active.register(unity);
        final persistedValues = <String?>[];
        final service = AvatarConfigService(
          initialCatalog: _remoteAvatarCatalog,
          capabilitySnapshots: snapshots,
          persistSelection: (key, selectedId) async {
            persistedValues.add(selectedId);
            return true;
          },
        ).init();

        await expectLater(
          service.applyInitial(),
          throwsA(
            isA<AvatarRemoteModelCapabilityException>().having(
              (error) => error.code,
              'code',
              'capability_unavailable',
            ),
          ),
        );

        expect(unity.loadAttempts, [_bundledAvatar.modelUrl]);
        expect(persistedValues, [null]);
        expect(service.selectedId.value, _bundledAvatar.id);
        expect(service.isSwitching.value, isFalse);
      },
    );

    test(
      'stale persisted remote apply rolls back after Unity settles',
      () async {
        SharedPreferences.setMockInitialValues({
          'avatar.selected_id': _remoteA.id,
        });
        await SpUtils.init();
        final snapshots = _capabilitySnapshots(AppHostPlatform.macos);
        final active = appServices.put(ActiveAvatarRuntime());
        final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
        final loadBarrier = Completer<void>();
        unity.loadBarriers[_remoteA.modelUrl] = loadBarrier;
        active.register(unity);
        final persistedValues = <String?>[];
        final service = AvatarConfigService(
          initialCatalog: _remoteAvatarCatalog,
          capabilitySnapshots: snapshots,
          persistSelection: (key, selectedId) async {
            persistedValues.add(selectedId);
            return true;
          },
        ).init();

        final apply = service.applyInitial();
        final applyExpectation = expectLater(
          apply,
          throwsA(isA<AvatarRemoteModelCapabilityException>()),
        );
        await _waitUntil(() => unity.loadAttempts.contains(_remoteA.modelUrl));
        _refreshCapabilities(snapshots, AppHostPlatform.web, generation: 1);
        loadBarrier.complete();

        await applyExpectation;
        await _waitUntilEventually(
          () =>
              unity.loadedAvatars.isNotEmpty &&
              unity.loadedAvatars.last == _bundledAvatar.modelUrl &&
              service.isSwitching.value == false,
        );
        expect(unity.loadedAvatars, contains(_remoteA.modelUrl));
        expect(unity.loadedAvatars.last, _bundledAvatar.modelUrl);
        expect(persistedValues, isNotEmpty);
        expect(persistedValues, everyElement(isNull));
        expect(service.selectedId.value, _bundledAvatar.id);
        expect(service.isSwitching.value, isFalse);
      },
    );

    test('restoring the bundled default remains ungated', () async {
      SharedPreferences.setMockInitialValues({});
      await SpUtils.init();
      final snapshots = _capabilitySnapshots(AppHostPlatform.web);
      final active = appServices.put(ActiveAvatarRuntime());
      final unity = FakeAvatarRuntime(AvatarBackendKind.unity);
      active.register(unity);
      final service = AvatarConfigService(
        initialCatalog: _remoteAvatarCatalog,
        capabilitySnapshots: snapshots,
      ).init();
      service.selectedId.value = _remoteA.id;

      await service.select(_bundledAvatar.id);
      await _drainMicrotasks();

      expect(service.selectedId.value, _bundledAvatar.id);
      expect(unity.loadedAvatars, [_bundledAvatar.modelUrl]);
    });
  });
}

const _bundledAvatar = AvatarOption(
  id: 'agent',
  name: 'Agent',
  backend: AvatarBackendKind.unity,
  modelUrl: 'unity://masso/avatar_agent',
  isDefault: true,
);

const _remoteA = AvatarOption(
  id: 'reviewed-model-24',
  name: 'Creator',
  backend: AvatarBackendKind.unity,
  modelUrl: 'https://cdn.example.com/creator.bundle',
  remoteModelId: 24,
);

const _remoteB = AvatarOption(
  id: 'reviewed-model-25',
  name: 'Performer',
  backend: AvatarBackendKind.unity,
  modelUrl: 'https://cdn.example.com/performer.bundle',
  remoteModelId: 25,
);

const _remoteAvatarCatalog = <AvatarOption>[_bundledAvatar, _remoteA, _remoteB];

AppCapabilitySnapshotService _capabilitySnapshots(AppHostPlatform platform) {
  return AppCapabilitySnapshotService(
    resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const []),
    initialContext: AppCapabilitySnapshotContext(
      hostPlatform: platform,
      rolloutGeneration: 0,
    ),
  );
}

void _refreshCapabilities(
  AppCapabilitySnapshotService snapshots,
  AppHostPlatform platform, {
  required int generation,
}) {
  snapshots.refresh(
    AppCapabilitySnapshotContext(
      hostPlatform: platform,
      rolloutGeneration: generation,
    ),
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached');
}

Future<void> _waitUntilEventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition was not reached before the timeout');
}

Future<void> _drainMicrotasks() async {
  for (var attempt = 0; attempt < 10; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}
