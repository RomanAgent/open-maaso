import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

void main() {
  test(
    'scene configuration replaces leases and queues a pending viewport change',
    () async {
      final runtime = _ReadyAvatarRuntime()..isReady.value = true;
      final gateway = _FakeAvatarPortalGateway();
      final coordinator = AvatarPortalCoordinator(
        avatarRuntime: ActiveAvatarRuntime()..register(runtime),
        gateway: gateway,
      );
      final first = coordinator.summon(
        includeWorld: true,
        viewportWidth: 800,
        viewportHeight: 1200,
      );
      expect(
        identical(
          first,
          coordinator.summon(
            includeWorld: true,
            viewportWidth: 800,
            viewportHeight: 1200,
          ),
        ),
        isTrue,
      );
      final resized = coordinator.summon(
        includeWorld: true,
        viewportWidth: 1080,
        viewportHeight: 720,
      );
      Future<void> completeFrame(int count) async {
        await _until(
          () => gateway.acquireCalls == count && coordinator.lease != null,
        );
        final lease = coordinator.lease!;
        gateway.emit(
          AvatarPortalEvent.firstFrame(
            generation: lease.generation,
            textureId: lease.textureId,
            width: lease.width,
            height: lease.height,
          ),
        );
      }

      await completeFrame(1);
      await first;
      await completeFrame(2);
      await resized;
      expect(gateway.released, <int>[1]);
      expect(gateway.acquiredScenes, <Object>[
        (includeWorld: true, width: 800, height: 1200),
        (includeWorld: true, width: 1080, height: 720),
      ]);
      expect(coordinator.capturesWorld, isTrue);
      expect(
        coordinator.usesCaptureConfiguration(
          profile: AvatarPortalProfile.compactHigh,
          targetFps: 30,
        ),
        isFalse,
      );
      expect(
        coordinator.usesCaptureConfiguration(
          profile: AvatarPortalProfile.compactHigh,
          targetFps: 30,
          includeWorld: true,
          viewportWidth: 1080,
          viewportHeight: 720,
        ),
        isTrue,
      );
      final avatarOnly = coordinator.summon();
      await completeFrame(3);
      await avatarOnly;
      expect(coordinator.capturesWorld, isFalse);
      expect(gateway.released, <int>[1, 2]);
      await coordinator.close();
      await gateway.close();
    },
  );

  test(
    'invalid scene request cannot acquire or replace the current lease',
    () async {
      final runtime = _ReadyAvatarRuntime()..isReady.value = true;
      final gateway = _FakeAvatarPortalGateway();
      final coordinator = AvatarPortalCoordinator(
        avatarRuntime: ActiveAvatarRuntime()..register(runtime),
        gateway: gateway,
      );
      await expectLater(
        coordinator.summon(
          includeWorld: true,
          viewportWidth: 3841,
          viewportHeight: 1600,
        ),
        throwsA(isA<AvatarPortalFailure>()),
      );
      expect(gateway.acquireCalls, 0);
      expect(coordinator.phase, AvatarPortalPhase.dormant);
      await coordinator.close();
      await gateway.close();
    },
  );

  test(
    'summon coalesces callers and waits for the matching first frame',
    () async {
      final runtime = _ReadyAvatarRuntime()..isReady.value = true;
      final activeAvatar = ActiveAvatarRuntime()..register(runtime);
      final gateway = _FakeAvatarPortalGateway();
      final coordinator = AvatarPortalCoordinator(
        avatarRuntime: activeAvatar,
        gateway: gateway,
      );

      final first = coordinator.summon();
      final second = coordinator.summon();
      expect(identical(first, second), isTrue);
      await _until(() => gateway.acquireCalls == 1);
      expect(coordinator.phase, AvatarPortalPhase.waitingForFirstFrame);
      expect(coordinator.lease?.textureId, 101);

      gateway.emit(
        const AvatarPortalEvent.firstFrame(
          generation: 99,
          textureId: 101,
          width: 320,
          height: 560,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.phase, AvatarPortalPhase.waitingForFirstFrame);

      gateway.emit(
        const AvatarPortalEvent.firstFrame(
          generation: 1,
          textureId: 101,
          width: 320,
          height: 560,
        ),
      );
      final lease = await first;

      expect(lease.textureId, 101);
      expect(coordinator.phase, AvatarPortalPhase.visible);
      expect(runtime.loadCalls, 0);

      await coordinator.close();
      await gateway.close();
    },
  );

  test(
    'summon waits for the existing Unity runtime instead of loading another',
    () async {
      final runtime = _ReadyAvatarRuntime();
      final activeAvatar = ActiveAvatarRuntime()..register(runtime);
      final gateway = _FakeAvatarPortalGateway();
      final coordinator = AvatarPortalCoordinator(
        avatarRuntime: activeAvatar,
        gateway: gateway,
        runtimeReadyTimeout: const Duration(seconds: 1),
      );

      final summon = coordinator.summon();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.acquireCalls, 0);
      expect(coordinator.phase, AvatarPortalPhase.preparing);

      runtime.isReady.value = true;
      await _until(() => gateway.acquireCalls == 1);
      gateway.emit(
        const AvatarPortalEvent.firstFrame(
          generation: 1,
          textureId: 101,
          width: 320,
          height: 560,
        ),
      );
      await summon;

      expect(runtime.loadCalls, 0);
      await coordinator.close();
      await gateway.close();
    },
  );

  test(
    'first-frame timeout releases its lease and exposes a retryable failure',
    () async {
      final runtime = _ReadyAvatarRuntime()..isReady.value = true;
      final activeAvatar = ActiveAvatarRuntime()..register(runtime);
      final gateway = _FakeAvatarPortalGateway();
      final coordinator = AvatarPortalCoordinator(
        avatarRuntime: activeAvatar,
        gateway: gateway,
        firstFrameTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        coordinator.summon(),
        throwsA(
          isA<AvatarPortalFailure>().having(
            (failure) => failure.code,
            'code',
            'avatar_portal_first_frame_timeout',
          ),
        ),
      );

      expect(gateway.released, <int>[1]);
      expect(coordinator.phase, AvatarPortalPhase.failed);
      expect(coordinator.lease, isNull);

      await coordinator.close();
      await gateway.close();
    },
  );

  test('suspend and resume preserve the same texture generation', () async {
    final runtime = _ReadyAvatarRuntime()..isReady.value = true;
    final activeAvatar = ActiveAvatarRuntime()..register(runtime);
    final gateway = _FakeAvatarPortalGateway();
    final coordinator = AvatarPortalCoordinator(
      avatarRuntime: activeAvatar,
      gateway: gateway,
    );

    final summon = coordinator.summon();
    await _until(() => gateway.acquireCalls == 1);
    gateway.emit(
      const AvatarPortalEvent.firstFrame(
        generation: 1,
        textureId: 101,
        width: 320,
        height: 560,
      ),
    );
    await summon;

    await coordinator.suspend();
    expect(coordinator.phase, AvatarPortalPhase.suspended);
    expect(gateway.suspended, <int>[1]);
    await coordinator.resume();
    expect(coordinator.phase, AvatarPortalPhase.visible);
    expect(gateway.resumed, <int>[1]);

    await coordinator.close();
    await gateway.close();
  });

  test(
    'capture changes release then acquire a new generation and ignore stale frames',
    () async {
      final runtime = _ReadyAvatarRuntime()..isReady.value = true;
      final activeAvatar = ActiveAvatarRuntime()..register(runtime);
      final gateway = _FakeAvatarPortalGateway();
      final coordinator = AvatarPortalCoordinator(
        avatarRuntime: activeAvatar,
        gateway: gateway,
      );

      final first = coordinator.summon(targetFps: 30);
      await _until(() => gateway.acquireCalls == 1);
      gateway.emit(
        const AvatarPortalEvent.firstFrame(
          generation: 1,
          textureId: 101,
          width: 320,
          height: 560,
        ),
      );
      await first;

      final replacement = coordinator.summon(targetFps: 60);
      await _until(() => gateway.acquireCalls == 2);
      expect(gateway.released, <int>[1]);
      expect(gateway.acquiredTargetFps, <int>[30, 60]);
      expect(coordinator.phase, AvatarPortalPhase.waitingForFirstFrame);

      gateway.emit(
        const AvatarPortalEvent.firstFrame(
          generation: 1,
          textureId: 101,
          width: 320,
          height: 560,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.phase, AvatarPortalPhase.waitingForFirstFrame);

      gateway.emit(
        const AvatarPortalEvent.firstFrame(
          generation: 2,
          textureId: 102,
          width: 320,
          height: 560,
        ),
      );
      final lease = await replacement;
      expect(lease.generation, 2);
      expect(
        coordinator.usesCaptureConfiguration(
          profile: AvatarPortalProfile.compactHigh,
          targetFps: 60,
        ),
        isTrue,
      );

      await coordinator.close();
      await gateway.close();
    },
  );

  test(
    'memory pressure invalidates the active lease without accepting stale frames',
    () async {
      final runtime = _ReadyAvatarRuntime()..isReady.value = true;
      final activeAvatar = ActiveAvatarRuntime()..register(runtime);
      final gateway = _FakeAvatarPortalGateway();
      final coordinator = AvatarPortalCoordinator(
        avatarRuntime: activeAvatar,
        gateway: gateway,
      );

      final summon = coordinator.summon();
      await _until(() => gateway.acquireCalls == 1);
      gateway.emit(
        const AvatarPortalEvent.released(
          generation: 0,
          reason: 'memoryPressure',
        ),
      );

      await expectLater(
        summon,
        throwsA(
          isA<AvatarPortalFailure>().having(
            (failure) => failure.code,
            'code',
            'avatar_portal_released',
          ),
        ),
      );
      expect(coordinator.phase, AvatarPortalPhase.failed);
      expect(coordinator.failure?.message, contains('memory'));

      gateway.emit(
        const AvatarPortalEvent.firstFrame(
          generation: 1,
          textureId: 101,
          width: 320,
          height: 560,
        ),
      );
      expect(coordinator.phase, AvatarPortalPhase.failed);

      await coordinator.close();
      await gateway.close();
    },
  );

  test(
    'release during acquire reports cancellation without an uncaught future',
    () async {
      final uncaught = <Object>[];

      await runZonedGuarded<Future<void>>(() async {
        final runtime = _ReadyAvatarRuntime()..isReady.value = true;
        final activeAvatar = ActiveAvatarRuntime()..register(runtime);
        final gateway = _DelayedAcquireAvatarPortalGateway();
        final coordinator = AvatarPortalCoordinator(
          avatarRuntime: activeAvatar,
          gateway: gateway,
        );

        final summon = coordinator.summon();
        await gateway.acquireStarted.future;
        await coordinator.release();
        gateway.allowAcquire.complete();

        await expectLater(
          summon,
          throwsA(
            isA<AvatarPortalFailure>().having(
              (failure) => failure.code,
              'code',
              'avatar_portal_cancelled',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await coordinator.close();
        await gateway.close();
      }, (error, _) => uncaught.add(error));

      expect(uncaught, isEmpty);
    },
  );
}

class _DelayedAcquireAvatarPortalGateway extends _FakeAvatarPortalGateway {
  final acquireStarted = Completer<void>();
  final allowAcquire = Completer<void>();

  @override
  Future<AvatarPortalLease> acquire({
    required int generation,
    AvatarPortalProfile profile = AvatarPortalProfile.compactHigh,
    int targetFps = 30,
    bool includeWorld = false,
    int? viewportWidth,
    int? viewportHeight,
  }) async {
    acquireCalls += 1;
    acquireStarted.complete();
    await allowAcquire.future;
    return AvatarPortalLease(
      textureId: 100 + generation,
      width: 320,
      height: 560,
      generation: generation,
    );
  }
}

class _FakeAvatarPortalGateway implements AvatarPortalGateway {
  final _events = StreamController<AvatarPortalEvent>.broadcast(sync: true);
  int acquireCalls = 0;
  final acquiredProfiles = <AvatarPortalProfile>[];
  final acquiredTargetFps = <int>[];
  final acquiredScenes = <({bool includeWorld, int? width, int? height})>[];
  final suspended = <int>[];
  final resumed = <int>[];
  final released = <int>[];

  @override
  Stream<AvatarPortalEvent> get events => _events.stream;

  @override
  Future<AvatarPortalLease> acquire({
    required int generation,
    AvatarPortalProfile profile = AvatarPortalProfile.compactHigh,
    int targetFps = 30,
    bool includeWorld = false,
    int? viewportWidth,
    int? viewportHeight,
  }) async {
    acquireCalls += 1;
    acquiredProfiles.add(profile);
    acquiredTargetFps.add(targetFps);
    acquiredScenes.add((
      includeWorld: includeWorld,
      width: viewportWidth,
      height: viewportHeight,
    ));
    return AvatarPortalLease(
      textureId: 100 + generation,
      width: viewportWidth ?? 320,
      height: viewportHeight ?? 560,
      generation: generation,
    );
  }

  void emit(AvatarPortalEvent event) => _events.add(event);

  @override
  Future<void> suspend(int generation) async => suspended.add(generation);

  @override
  Future<void> resume(int generation) async => resumed.add(generation);

  @override
  Future<void> release(int generation) async => released.add(generation);

  @override
  Future<void> close() => _events.close();
}

class _ReadyAvatarRuntime extends AvatarRuntime {
  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final isReady = false.obs;

  int loadCalls = 0;

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {
    loadCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 20 && !condition(); i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}
