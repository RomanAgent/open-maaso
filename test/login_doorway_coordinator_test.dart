import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';

class _DoorwayAvatar extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  @override
  bool get supportsLoginDoorway => true;
  final calls = <AvatarDoorwayTransition>[];
  final pending = <Completer<void>>[];
  @override
  Future<void> transitionLoginDoorway(AvatarDoorwayTransition request) {
    calls.add(request);
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  void finish() {
    for (final value in pending.toList()) {
      if (!value.isCompleted) value.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String scope;
  late int generation;
  late bool mounted;
  late int claims;
  late LoginDoorwayCoordinator coordinator;
  late _DoorwayAvatar avatar;
  setUp(() {
    scope = 'account-a';
    generation = 1;
    mounted = true;
    claims = 0;
    avatar = _DoorwayAvatar();
    coordinator = LoginDoorwayCoordinator(
      currentScope: () => scope,
      currentGeneration: () => generation,
      accountMounted: () => mounted,
      consumeEntrance: () => ++claims == 1,
      preparationTimeout: const Duration(milliseconds: 100),
      preparationRetryDelay: const Duration(milliseconds: 1),
    );
  });
  tearDown(() {
    coordinator.closeLifecycle();
    avatar.finish();
  });
  Future<void> tick() async {
    await Future<void>.delayed(Duration.zero);
  }

  void start() => coordinator.reconcile(
    renderer: avatar,
    canPresent: () => true,
    reduceMotion: false,
  );

  test(
    'unauthenticated request never claims entrance or starts a renderer',
    () {
      mounted = false;
      coordinator.requestAuthenticated();
      start();
      expect(claims, 0);
      expect(avatar.calls, isEmpty);
      expect(coordinator.active, isFalse);
    },
  );
  test(
    'authenticated intent survives route delay and claims one process entrance',
    () async {
      coordinator.requestAuthenticated();
      final id = coordinator.transitionId;
      coordinator.requestAuthenticated();
      expect(coordinator.transitionId, id);
      expect(claims, 1);
      expect(avatar.calls, isEmpty);
      start();
      expect(avatar.calls.single.phase, AvatarDoorwayPhase.prepare);
      avatar.finish();
      await tick();
      expect(coordinator.phase.value, LoginDoorwayStage.opening);
      avatar.finish();
      await tick();
      expect(coordinator.phase.value, LoginDoorwayStage.entering);
      avatar.finish();
      await tick();
      expect(coordinator.phase.value, LoginDoorwayStage.framing);
      avatar.finish();
      await tick();
      expect(coordinator.completed, isTrue);
      start();
      expect(avatar.calls.map((c) => c.phase), [
        AvatarDoorwayPhase.prepare,
        AvatarDoorwayPhase.open,
        AvatarDoorwayPhase.enter,
        AvatarDoorwayPhase.frame,
      ]);
      expect(avatar.calls.map((c) => c.transitionId).toSet(), {id});
    },
  );
  test(
    'a changed account invalidates a delayed prepare and cannot inherit intent',
    () async {
      coordinator.requestAuthenticated();
      start();
      scope = 'account-b';
      generation++;
      start();
      avatar.finish();
      await tick();
      expect(coordinator.active, isFalse);
      expect(coordinator.phase.value, LoginDoorwayStage.cancelled);
      expect(
        avatar.calls.where((c) => c.phase == AvatarDoorwayPhase.open),
        isEmpty,
      );
      coordinator.requestAuthenticated();
      expect(claims, 2);
      expect(coordinator.phase.value, LoginDoorwayStage.skipped);
    },
  );
  test('reduced motion consumes intent without a camera command', () async {
    coordinator.requestAuthenticated();
    coordinator.reconcile(
      renderer: avatar,
      canPresent: () => true,
      reduceMotion: true,
    );
    await tick();
    expect(coordinator.phase.value, LoginDoorwayStage.skipped);
    expect(avatar.calls, isEmpty);
    expect(claims, 1);
  });

  test(
    'door stays covered until the selected account avatar finishes preparing',
    () async {
      final ready = Completer<void>();
      coordinator.requestAuthenticated();
      coordinator.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
        prepareAvatar: () => ready.future,
      );
      expect(avatar.calls, isEmpty);
      expect(coordinator.covered, isTrue);
      ready.complete();
      await tick();
      expect(avatar.calls.single.phase, AvatarDoorwayPhase.prepare);
      expect(coordinator.covered, isTrue);
      avatar.finish();
      await tick();
      expect(coordinator.covered, isFalse);
    },
  );
  test('a transient native prepare rejection retries before Home', () async {
    coordinator.requestAuthenticated();
    final firstTransition = coordinator.transitionId;
    start();
    avatar.pending.first.completeError(
      const AvatarDoorwayTransitionException('presentation_unavailable'),
    );
    await tick();
    expect(coordinator.phase.value, LoginDoorwayStage.preparing);
    expect(coordinator.active, isTrue);
    expect(coordinator.transitionId, isNot(firstTransition));
    await Future<void>.delayed(const Duration(milliseconds: 3));
    start();
    expect(avatar.calls.last.phase, AvatarDoorwayPhase.prepare);
    expect(avatar.calls, hasLength(2));
    for (final phase in <LoginDoorwayStage>[
      LoginDoorwayStage.opening,
      LoginDoorwayStage.entering,
      LoginDoorwayStage.framing,
      LoginDoorwayStage.completed,
    ]) {
      avatar.finish();
      await tick();
      expect(coordinator.phase.value, phase);
    }
    expect(coordinator.completed, isTrue);
  });

  test(
    'Avatar reload during preparation waits for renderer readiness',
    () async {
      final selectedAvatar = Completer<void>();
      coordinator.requestAuthenticated();
      coordinator.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
        prepareAvatar: () => selectedAvatar.future,
      );
      avatar.isReady.value = false;
      coordinator.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
      );
      expect(coordinator.phase.value, LoginDoorwayStage.preparing);
      selectedAvatar.complete();
      await tick();
      expect(coordinator.phase.value, LoginDoorwayStage.preparing);
      avatar.isReady.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 3));
      start();
      expect(avatar.calls.single.phase, AvatarDoorwayPhase.prepare);
    },
  );
  test(
    'explicit static fallback remains available but readiness timeout is retryable',
    () async {
      coordinator.requestAuthenticated();
      avatar.isReady.value = false;
      start();
      await coordinator.skip();
      expect(coordinator.phase.value, LoginDoorwayStage.skipped);
      expect(avatar.calls, isEmpty);
      final waiting = LoginDoorwayCoordinator(
        currentScope: () => scope,
        currentGeneration: () => generation,
        accountMounted: () => mounted,
        consumeEntrance: () => true,
        readinessTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(waiting.closeLifecycle);
      waiting.requestAuthenticated();
      waiting.reconcile(
        renderer: null,
        canPresent: () => false,
        reduceMotion: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(waiting.phase.value, LoginDoorwayStage.preparationFailed);
      expect(waiting.canRetryPreparation, isTrue);
      expect(waiting.completed, isFalse);
      expect(mounted, isTrue);
    },
  );
  test(
    'background and renderer recreation stop motion and do not replay entrance',
    () async {
      coordinator.requestAuthenticated();
      start();
      avatar.finish();
      await tick();
      coordinator.interrupt();
      avatar.finish();
      await tick();
      start();
      expect(coordinator.phase.value, LoginDoorwayStage.skipped);
      expect(
        avatar.calls.where((c) => c.phase == AvatarDoorwayPhase.prepare),
        hasLength(1),
      );
      expect(avatar.calls.last.phase, AvatarDoorwayPhase.cancel);
    },
  );

  test(
    'a rendered skip hands the final pose to Home without another entrance',
    () async {
      coordinator.requestAuthenticated();
      start();
      avatar.finish();
      await tick();
      final skip = coordinator.skip();
      await coordinator.skip();
      expect(
        avatar.calls.where((call) => call.phase == AvatarDoorwayPhase.skip),
        hasLength(1),
      );
      avatar.finish();
      await skip;
      expect(coordinator.phase.value, LoginDoorwayStage.skipped);
      expect(coordinator.completed, isTrue);
      start();
      expect(
        avatar.calls.where((call) => call.phase == AvatarDoorwayPhase.prepare),
        hasLength(1),
      );
    },
  );
  test(
    'native failure cannot turn an authenticated session into login failure',
    () async {
      coordinator.requestAuthenticated();
      start();
      avatar.pending.first.completeError(StateError('missing asset'));
      await tick();
      expect(mounted, isTrue);
      expect(coordinator.phase.value, LoginDoorwayStage.preparationFailed);
      expect(coordinator.canRetryPreparation, isTrue);
    },
  );

  test(
    'presentation revocation releases a prepared camera before any later phase',
    () async {
      var allowed = true;
      coordinator.requestAuthenticated();
      coordinator.reconcile(
        renderer: avatar,
        canPresent: () => allowed,
        reduceMotion: false,
      );
      avatar.finish();
      await tick();
      allowed = false;
      coordinator.reconcile(
        renderer: avatar,
        canPresent: () => allowed,
        reduceMotion: false,
      );
      expect(coordinator.phase.value, LoginDoorwayStage.skipped);
      expect(avatar.calls.last.phase, AvatarDoorwayPhase.cancel);
      avatar.finish();
      await tick();
      expect(
        avatar.calls.where((call) => call.phase == AvatarDoorwayPhase.enter),
        isEmpty,
      );
    },
  );

  testWidgets(
    'cold renderer and selected model loading do not consume the native camera budget',
    (tester) async {
      final waiting = LoginDoorwayCoordinator(
        currentScope: () => scope,
        currentGeneration: () => generation,
        accountMounted: () => mounted,
        consumeEntrance: () => ++claims == 1,
      );
      addTearDown(waiting.closeLifecycle);
      final selectedModel = Completer<void>();
      waiting.requestAuthenticated();
      waiting.reconcile(
        renderer: null,
        canPresent: () => false,
        reduceMotion: false,
      );
      await tester.pump(const Duration(seconds: 16));
      expect(waiting.phase.value, LoginDoorwayStage.preparing);
      expect(waiting.completed, isFalse);

      waiting.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
        prepareAvatar: () => selectedModel.future,
      );
      await tester.pump(const Duration(seconds: 16));
      expect(waiting.phase.value, LoginDoorwayStage.preparing);
      expect(avatar.calls, isEmpty);
      selectedModel.complete();
      await tester.pump();
      expect(avatar.calls.single.phase, AvatarDoorwayPhase.prepare);
      await tester.pump(const Duration(seconds: 14));
      expect(waiting.phase.value, LoginDoorwayStage.preparing);
      for (final stage in [
        LoginDoorwayStage.opening,
        LoginDoorwayStage.entering,
        LoginDoorwayStage.framing,
        LoginDoorwayStage.completed,
      ]) {
        avatar.finish();
        await tester.pump();
        expect(waiting.phase.value, stage);
      }
      expect(waiting.completed, isTrue);
      expect(claims, 1);
    },
  );

  testWidgets(
    'native preparation timeout stays on the authenticated presentation and retry ignores late receipts',
    (tester) async {
      coordinator.requestAuthenticated();
      start();
      final oldTransition = coordinator.transitionId;
      await tester.pump(const Duration(milliseconds: 150));
      expect(coordinator.phase.value, LoginDoorwayStage.preparationFailed);
      expect(coordinator.canRetryPreparation, isTrue);
      expect(coordinator.completed, isFalse);
      expect(coordinator.covered, isTrue);
      expect(mounted, isTrue);
      coordinator.retryPreparation();
      expect(coordinator.transitionId, isNot(oldTransition));
      // The old prepare/cancel receipts arrive after the new attempt starts.
      avatar.finish();
      await tester.pump();
      expect(coordinator.phase.value, LoginDoorwayStage.preparing);
      expect(
        avatar.calls.where((call) => call.phase == AvatarDoorwayPhase.open),
        isEmpty,
      );
      start();
      expect(avatar.calls.last.phase, AvatarDoorwayPhase.prepare);
      for (final stage in [
        LoginDoorwayStage.opening,
        LoginDoorwayStage.entering,
        LoginDoorwayStage.framing,
        LoginDoorwayStage.completed,
      ]) {
        avatar.finish();
        await tester.pump();
        expect(coordinator.phase.value, stage);
      }
      expect(coordinator.completed, isTrue);
      expect(claims, 1);
    },
  );

  testWidgets('settled Avatar preparation does not hold a native retry', (
    tester,
  ) async {
    coordinator.requestAuthenticated();
    coordinator.reconcile(
      renderer: avatar,
      canPresent: () => true,
      reduceMotion: false,
      prepareAvatar: () async {},
    );
    await tester.pump();
    expect(avatar.calls.single.phase, AvatarDoorwayPhase.prepare);
    await tester.pump(const Duration(milliseconds: 150));
    expect(coordinator.phase.value, LoginDoorwayStage.preparationFailed);
    coordinator.retryPreparation();
    coordinator.reconcile(
      renderer: avatar,
      canPresent: () => true,
      reduceMotion: false,
      prepareAvatar: () async {},
    );
    await tester.pump();
    expect(
      avatar.calls.where((call) => call.phase == AvatarDoorwayPhase.prepare),
      hasLength(2),
    );
    for (final stage in [
      LoginDoorwayStage.opening,
      LoginDoorwayStage.entering,
      LoginDoorwayStage.framing,
      LoginDoorwayStage.completed,
    ]) {
      avatar.finish();
      await tester.pump();
      expect(coordinator.phase.value, stage);
    }
  });

  testWidgets(
    'retry waits for the old Avatar load to settle before starting a new readiness budget',
    (tester) async {
      final waiting = LoginDoorwayCoordinator(
        currentScope: () => scope,
        currentGeneration: () => generation,
        accountMounted: () => mounted,
        consumeEntrance: () => ++claims == 1,
        readinessTimeout: const Duration(milliseconds: 20),
        preparationTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(waiting.closeLifecycle);
      final firstLoad = Completer<void>();
      var preparations = 0;
      Future<void> prepareAvatar() {
        preparations++;
        return preparations == 1 ? firstLoad.future : Future<void>.value();
      }

      waiting.requestAuthenticated();
      void reconcile() => waiting.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
        prepareAvatar: prepareAvatar,
      );
      reconcile();
      expect(preparations, 1);
      await tester.pump(const Duration(milliseconds: 25));
      expect(waiting.phase.value, LoginDoorwayStage.preparationFailed);
      waiting.retryPreparation();
      reconcile();
      await tester.pump(const Duration(milliseconds: 50));
      expect(waiting.phase.value, LoginDoorwayStage.preparing);
      expect(preparations, 1);
      expect(avatar.calls, isEmpty);
      expect(claims, 1);

      firstLoad.completeError(StateError('old load settled'));
      await tester.pump();
      reconcile();
      await tester.pump();
      expect(preparations, 2);
      expect(avatar.calls.single.phase, AvatarDoorwayPhase.prepare);
      for (final stage in [
        LoginDoorwayStage.opening,
        LoginDoorwayStage.entering,
        LoginDoorwayStage.framing,
        LoginDoorwayStage.completed,
      ]) {
        avatar.finish();
        await tester.pump();
        expect(waiting.phase.value, stage);
      }
      expect(waiting.completed, isTrue);
      expect(claims, 1);
    },
  );

  testWidgets(
    'an old account Avatar load cannot release a new account attempt',
    (tester) async {
      final waiting = LoginDoorwayCoordinator(
        currentScope: () => scope,
        currentGeneration: () => generation,
        accountMounted: () => mounted,
        consumeEntrance: () {
          claims++;
          return true;
        },
        readinessTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(waiting.closeLifecycle);
      final oldLoad = Completer<void>();
      final newLoad = Completer<void>();
      waiting.requestAuthenticated();
      waiting.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
        prepareAvatar: () => oldLoad.future,
      );
      await tester.pump(const Duration(milliseconds: 25));
      expect(waiting.phase.value, LoginDoorwayStage.preparationFailed);

      scope = 'account-b';
      generation++;
      waiting.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
      );
      expect(waiting.phase.value, LoginDoorwayStage.cancelled);
      waiting.requestAuthenticated();
      waiting.reconcile(
        renderer: avatar,
        canPresent: () => true,
        reduceMotion: false,
        prepareAvatar: () => newLoad.future,
      );
      oldLoad.complete();
      await tester.pump();
      expect(waiting.phase.value, LoginDoorwayStage.preparing);
      expect(avatar.calls, isEmpty);
      newLoad.complete();
      await tester.pump();
      expect(avatar.calls.single.phase, AvatarDoorwayPhase.prepare);
      expect(claims, 2);
      for (final stage in [
        LoginDoorwayStage.opening,
        LoginDoorwayStage.entering,
        LoginDoorwayStage.framing,
        LoginDoorwayStage.completed,
      ]) {
        avatar.finish();
        await tester.pump();
        expect(waiting.phase.value, stage);
      }
    },
  );

  testWidgets('an account change invalidates a failed preparation retry', (
    tester,
  ) async {
    coordinator.requestAuthenticated();
    start();
    await tester.pump(const Duration(milliseconds: 150));
    expect(coordinator.canRetryPreparation, isTrue);
    scope = 'account-b';
    generation++;
    coordinator.retryPreparation();
    expect(coordinator.canRetryPreparation, isFalse);
    start();
    expect(coordinator.phase.value, LoginDoorwayStage.cancelled);
    expect(
      avatar.calls.where((call) => call.phase == AvatarDoorwayPhase.prepare),
      hasLength(1),
    );
  });
}
