import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_agent_space.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local entry prepares the selected renderer without a cloud lease',
    () async {
      final renderer = _RoomAvatar();
      final active = ActiveAvatarRuntime()..register(renderer);
      var preparations = 0;
      final room = AgentSpaceController(
        avatar: active,
        prepareAvatar: () async => preparations++,
      );
      await room.enter();
      expect(room.state.value.phase, AgentSpacePhase.active);
      expect(renderer.prepared, 1);
      expect(preparations, 1);
      expect(renderer.entered, hasLength(1));
      await room.enter();
      expect(renderer.entered, hasLength(1));
      await room.leave();
      expect(renderer.left, renderer.entered);
      room.onClose();
    },
  );

  test(
    'entering from chat shows the same avatar and exit restores visibility',
    () async {
      final renderer = _RoomAvatar();
      final active = ActiveAvatarRuntime()..register(renderer);
      await active.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: active);
      await room.enter();
      expect(active.current, same(renderer));
      expect(active.localAvatarVisible, isTrue);
      await room.leave();
      expect(active.localAvatarVisible, isFalse);
      room.onClose();
    },
  );

  test(
    'late entry cannot reactivate a room after exit or hide the next session',
    () async {
      final renderer = _RoomAvatar()..entry = Completer<void>();
      final active = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: active);
      final first = room.enter();
      await _settle();
      final oldSession = renderer.entered.single;
      final leaving = room.leave();
      final second = room.enter();
      renderer.entry!.complete();
      await Future.wait([first, leaving, second]);
      expect(room.state.value.phase, AgentSpacePhase.active);
      expect(renderer.entered, hasLength(2));
      expect(renderer.left, contains(oldSession));
      expect(renderer.left, isNot(contains(renderer.entered.last)));
      room.onClose();
    },
  );

  test(
    'scope retirement cancels readiness and drains without revealing a character',
    () async {
      final renderer = _RoomAvatar()..isReady.value = false;
      final active = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: active);
      final entering = room.enter();
      await _settle();
      await room.deactivateAndDrain();
      renderer.isReady.value = true;
      await entering;
      expect(renderer.entered, isEmpty);
      expect(renderer.visibility, isEmpty);
      room.onClose();
    },
  );

  test(
    'account or renderer replacement during preparation cancels old entry',
    () async {
      final first = _RoomAvatar();
      final second = _RoomAvatar();
      final active = ActiveAvatarRuntime()..register(first);
      final preparing = Completer<void>();
      final room = AgentSpaceController(
        avatar: active,
        prepareAvatar: () => preparing.future,
      );
      final operation = room.enter();
      await _settle();
      active.register(second);
      preparing.complete();
      await operation;
      expect(first.entered, isEmpty);
      expect(second.entered, isEmpty);
      room.onClose();
    },
  );

  test(
    'background and invalid coordinates do not issue local movement',
    () async {
      final renderer = _RoomAvatar();
      final active = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: active);
      final source = Object();
      await room.enter();
      await room.handleScreenTap(.2, .8);
      expect(renderer.moves, [(x: .2, y: .8)]);
      for (final point in [(-1.0, .5), (.5, 2.0), (double.nan, .5)]) {
        await room.handleScreenTap(point.$1, point.$2);
      }
      room.setActivity(resumed: false, currentPage: true, source: source);
      await room.handleScreenTap(.3, .7);
      expect(renderer.moves, hasLength(1));
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      await room.handleScreenTap(.3, .7);
      expect(renderer.moves, hasLength(2));
      room.onClose();
    },
  );

  test('a stale page disposal cannot dismiss a newer visible page', () async {
    final renderer = _RoomAvatar();
    final active = ActiveAvatarRuntime()..register(renderer);
    final room = AgentSpaceController(avatar: active);
    final old = Object(), current = Object();
    room.setActivity(resumed: true, currentPage: true, source: old);
    await room.enter();
    room.setActivity(resumed: true, currentPage: true, source: current);
    room.setActivity(resumed: false, currentPage: false, source: old);
    expect(room.state.value.phase, AgentSpacePhase.active);
    expect(renderer.left, isEmpty);
    room.onClose();
  });

  test('camera destinations travel with each animated room command', () async {
    final renderer = _RoomAvatar();
    final avatar = ActiveAvatarRuntime()..register(renderer);
    final room = AgentSpaceController(avatar: avatar);
    const homeViewport = AvatarViewportSafeArea(top: .05, bottom: .2);
    await room.enter(
      animated: true,
      targetViewportSafeArea: const AvatarViewportSafeArea(),
    );
    expect(renderer.entryAnimations, [true]);
    expect(renderer.entryViewports, [const AvatarViewportSafeArea()]);
    await room.leave(animated: true, homeViewportSafeArea: homeViewport);
    expect(renderer.exitAnimations, [true]);
    expect(renderer.exitViewports, [homeViewport]);
    expect(renderer.viewportWrites, isEmpty);
    room.onClose();
  });

  test(
    'strict exit interrupts a pending animated entry by its exact session',
    () async {
      final renderer = _RoomAvatar()
        ..entry = Completer<void>()
        ..cancelAnimationsOnImmediateExit = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      final entering = room.enter(animated: true);
      await _settle();
      final session = renderer.entered.single;
      await Future.wait<void>([entering, room.leave()]);
      expect(renderer.left, [session]);
      expect(renderer.exitAnimations, [false]);
      expect(renderer.nativeSession, isNull);
      expect(room.state.value.phase, AgentSpacePhase.initial);
      expect(avatar.localAvatarVisible, isFalse);
      room.onClose();
    },
  );

  test(
    'background interrupts normal exit without waiting for its animation',
    () async {
      final renderer = _RoomAvatar()
        ..animatedExit = Completer<void>()
        ..cancelAnimationsOnImmediateExit = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: avatar);
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      final session = renderer.entered.single;
      final leaving = room.leave(animated: true);
      await _settle();
      room.setActivity(resumed: false, currentPage: true, source: source);
      await leaving;
      expect(renderer.left, [session, session]);
      expect(renderer.exitAnimations, [true, false]);
      expect(renderer.nativeSession, isNull);
      expect(room.state.value.phase, AgentSpacePhase.initial);
      await room.handleScreenTap(.3, .7);
      expect(renderer.moves, isEmpty);
      room.onClose();
    },
  );

  test('failed interruption keeps cleanup authority and can retry', () async {
    final renderer = _RoomAvatar()
      ..animatedExit = Completer<void>()
      ..cancelAnimationsOnImmediateExit = true;
    final avatar = ActiveAvatarRuntime()..register(renderer);
    await avatar.setLocalAvatarVisible(false);
    final room = AgentSpaceController(avatar: avatar);
    await room.enter();
    final original = renderer.nativeSession;
    final leaving = room.leave(animated: true);
    await _settle();
    renderer.immediateExitFailure = StateError('immediate exit failed');
    final interrupted = room.leave();
    await expectLater(
      Future.wait<void>([leaving, interrupted]),
      throwsStateError,
    );
    expect(room.state.value.phase, AgentSpacePhase.failure);
    expect(renderer.nativeSession, original);
    expect(avatar.localAvatarVisible, isTrue);
    renderer.immediateExitFailure = null;
    await room.enter();
    expect(renderer.entered, hasLength(2));
    expect(renderer.nativeSession, isNot(original));
    expect(room.state.value.phase, AgentSpacePhase.active);
    await room.leave();
    expect(renderer.nativeSession, isNull);
    expect(avatar.localAvatarVisible, isFalse);
    room.onClose();
  });

  test(
    'a racing normal receipt still waits for the already issued strict exit',
    () async {
      final renderer = _RoomAvatar()
        ..animatedExit = Completer<void>()
        ..immediateExitReceipt = Completer<void>();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final normal = room.leave(animated: true);
      await _settle();
      final strict = room.leave();
      await _settle();
      renderer.animatedExit!.complete();
      await _settle();
      expect(room.state.value.phase, AgentSpacePhase.leaving);
      expect(avatar.localAvatarVisible, isTrue);
      renderer.immediateExitReceipt!.complete();
      await Future.wait<void>([normal, strict]);
      expect(room.state.value.phase, AgentSpacePhase.initial);
      expect(avatar.localAvatarVisible, isFalse);
      room.onClose();
    },
  );

  test(
    'native entry failure shows an actionable failure and can retry',
    () async {
      final renderer = _RoomAvatar()..failEntry = true;
      final active = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: active);
      await room.enter();
      expect(room.state.value.phase, AgentSpacePhase.failure);
      renderer.failEntry = false;
      await room.enter();
      expect(room.state.value.phase, AgentSpacePhase.active);
      room.onClose();
    },
  );
  for (final reason in ['path_blocked', 'outside_walkable_floor']) {
    test(
      'navigation refusal $reason keeps the room active and exits normally',
      () async {
        final renderer = _RoomAvatar()..enforceSessions = true;
        final avatar = ActiveAvatarRuntime()..register(renderer);
        await avatar.setLocalAvatarVisible(false);
        final room = AgentSpaceController(avatar: avatar);
        await room.enter();
        final session = renderer.nativeSession;
        renderer.moveFailure = AvatarAgentSpaceCommandException(
          method: 'requestAgentSpaceMoveAtScreenPoint',
          code: reason,
        );
        await room.handleScreenTap(.4, .6);
        expect(room.state.value.phase, AgentSpacePhase.active);
        expect(renderer.nativeSession, session);
        await room.enter();
        expect(renderer.entered, hasLength(1));
        await room.leave();
        expect(renderer.nativeSession, isNull);
        expect(avatar.localAvatarVisible, isFalse);
        room.onClose();
      },
    );
  }

  test(
    'fatal move retry retires the old session and preserves chat visibility',
    () async {
      final renderer = _RoomAvatar()..enforceSessions = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final previous = renderer.nativeSession;
      renderer.moveFailure = const AvatarAgentSpaceCommandException(
        method: 'requestAgentSpaceMoveAtScreenPoint',
        code: 'personal_room_unavailable',
      );
      await room.handleScreenTap(.2, .8);
      expect(room.state.value.phase, AgentSpacePhase.failure);
      renderer.moveFailure = null;
      await room.enter();
      expect(room.state.value.phase, AgentSpacePhase.active);
      expect(renderer.left, contains(previous));
      expect(renderer.nativeSession, isNot(previous));
      await room.leave();
      expect(renderer.nativeSession, isNull);
      expect(avatar.localAvatarVisible, isFalse);
      room.onClose();
    },
  );

  test('failed retry cleanup retains its session for a later retry', () async {
    final renderer = _RoomAvatar()..enforceSessions = true;
    final avatar = ActiveAvatarRuntime()..register(renderer);
    await avatar.setLocalAvatarVisible(false);
    final room = AgentSpaceController(avatar: avatar);
    await room.enter();
    final previous = renderer.nativeSession;
    renderer.moveFailure = StateError('renderer failed');
    await room.handleScreenTap(.2, .8);
    renderer.failNextLeave = true;
    await room.enter();
    expect(room.state.value.phase, AgentSpacePhase.failure);
    expect(renderer.nativeSession, previous);
    expect(renderer.entered, hasLength(1));
    await room.enter();
    expect(room.state.value.phase, AgentSpacePhase.active);
    await room.leave();
    expect(renderer.nativeSession, isNull);
    expect(avatar.localAvatarVisible, isFalse);
    room.onClose();
  });

  test(
    'native entry failure and retry do not overwrite the original chat visibility',
    () async {
      final renderer = _RoomAvatar()..failEntry = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      expect(room.state.value.phase, AgentSpacePhase.failure);
      expect(avatar.localAvatarVisible, isFalse);
      renderer.failEntry = false;
      await room.enter();
      await room.leave();
      expect(avatar.localAvatarVisible, isFalse);
      room.onClose();
    },
  );

  test(
    'background during selected-avatar preparation cancels the pending entry',
    () async {
      final renderer = _RoomAvatar();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      final preparation = Completer<void>();
      final room = AgentSpaceController(
        avatar: avatar,
        prepareAvatar: () => preparation.future,
      );
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      final entering = room.enter();
      await _settle();
      room.setActivity(resumed: false, currentPage: true, source: source);
      preparation.complete();
      await entering;
      await _settle();
      expect(renderer.entered, isEmpty);
      expect(renderer.visibility, isEmpty);
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      expect(room.state.value.phase, AgentSpacePhase.active);
      room.onClose();
    },
  );

  test(
    'late move failure from the exited session cannot fail its replacement',
    () async {
      final renderer = _RoomAvatar()..enforceSessions = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final movement = Completer<void>();
      renderer.moveReceipt = movement;
      final moving = room.handleScreenTap(.3, .6);
      await room.leave();
      renderer.moveReceipt = null;
      await room.enter();
      final replacement = renderer.nativeSession;
      movement.completeError(StateError('old move failed'));
      await moving;
      expect(room.state.value.phase, AgentSpacePhase.active);
      expect(renderer.nativeSession, replacement);
      room.onClose();
    },
  );

  test(
    'exit waits for an already dispatched visibility write before restoration',
    () async {
      final renderer = _RoomAvatar();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final visibility = Completer<void>();
      renderer.visibilityReceipt = visibility;
      final room = AgentSpaceController(avatar: avatar);
      final entering = room.enter();
      await _settle();
      final leaving = room.leave();
      await _settle();
      expect(renderer.entered, isEmpty);
      expect(renderer.left, isEmpty);
      visibility.complete();
      await Future.wait([entering, leaving]);
      expect(renderer.entered, isEmpty);
      expect(avatar.localAvatarVisible, isFalse);
      room.onClose();
    },
  );
  test(
    'failed exit retains the session and original Home preference for retry',
    () async {
      final renderer = _RoomAvatar()..enforceSessions = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final original = renderer.nativeSession;
      renderer.failNextLeave = true;
      await expectLater(room.leave(), throwsStateError);
      expect(room.state.value.phase, AgentSpacePhase.failure);
      expect(renderer.nativeSession, original);
      await room.leave();
      expect(renderer.nativeSession, isNull);
      expect(avatar.localAvatarVisible, isFalse);
      room.onClose();
    },
  );

  test(
    'strict account drain exposes failed native exit and can retry it',
    () async {
      final renderer = _RoomAvatar()..enforceSessions = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      renderer.failNextLeave = true;
      await expectLater(room.deactivateAndDrain(), throwsStateError);
      expect(renderer.nativeSession, isNotNull);
      await room.deactivateAndDrain();
      expect(renderer.nativeSession, isNull);
      room.onClose();
    },
  );

  test(
    'activity exit observes its error without losing retry authority',
    () async {
      final renderer = _RoomAvatar()..enforceSessions = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      final original = renderer.nativeSession;
      renderer.failNextLeave = true;
      room.setActivity(resumed: false, currentPage: false, source: source);
      await _settle();
      expect(room.state.value.phase, AgentSpacePhase.failure);
      expect(renderer.nativeSession, original);
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      expect(room.state.value.phase, AgentSpacePhase.active);
      await room.leave();
      expect(avatar.localAvatarVisible, isFalse);
      room.onClose();
    },
  );

  for (final reason in ['session_mismatch', 'session_retired']) {
    test(
      'only an explicit retired-owner $reason receipt is idempotent cleanup',
      () async {
        final renderer = _RoomAvatar();
        final avatar = ActiveAvatarRuntime()..register(renderer);
        var current = true;
        final room = AgentSpaceController(
          avatar: avatar,
          isCurrent: () => current,
        );
        await room.enter();
        renderer.leaveFailure = AvatarAgentSpaceCommandException(
          method: 'leaveAgentSpace',
          code: reason,
        );
        await expectLater(
          room.leave(),
          throwsA(isA<AvatarAgentSpaceCommandException>()),
        );
        expect(room.state.value.phase, AgentSpacePhase.failure);
        current = false;
        renderer.nativeSession = 'replacement-owner-session';
        final visibilityWrites = renderer.visibility.length;
        await room.deactivateAndDrain();
        expect(renderer.nativeSession, 'replacement-owner-session');
        expect(renderer.visibility.length, visibilityWrites);
        room.onClose();
      },
    );
  }
  test(
    'Home mounts before the native return completes without cancelling its owner',
    () async {
      final renderer = _RoomAvatar()
        ..animatedExit = Completer<void>()
        ..cancelAnimationsOnImmediateExit = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      var homeRoute = false;
      final room = AgentSpaceController(
        avatar: avatar,
        homeRouteIsCurrent: () => homeRoute,
      );
      final spaceSource = Object(), homeSource = Object();
      room.setActivity(resumed: true, currentPage: true, source: spaceSource);
      await room.enter();
      final exit = room.leave(animated: true, handoffToHome: true);
      expect(room.state.value.phase, AgentSpacePhase.leaving);
      expect(room.isReturningHome, isTrue);
      expect(room.hasPendingHomeReturn(renderer), isTrue);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      expect(renderer.left, isEmpty);
      // Publishing the leaving state can synchronously rebuild the old page
      // before go(Home); its same-source foreground report is not a new visit.
      room.setActivity(resumed: true, currentPage: true, source: spaceSource);
      homeRoute = true;
      room.setActivity(resumed: true, currentPage: false, source: spaceSource);
      room.setHomeActivity(
        resumed: true,
        currentPage: true,
        source: homeSource,
      );
      room.setActivity(resumed: true, currentPage: false, source: spaceSource);
      final repeated = room.leave(animated: true, handoffToHome: true);
      expect(repeated, same(exit));
      await _settle();
      expect(renderer.exitAnimations, [true]);
      expect(room.isReturningHome, isTrue);
      expect(avatar.localAvatarVisible, isTrue);
      renderer.animatedExit!.complete();
      await exit;
      expect(room.isReturningHome, isFalse);
      expect(room.state.value.phase, AgentSpacePhase.initial);
      expect(room.consumeHomeReturnFrame(renderer), isTrue);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      expect(renderer.exitAnimations, [true]);
      expect(renderer.visibility, everyElement(isTrue));
      room.onClose();
    },
  );

  test(
    'destination ownership ignores stale Home and Space detach reports',
    () async {
      final renderer = _RoomAvatar()
        ..animatedExit = Completer<void>()
        ..cancelAnimationsOnImmediateExit = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(
        avatar: avatar,
        homeRouteIsCurrent: () => true,
      );
      final spaceSource = Object(), homeSource = Object();
      room.setActivity(resumed: true, currentPage: true, source: spaceSource);
      await room.enter();
      final exit = room.leave(animated: true, handoffToHome: true);
      // The old underlying Home may report covered before the destination's
      // first activity report. It does not own this return yet.
      room.setHomeActivity(resumed: true, currentPage: false, source: Object());
      room.setHomeActivity(
        resumed: true,
        currentPage: true,
        source: homeSource,
      );
      room.setHomeActivity(
        resumed: false,
        currentPage: false,
        source: Object(),
      );
      room.setActivity(resumed: true, currentPage: false, source: spaceSource);
      await _settle();
      expect(renderer.exitAnimations, [true]);
      expect(room.isReturningHome, isTrue);
      renderer.animatedExit!.complete();
      await exit;
      expect(room.consumeHomeReturnFrame(renderer), isTrue);
      room.onClose();
    },
  );

  for (final retirement in [
    'background',
    'non-home',
    'account',
    'model',
    'renderer',
    'unready',
    'new-space',
  ]) {
    test(
      'Home pending return is revoked by $retirement and retires only its session',
      () async {
        final renderer = _RoomAvatar()
          ..animatedExit = Completer<void>()
          ..cancelAnimationsOnImmediateExit = true;
        final avatar = ActiveAvatarRuntime()..register(renderer);
        await avatar.setLocalAvatarVisible(true);
        var current = true, homeRoute = true;
        final room = AgentSpaceController(
          avatar: avatar,
          isCurrent: () => current,
          homeRouteIsCurrent: () => homeRoute,
        );
        final spaceSource = Object(), homeSource = Object();
        room.setActivity(resumed: true, currentPage: true, source: spaceSource);
        await room.enter();
        final oldSession = renderer.nativeSession;
        final exit = room.leave(animated: true, handoffToHome: true);
        room.setHomeActivity(
          resumed: true,
          currentPage: true,
          source: homeSource,
        );
        await _settle();
        List<bool>? replacementVisibility;
        switch (retirement) {
          case 'background':
            room.setHomeActivity(
              resumed: false,
              currentPage: true,
              source: homeSource,
            );
          case 'non-home':
            homeRoute = false;
            room.setHomeActivity(
              resumed: true,
              currentPage: false,
              source: homeSource,
            );
          case 'account':
            current = false;
            room.setHomeActivity(
              resumed: true,
              currentPage: true,
              source: homeSource,
            );
          case 'model':
            renderer.epoch++;
            room.setHomeActivity(
              resumed: true,
              currentPage: true,
              source: homeSource,
            );
          case 'renderer':
            avatar.register(_RoomAvatar());
            replacementVisibility = List<bool>.of(
              (avatar.current as _RoomAvatar).visibility,
            );
            room.setHomeActivity(
              resumed: true,
              currentPage: true,
              source: homeSource,
            );
          case 'unready':
            renderer.isReady.value = false;
            room.setHomeActivity(
              resumed: true,
              currentPage: true,
              source: homeSource,
            );
          case 'new-space':
            homeRoute = false;
            room.setActivity(
              resumed: true,
              currentPage: true,
              source: Object(),
            );
        }
        expect(room.isReturningHome, isFalse);
        expect(room.hasPendingHomeReturn(renderer), isFalse);
        await exit;
        await _settle();
        expect(renderer.left, [oldSession, oldSession]);
        expect(renderer.exitAnimations, [true, false]);
        expect(renderer.nativeSession, isNull);
        expect(room.consumeHomeReturnFrame(renderer), isFalse);
        if (retirement == 'renderer') {
          expect(
            (avatar.current as _RoomAvatar).visibility,
            replacementVisibility,
            reason:
                'Register may sync visibility; the retired return adds no write.',
          );
        }
        if (retirement == 'new-space') {
          await room.enter();
          expect(renderer.entered, hasLength(2));
          expect(renderer.nativeSession, isNot(oldSession));
        }
        room.onClose();
      },
    );
  }

  test(
    'Space detach onto another route cannot preserve a pending Home return',
    () async {
      final renderer = _RoomAvatar()
        ..animatedExit = Completer<void>()
        ..cancelAnimationsOnImmediateExit = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(
        avatar: avatar,
        homeRouteIsCurrent: () => false,
      );
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      final exit = room.leave(animated: true, handoffToHome: true);
      await _settle();
      room.setActivity(resumed: true, currentPage: false, source: source);
      await exit;
      expect(renderer.exitAnimations, [true, false]);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    },
  );

  test(
    'chat Home handoff holds cleanup ownership but skips the visible journey',
    () async {
      final renderer = _RoomAvatar()..immediateExitReceipt = Completer<void>();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final exit = room.leave(animated: true, handoffToHome: true);
      expect(room.isReturningHome, isTrue);
      room.setHomeActivity(resumed: true, currentPage: true, source: Object());
      await _settle();
      expect(renderer.exitAnimations, [false]);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      renderer.immediateExitReceipt!.complete();
      await exit;
      expect(room.isReturningHome, isFalse);
      expect(avatar.localAvatarVisible, isFalse);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    },
  );

  test(
    'failed Home handoff releases its pending token without inventing a frame',
    () async {
      final renderer = _RoomAvatar()
        ..failNextLeave = true
        ..cancelAnimationsOnImmediateExit = true
        ..immediateExitFailure = StateError('exact cleanup failed');
      final avatar = ActiveAvatarRuntime()..register(renderer);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final exit = room.leave(animated: true, handoffToHome: true);
      expect(room.isReturningHome, isTrue);
      room.setHomeActivity(resumed: true, currentPage: true, source: Object());
      await expectLater(exit, throwsStateError);
      expect(room.isReturningHome, isFalse);
      expect(room.state.value.phase, AgentSpacePhase.failure);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      renderer.immediateExitFailure = null;
      await room.leave();
      expect(renderer.nativeSession, isNull);
      room.onClose();
    },
  );

  test(
    'a failed Home animation gets one exact-session immediate fallback',
    () async {
      final renderer = _RoomAvatar()..failNextLeave = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final session = renderer.nativeSession;
      await room.leave(animated: true, handoffToHome: true);
      expect(renderer.left, [session, session]);
      expect(renderer.exitAnimations, [true, false]);
      expect(renderer.nativeSession, isNull);
      expect(room.consumeHomeReturnFrame(renderer), isTrue);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    },
  );

  test(
    'completed native Home return survives page disposal and is consumed once',
    () async {
      final renderer = _RoomAvatar();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final room = AgentSpaceController(avatar: avatar);
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      await room.leave(animated: true);
      final writes = List<bool>.of(renderer.visibility);
      room.setActivity(resumed: false, currentPage: false, source: source);
      await _settle();
      expect(room.consumeHomeReturnFrame(renderer), isTrue);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      expect(renderer.visibility, writes);
      room.onClose();
    },
  );

  test(
    'foreground immediate exit grants Home only after its native receipt',
    () async {
      final renderer = _RoomAvatar()..immediateExitReceipt = Completer<void>();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final room = AgentSpaceController(avatar: avatar);
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      final exit = room.leave(handoffToHome: true);
      await _settle();
      expect(renderer.exitAnimations, [false]);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      renderer.immediateExitReceipt!.complete();
      await exit;
      room.setActivity(resumed: false, currentPage: false, source: source);
      await _settle();
      expect(room.consumeHomeReturnFrame(renderer), isTrue);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    },
  );

  test(
    'background interruption cannot adopt an immediate foreground exit',
    () async {
      final renderer = _RoomAvatar()..immediateExitReceipt = Completer<void>();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final room = AgentSpaceController(avatar: avatar);
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      final exit = room.leave(handoffToHome: true);
      await _settle();
      room.setActivity(resumed: false, currentPage: true, source: source);
      renderer.immediateExitReceipt!.complete();
      await exit;
      await _settle();
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    },
  );

  test(
    'a failed immediate foreground exit cannot grant a Home frame',
    () async {
      final renderer = _RoomAvatar()..failNextLeave = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      await expectLater(room.leave(handoffToHome: true), throwsStateError);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      await room.leave();
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    },
  );

  test(
    'closing during entry adopts the acknowledged immediate Home reset',
    () async {
      final renderer = _RoomAvatar()
        ..entry = Completer<void>()
        ..immediateExitReceipt = Completer<void>()
        ..cancelAnimationsOnImmediateExit = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final room = AgentSpaceController(avatar: avatar);
      final entering = room.enter(animated: true);
      await _settle();
      final exit = room.leave(handoffToHome: true);
      await _settle();
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      renderer.immediateExitReceipt!.complete();
      await Future.wait<void>([entering, exit]);
      expect(room.consumeHomeReturnFrame(renderer), isTrue);
      room.onClose();
    },
  );

  for (final retirement in [
    'background',
    'account',
    'model',
    'renderer',
    'unready',
    'hidden',
    'new-space',
  ]) {
    test('completed Home return is rejected after $retirement', () async {
      final renderer = _RoomAvatar();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      var current = true;
      final room = AgentSpaceController(
        avatar: avatar,
        isCurrent: () => current,
      );
      final source = Object();
      room.setActivity(resumed: true, currentPage: true, source: source);
      await room.enter();
      await room.leave(animated: true);
      switch (retirement) {
        case 'background':
          room.setActivity(resumed: false, currentPage: true, source: source);
        case 'account':
          current = false;
        case 'model':
          renderer.epoch++;
        case 'renderer':
          avatar.register(_RoomAvatar());
        case 'unready':
          renderer.isReady.value = false;
        case 'hidden':
          await avatar.setLocalAvatarVisible(false);
        case 'new-space':
          await room.enter();
      }
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    });
  }

  test('failed native return never grants a Home frame', () async {
    final renderer = _RoomAvatar()..failNextLeave = true;
    final avatar = ActiveAvatarRuntime()..register(renderer);
    await avatar.setLocalAvatarVisible(true);
    final room = AgentSpaceController(avatar: avatar);
    await room.enter();
    await expectLater(room.leave(animated: true), throwsStateError);
    expect(room.consumeHomeReturnFrame(renderer), isFalse);
    await room.leave();
    expect(room.consumeHomeReturnFrame(renderer), isFalse);
    room.onClose();
  });

  test(
    'strict interruption of a normal return cannot grant its final frame',
    () async {
      final renderer = _RoomAvatar()
        ..animatedExit = Completer<void>()
        ..cancelAnimationsOnImmediateExit = true;
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(true);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      final normal = room.leave(animated: true);
      await _settle();
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      await Future.wait<void>([normal, room.leave()]);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      expect(renderer.exitAnimations, [true, false]);
      room.onClose();
    },
  );

  test(
    'a completed return to chat cannot be adopted as a visible avatar frame',
    () async {
      final renderer = _RoomAvatar();
      final avatar = ActiveAvatarRuntime()..register(renderer);
      await avatar.setLocalAvatarVisible(false);
      final room = AgentSpaceController(avatar: avatar);
      await room.enter();
      await room.leave(animated: true);
      expect(avatar.localAvatarVisible, isFalse);
      expect(room.consumeHomeReturnFrame(renderer), isFalse);
      room.onClose();
    },
  );
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _RoomAvatar extends AvatarRuntime implements AvatarAgentSpaceRuntime {
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  int epoch = 0;
  @override
  int get modelLoadEpoch => epoch;
  var prepared = 0;
  final entered = <String>[], left = <String>[];
  final moves = <({double x, double y})>[];
  final visibility = <bool>[];
  final entryAnimations = <bool>[];
  final exitAnimations = <bool>[];
  final entryViewports = <AvatarViewportSafeArea?>[];
  final exitViewports = <AvatarViewportSafeArea?>[];
  final viewportWrites = <AvatarViewportSafeArea>[];
  Completer<void>? entry;
  Completer<void>? animatedExit;
  Completer<void>? immediateExitReceipt;
  bool cancelAnimationsOnImmediateExit = false;
  Object? immediateExitFailure;
  bool failEntry = false;
  bool enforceSessions = false;
  bool failNextLeave = false;
  String? nativeSession;
  Object? moveFailure;
  Object? leaveFailure;
  Completer<void>? moveReceipt;
  Completer<void>? visibilityReceipt;

  @override
  Future<void> prepareRenderer() async => prepared++;
  @override
  Future<void> setLocalAvatarVisible(bool visible) async {
    visibility.add(visible);
    if (visible) await visibilityReceipt?.future;
  }

  @override
  Future<void> enterAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    entered.add(sessionId);
    entryAnimations.add(animated);
    entryViewports.add(targetViewportSafeArea);
    if (failEntry) throw StateError('native entry rejected');
    if (enforceSessions &&
        nativeSession != null &&
        nativeSession != sessionId) {
      throw const AvatarAgentSpaceCommandException(
        method: 'enterAgentSpace',
        code: 'space_busy',
      );
    }
    nativeSession = sessionId;
    await entry?.future;
  }

  @override
  Future<void> leaveAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    left.add(sessionId);
    exitAnimations.add(animated);
    exitViewports.add(targetViewportSafeArea);
    if (leaveFailure case final Object failure) throw failure;
    if (failNextLeave) {
      failNextLeave = false;
      throw StateError('leave failed');
    }
    if (enforceSessions &&
        nativeSession != null &&
        nativeSession != sessionId) {
      throw const AvatarAgentSpaceCommandException(
        method: 'leaveAgentSpace',
        code: 'session_mismatch',
      );
    }
    if (!animated && cancelAnimationsOnImmediateExit) {
      if (entry != null && !entry!.isCompleted) {
        entry!.completeError(
          const AvatarAgentSpaceCommandException(
            method: 'enterAgentSpace',
            code: 'space_transition_cancelled',
          ),
        );
      }
      if (animatedExit != null && !animatedExit!.isCompleted) {
        animatedExit!.completeError(
          const AvatarAgentSpaceCommandException(
            method: 'leaveAgentSpace',
            code: 'space_transition_cancelled',
          ),
        );
      }
      if (immediateExitFailure case final Object failure) throw failure;
    }
    if (animated) await animatedExit?.future;
    if (!animated) await immediateExitReceipt?.future;
    nativeSession = null;
  }

  @override
  Future<void> moveAgentSpaceAtScreenPoint({
    required String sessionId,
    required double x,
    required double y,
  }) async {
    moves.add((x: x, y: y));
    if (moveFailure case final Object failure) throw failure;
    await moveReceipt?.future;
  }

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) async =>
      viewportWrites.add(safeArea);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
