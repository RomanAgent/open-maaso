import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_texture.dart';

void main() {
  testWidgets('default Mac Unity view retains its loading placeholder', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(
        const MaterialApp(home: UnityAvatarView(includeWorld: true)),
      );
      await tester.pump();
      expect(
        tester
            .widget<UnityAvatarView>(find.byType(UnityAvatarView))
            .showLoadingPlaceholder,
        isTrue,
      );
      expect(find.byIcon(Icons.view_in_ar_rounded), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'Mac World captures its whole viewport, resizes, and yields to pet',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final runtime = ActiveAvatarRuntime()..register(_ReadyRuntime());
      final gateway = _SceneGateway();
      final portal = AvatarPortalCoordinator(
        avatarRuntime: runtime,
        gateway: gateway,
      );
      Future<void> pump({
        double width = 400,
        bool sceneActive = true,
        bool active = true,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(devicePixelRatio: 2),
              child: AvatarPortalScope(
                portal: portal,
                avatarRuntime: runtime,
                sceneSurfaceActive: sceneActive,
                child: Center(
                  child: SizedBox(
                    width: width,
                    height: 600,
                    child: UnityAvatarView(
                      includeWorld: true,
                      viewportActive: active,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
      }

      try {
        await pump(active: false);
        expect(gateway.requests, isEmpty);
        await pump();
        expect(gateway.requests.single, (
          includeWorld: true,
          width: 800,
          height: 1200,
        ));
        expect(tester.getSize(find.byType(Texture)), const Size(400, 600));
        expect(
          tester
              .widget<Transform>(
                find.byKey(AvatarPortalTexture.appleOrientationCorrectionKey),
              )
              .transform
              .storage[5],
          -1,
        );
        await pump(width: 800);
        expect(gateway.requests.last, (
          includeWorld: true,
          width: 1600,
          height: 1200,
        ));
        expect(gateway.released, <int>[1]);
        expect(tester.getSize(find.byType(Texture)), const Size(800, 600));
        await pump(width: 800, sceneActive: false);
        final petCapture = portal.summon();
        await tester.pump();
        await petCapture;
        expect(gateway.requests.last.includeWorld, isFalse);
        expect(
          find.byType(Texture),
          findsNothing,
          reason: 'World cannot render the pet lease into its room viewport.',
        );
        await pump(width: 800);
        expect(gateway.requests.last.includeWorld, isTrue);
        expect(tester.getSize(find.byType(Texture)), const Size(800, 600));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        portal.dispose();
        unawaited(gateway.close());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('Mac default Unity view preserves compact avatar-only capture', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final runtime = ActiveAvatarRuntime()..register(_ReadyRuntime());
    final gateway = _SceneGateway();
    final portal = AvatarPortalCoordinator(
      avatarRuntime: runtime,
      gateway: gateway,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: AvatarPortalScope(
            portal: portal,
            avatarRuntime: runtime,
            child: const UnityAvatarView(),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
      expect(gateway.requests.single, (
        includeWorld: false,
        width: null,
        height: null,
      ));
      expect(tester.getSize(find.byType(Texture)), const Size(160, 280));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      portal.dispose();
      unawaited(gateway.close());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final includeWorld in <bool>[false, true]) {
    testWidgets(
      'inactive Mac window does not acquire or render shared capture world=$includeWorld',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final runtime = ActiveAvatarRuntime()..register(_ReadyRuntime());
        final gateway = _SceneGateway();
        final portal = AvatarPortalCoordinator(
          avatarRuntime: runtime,
          gateway: gateway,
        );
        Future<void> pump(bool active) async {
          await tester.pumpWidget(
            MaterialApp(
              home: AvatarPortalScope(
                portal: portal,
                avatarRuntime: runtime,
                sceneSurfaceActive: active,
                child: UnityAvatarView(includeWorld: includeWorld),
              ),
            ),
          );
          for (var i = 0; i < 8; i++) {
            await tester.pump();
          }
        }

        try {
          await pump(false);
          expect(gateway.requests, isEmpty);
          final externalCapture = portal.summon(
            includeWorld: includeWorld,
            viewportWidth: includeWorld ? 800 : null,
            viewportHeight: includeWorld ? 600 : null,
          );
          await tester.pump();
          await externalCapture;
          await tester.pump();
          expect(find.byType(Texture), findsNothing);
          expect(gateway.requests, hasLength(1));
          expect(gateway.released, isEmpty);

          await pump(true);
          expect(find.byType(Texture), findsOneWidget);
          final requestCount = gateway.requests.length;
          final releaseCount = gateway.released.length;
          await pump(false);
          expect(find.byType(Texture), findsNothing);
          expect(gateway.requests, hasLength(requestCount));
          expect(gateway.released, hasLength(releaseCount));
          expect(portal.phase, AvatarPortalPhase.visible);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          portal.dispose();
          unawaited(gateway.close());
          await tester.pump();
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets(
    'leaving Mac World while resume awaits cannot acquire a preview',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final runtime = ActiveAvatarRuntime()..register(_ReadyRuntime());
      final gateway = _DelayedResumeGateway();
      final portal = AvatarPortalCoordinator(
        avatarRuntime: runtime,
        gateway: gateway,
      );
      Future<void> pump(bool active) async {
        await tester.pumpWidget(
          MaterialApp(
            home: AvatarPortalScope(
              portal: portal,
              avatarRuntime: runtime,
              sceneSurfaceActive: active,
              child: const UnityAvatarView(),
            ),
          ),
        );
        await tester.pump();
      }

      try {
        final externalCapture = portal.summon(
          includeWorld: true,
          viewportWidth: 800,
          viewportHeight: 600,
        );
        await tester.pump();
        await externalCapture;
        await portal.suspend();
        await pump(true);
        expect(gateway.resumeStarted.isCompleted, isTrue);
        await pump(false);
        gateway.allowResume.complete();
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(gateway.requests, hasLength(1));
        expect(gateway.released, isEmpty);
        expect(portal.capturesWorld, isTrue);
        expect(find.byType(Texture), findsNothing);
      } finally {
        if (!gateway.allowResume.isCompleted) gateway.allowResume.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        portal.dispose();
        unawaited(gateway.close());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('Mac inactive preview cannot change shared desktop runtime', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await appServices.reset();
    final recording =
        appServices.put<UnityAvatarRuntime>(_RecordingUnityRuntime())
            as _RecordingUnityRuntime;
    appServices.put(ActiveAvatarRuntime()..register(recording));
    final runtime = ActiveAvatarRuntime()..register(_ReadyRuntime());
    final gateway = _SceneGateway();
    final portal = AvatarPortalCoordinator(
      avatarRuntime: runtime,
      gateway: gateway,
    );
    Future<void> pump(bool active, double top) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AvatarPortalScope(
            portal: portal,
            avatarRuntime: runtime,
            sceneSurfaceActive: active,
            child: UnityAvatarView(
              viewportSafeArea: AvatarViewportSafeArea(top: top, bottom: .2),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
    }

    try {
      await pump(false, .1);
      await tester.tap(find.byType(UnityAvatarView));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(recording.calls, isEmpty);
      await pump(true, .1);
      expect(recording.calls, containsAll(<String>['prepare', 'safeArea']));
      await tester.tap(find.byType(UnityAvatarView));
      expect(recording.calls, contains('tap'));
      recording.calls.clear();
      await pump(false, .3);
      await tester.tap(find.byType(UnityAvatarView));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(recording.calls, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      portal.dispose();
      unawaited(gateway.close());
      await tester.pump();
      await appServices.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS view retains preparation and lifecycle outside Mac scope', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await appServices.reset();
    final recording = _RecordingUnityRuntime();
    appServices.put<UnityAvatarRuntime>(recording);
    appServices.put(ActiveAvatarRuntime()..register(recording));
    final runtime = ActiveAvatarRuntime()..register(_ReadyRuntime());
    final gateway = _SceneGateway();
    final portal = AvatarPortalCoordinator(
      avatarRuntime: runtime,
      gateway: gateway,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: AvatarPortalScope(
            portal: portal,
            avatarRuntime: runtime,
            sceneSurfaceActive: false,
            child: const UnityAvatarView(
              viewportSafeArea: AvatarViewportSafeArea(top: .1, bottom: .2),
            ),
          ),
        ),
      );
      expect(recording.calls, containsAll(<String>['prepare', 'safeArea']));
      await tester.tap(find.byType(UnityAvatarView));
      expect(recording.calls, contains('tap'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(recording.calls, containsAll(<String>['pause', 'resume']));
      expect(gateway.requests, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      portal.dispose();
      unawaited(gateway.close());
      await tester.pump();
      await appServices.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _RecordingUnityRuntime extends UnityAvatarRuntime {
  final calls = <String>[];
  @override
  Future<void> prepareView() async => calls.add('prepare');
  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async =>
      calls.add('safeArea');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> reactToScreenTap({
    required double normalizedX,
    required double normalizedY,
  }) async => calls.add('tap');
}

class _DelayedResumeGateway extends _SceneGateway {
  final resumeStarted = Completer<void>();
  final allowResume = Completer<void>();
  @override
  Future<void> resume(int generation) async {
    resumeStarted.complete();
    await allowResume.future;
  }
}

class _ReadyRuntime extends AvatarRuntime {
  @override
  final backendKind = AvatarBackendKind.unity;
  @override
  final isReady = true.obs;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SceneGateway implements AvatarPortalGateway {
  final _events = StreamController<AvatarPortalEvent>.broadcast(sync: true);
  final requests = <({bool includeWorld, int? width, int? height})>[];
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
    requests.add((
      includeWorld: includeWorld,
      width: viewportWidth,
      height: viewportHeight,
    ));
    final lease = AvatarPortalLease(
      textureId: generation + 70,
      width: viewportWidth ?? 320,
      height: viewportHeight ?? 560,
      generation: generation,
    );
    scheduleMicrotask(
      () => _events.add(
        AvatarPortalEvent.firstFrame(
          generation: generation,
          textureId: lease.textureId,
          width: lease.width,
          height: lease.height,
        ),
      ),
    );
    return lease;
  }

  @override
  Future<void> release(int generation) async {
    released.add(generation);
  }

  @override
  Future<void> resume(int generation) async {}
  @override
  Future<void> suspend(int generation) async {}
  @override
  Future<void> close() => _events.close();
}
