import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_agent_space.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'space entry waits for the exact session and renderer receipt',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      var finished = false;
      final operation = (runtime as AvatarAgentSpaceRuntime)
          .enterAgentSpace(sessionId: 'account-room:1')
          .then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      final call = transport.calls.last;
      expect(call.method, 'enterAgentSpace');
      final args = Map<String, Object?>.from(call.arguments as Map);
      expect(args.keys, unorderedEquals(['requestId', 'sessionId']));
      final receipt = {...args, 'method': call.method, 'ok': true, 'code': ''};
      expect(
        await transport.emit(
          MethodCall('commandResult', {...receipt, 'sessionId': 'other-room'}),
        ),
        isFalse,
      );
      expect(
        await transport.emit(
          MethodCall('commandResult', {
            ...receipt,
            'method': 'leaveAgentSpace',
          }),
        ),
        isFalse,
      );
      for (final invalid in <Map<String, Object?>>[
        {...receipt, 'worldId': 'retired-world'},
        {...receipt, 'code': 'unrecognized_success'},
        {...receipt, 'ok': false, 'code': 'unrecognized_failure'},
        {...receipt, 'ok': 1},
      ]) {
        expect(
          await transport.emit(MethodCall('commandResult', invalid)),
          isFalse,
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      expect(
        await transport.emit(MethodCall('commandResult', receipt)),
        isTrue,
      );
      await operation;
      expect(finished, isTrue);
    },
  );

  test(
    'space exit and movement carry the same explicit page session',
    () async {
      final transport = _Transport()..autoReceipt = true;
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      await runtime.enterAgentSpace(sessionId: 'room:2');
      await runtime.moveAgentSpaceAtScreenPoint(
        sessionId: 'room:2',
        x: .25,
        y: .75,
      );
      await runtime.leaveAgentSpace(sessionId: 'room:2');
      final commands = transport.calls
          .where(
            (call) =>
                call.method == 'enterAgentSpace' ||
                call.method == 'leaveAgentSpace' ||
                call.method == 'requestAgentSpaceMoveAtScreenPoint',
          )
          .toList();
      expect(commands.map((call) => call.method), [
        'enterAgentSpace',
        'requestAgentSpaceMoveAtScreenPoint',
        'leaveAgentSpace',
      ]);
      for (final call in commands) {
        expect(call.arguments as Map, containsPair('sessionId', 'room:2'));
      }
      expect(commands[1].arguments as Map, containsPair('x', .25));
      expect(commands[1].arguments as Map, containsPair('y', .75));
    },
  );

  test(
    'animated transitions carry one bounded target and wait for completion',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      for (final entering in [true, false]) {
        var finished = false;
        final operation =
            (entering
                    ? runtime.enterAgentSpace(
                        sessionId: 'room:animation',
                        animated: true,
                        targetViewportSafeArea: const AvatarViewportSafeArea(
                          top: .1,
                          bottom: .3,
                        ),
                      )
                    : runtime.leaveAgentSpace(
                        sessionId: 'room:animation',
                        animated: true,
                        targetViewportSafeArea: const AvatarViewportSafeArea(
                          top: .2,
                          bottom: .4,
                        ),
                      ))
                .then((_) => finished = true);
        await Future<void>.delayed(Duration.zero);
        final call = transport.calls.last;
        final args = call.arguments as Map;
        expect(
          args.keys,
          unorderedEquals([
            'requestId',
            'sessionId',
            'animated',
            'viewportTop',
            'viewportBottom',
          ]),
        );
        expect(args['animated'], isTrue);
        expect(args['viewportTop'], entering ? .1 : .2);
        expect(args['viewportBottom'], entering ? .3 : .4);
        expect(finished, isFalse);
        await transport.emit(MethodCall('commandResult', _receipt(call)));
        await operation;
        expect(finished, isTrue);
      }
    },
  );

  test(
    'forced exit restores the captured Home viewport without another packet',
    () async {
      final transport = _Transport()..autoReceipt = true;
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      const home = AvatarViewportSafeArea(top: .1, bottom: .3);
      await runtime.setViewportSafeArea(home);
      await runtime.enterAgentSpace(
        sessionId: 'room:forced',
        animated: true,
        targetViewportSafeArea: const AvatarViewportSafeArea(),
      );
      transport.calls.clear();
      await runtime.leaveAgentSpace(sessionId: 'room:forced');
      expect(transport.calls.map((call) => call.method), ['leaveAgentSpace']);
      expect(
        (transport.calls.single.arguments as Map).keys,
        unorderedEquals(['requestId', 'sessionId']),
      );
      await transport.emit(const MethodCall('unready', {'reason': 'detached'}));
      await transport.emit(const MethodCall('ready'));
      expect(
        transport.calls
            .where((call) => call.method == 'setViewportSafeArea')
            .single
            .arguments,
        home.toJson(),
      );
    },
  );

  test(
    'cancelled entry cannot overwrite the completed forced exit viewport',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      const home = AvatarViewportSafeArea(top: .05, bottom: .35);
      await runtime.setViewportSafeArea(home);
      final entry = runtime.enterAgentSpace(
        sessionId: 'room:cancel',
        animated: true,
        targetViewportSafeArea: const AvatarViewportSafeArea(),
      );
      final check = expectLater(
        entry,
        throwsA(
          isA<AvatarAgentSpaceCommandException>().having(
            (error) => error.code,
            'code',
            'space_transition_cancelled',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final entryCall = transport.calls.last;
      final leave = runtime.leaveAgentSpace(sessionId: 'room:cancel');
      await Future<void>.delayed(Duration.zero);
      final leaveCall = transport.calls.last;
      await transport.emit(MethodCall('commandResult', _receipt(leaveCall)));
      await leave;
      await transport.emit(
        MethodCall('commandResult', {
          ..._receipt(entryCall),
          'ok': false,
          'code': 'space_transition_cancelled',
        }),
      );
      await check;
      await transport.emit(const MethodCall('unready', {'reason': 'detached'}));
      transport.calls.clear();
      await transport.emit(const MethodCall('ready'));
      expect(
        transport.calls
            .where((call) => call.method == 'setViewportSafeArea')
            .single
            .arguments,
        home.toJson(),
      );
    },
  );

  test(
    'late entry success cannot undo a newer session completed viewport',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      final first = runtime.enterAgentSpace(
        sessionId: 'room:first',
        targetViewportSafeArea: const AvatarViewportSafeArea(top: .1),
      );
      await Future<void>.delayed(Duration.zero);
      final firstCall = transport.calls.last;
      const newest = AvatarViewportSafeArea(top: .2, bottom: .3);
      final second = runtime.enterAgentSpace(
        sessionId: 'room:second',
        targetViewportSafeArea: newest,
      );
      await Future<void>.delayed(Duration.zero);
      await transport.emit(
        MethodCall('commandResult', _receipt(transport.calls.last)),
      );
      await second;
      await transport.emit(MethodCall('commandResult', _receipt(firstCall)));
      await first;
      await transport.emit(const MethodCall('unready', {'reason': 'detached'}));
      transport.calls.clear();
      await transport.emit(const MethodCall('ready'));
      expect(
        transport.calls
            .where((call) => call.method == 'setViewportSafeArea')
            .single
            .arguments,
        newest.toJson(),
      );
    },
  );

  for (final takeover in ['model']) {
    test(
      '$takeover takeover rejects an earlier room success already in transit',
      () async {
        final transport = _Transport();
        final runtime = UnityAvatarRuntime(transport: transport);
        addTearDown(runtime.onClose);
        await transport.emit(const MethodCall('ready'));
        const home = AvatarViewportSafeArea(top: .05, bottom: .35);
        await runtime.setViewportSafeArea(home);
        final entry = runtime.enterAgentSpace(
          sessionId: 'room:old-$takeover',
          animated: true,
          targetViewportSafeArea: const AvatarViewportSafeArea(),
        );
        final retired = expectLater(entry, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        final oldEntry = transport.calls.last;
        final replacement = runtime.loadAvatar(
          'unity://masso/avatar_matt',
          const {'avatar': 'matt'},
        );
        await Future<void>.delayed(Duration.zero);
        final replacedCall = transport.calls.last;
        expect(replacedCall.method, 'loadAvatar');
        // Unity sent the old success before receiving the replacement command;
        // Dart receives it while the newer replacement receipt is still pending.
        expect(
          await transport.emit(MethodCall('commandResult', _receipt(oldEntry))),
          isFalse,
        );
        await retired;
        await transport.emit(
          MethodCall('commandResult', _replacementReceipt(replacedCall)),
        );
        await replacement;
        await transport.emit(
          const MethodCall('unready', {'reason': 'detached'}),
        );
        transport.calls.clear();
        await transport.emit(const MethodCall('ready'));
        expect(
          transport.calls
              .where((call) => call.method == 'setViewportSafeArea')
              .single
              .arguments,
          home.toJson(),
        );
      },
    );

    test(
      '$takeover takeover restores Home cache after room entry already completed',
      () async {
        final transport = _Transport()..autoReceipt = true;
        final runtime = UnityAvatarRuntime(transport: transport);
        addTearDown(runtime.onClose);
        await transport.emit(const MethodCall('ready'));
        const home = AvatarViewportSafeArea(top: .08, bottom: .25);
        await runtime.setViewportSafeArea(home);
        await runtime.enterAgentSpace(
          sessionId: 'room:active-$takeover',
          animated: true,
          targetViewportSafeArea: const AvatarViewportSafeArea(),
        );
        final replacement = runtime.loadAvatar(
          'unity://masso/avatar_matt',
          const {'avatar': 'matt'},
        );
        await Future<void>.delayed(Duration.zero);
        await transport.emit(
          MethodCall(
            'commandResult',
            _replacementReceipt(transport.calls.last),
          ),
        );
        await replacement;
        await transport.emit(
          const MethodCall('unready', {'reason': 'detached'}),
        );
        transport.calls.clear();
        await transport.emit(const MethodCall('ready'));
        expect(
          transport.calls
              .where((call) => call.method == 'setViewportSafeArea')
              .single
              .arguments,
          home.toJson(),
        );
      },
    );
  }

  test(
    'same loaded model cache hit does not retire an active room operation',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      final load = runtime.loadAvatar('unity://masso/avatar_matt', const {
        'avatar': 'matt',
      });
      await Future<void>.delayed(Duration.zero);
      await transport.emit(
        MethodCall('commandResult', _replacementReceipt(transport.calls.last)),
      );
      await load;
      final entry = runtime.enterAgentSpace(
        sessionId: 'room:same-model',
        animated: true,
      );
      await Future<void>.delayed(Duration.zero);
      final entryCall = transport.calls.last;
      final count = transport.calls.length;
      await runtime.loadAvatar('unity://masso/avatar_matt', const {
        'avatar': 'matt',
      });
      expect(transport.calls, hasLength(count));
      expect(
        await transport.emit(MethodCall('commandResult', _receipt(entryCall))),
        isTrue,
      );
      await entry;
    },
  );

  test(
    'joining an already dispatched model load does not retire a newer room operation',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      final load = runtime.loadAvatar('unity://masso/avatar_matt', const {
        'avatar': 'matt',
      });
      await Future<void>.delayed(Duration.zero);
      final loadCall = transport.calls.last;
      final entry = runtime.enterAgentSpace(
        sessionId: 'room:joining',
        animated: true,
      );
      await Future<void>.delayed(Duration.zero);
      final entryCall = transport.calls.last;
      final count = transport.calls.length;
      final joined = runtime.loadAvatar('unity://masso/avatar_matt', const {
        'avatar': 'matt',
      });
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls, hasLength(count));
      expect(
        await transport.emit(MethodCall('commandResult', _receipt(entryCall))),
        isTrue,
      );
      await entry;
      await transport.emit(
        MethodCall('commandResult', _replacementReceipt(loadCall)),
      );
      await Future.wait([load, joined]);
    },
  );

  test(
    'invalid transition viewport is rejected before any native dispatch',
    () async {
      final transport = _Transport()..autoReceipt = true;
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      transport.calls.clear();
      for (final target in [
        const AvatarViewportSafeArea(top: -.01),
        const AvatarViewportSafeArea(bottom: .46),
        const AvatarViewportSafeArea(top: double.nan),
        const AvatarViewportSafeArea(bottom: double.infinity),
      ]) {
        for (final entering in [true, false]) {
          expect(
            () => entering
                ? runtime.enterAgentSpace(
                    sessionId: 'room:bad',
                    animated: true,
                    targetViewportSafeArea: target,
                  )
                : runtime.leaveAgentSpace(
                    sessionId: 'room:bad',
                    animated: true,
                    targetViewportSafeArea: target,
                  ),
            throwsArgumentError,
          );
        }
      }
      expect(transport.calls, isEmpty);
    },
  );

  test('native room rejection preserves a typed method and reason', () async {
    final transport = _Transport();
    final runtime = UnityAvatarRuntime(transport: transport);
    addTearDown(runtime.onClose);
    await transport.emit(const MethodCall('ready'));
    final operation = runtime.moveAgentSpaceAtScreenPoint(
      sessionId: 'room:blocked',
      x: .5,
      y: .5,
    );
    final check = expectLater(
      operation,
      throwsA(
        isA<AvatarAgentSpaceCommandException>()
            .having(
              (error) => error.method,
              'method',
              'requestAgentSpaceMoveAtScreenPoint',
            )
            .having((error) => error.code, 'code', 'path_blocked'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final args = transport.calls.last.arguments as Map;
    await transport.emit(
      MethodCall('commandResult', {
        'requestId': args['requestId'],
        'sessionId': args['sessionId'],
        'method': 'requestAgentSpaceMoveAtScreenPoint',
        'ok': false,
        'code': 'path_blocked',
      }),
    );
    await check;
  });

  test(
    'renderer loss retires pending entry and rejects late success',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      final operation = runtime.enterAgentSpace(sessionId: 'room:3');
      final check = expectLater(operation, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final args = Map<String, Object?>.from(
        transport.calls.last.arguments as Map,
      );
      await transport.emit(const MethodCall('unready', {'reason': 'detached'}));
      await check;
      await transport.emit(const MethodCall('ready'));
      expect(
        await transport.emit(
          MethodCall('commandResult', {
            ...args,
            'method': 'enterAgentSpace',
            'ok': true,
            'code': '',
          }),
        ),
        isFalse,
      );
    },
  );

  test(
    'space commands expose platform failures instead of apparent success',
    () async {
      final transport = _Transport();
      final runtime = UnityAvatarRuntime(transport: transport);
      addTearDown(runtime.onClose);
      await transport.emit(const MethodCall('ready'));
      transport.failMethod = 'enterAgentSpace';
      await expectLater(
        runtime.enterAgentSpace(sessionId: 'room:4'),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test('missing native space receipt times out', () async {
    final transport = _Transport();
    final runtime = UnityAvatarRuntime(
      transport: transport,
      agentSpaceTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(runtime.onClose);
    await transport.emit(const MethodCall('ready'));
    await expectLater(
      runtime.enterAgentSpace(sessionId: 'room:5'),
      throwsA(isA<TimeoutException>()),
    );
  });

  testWidgets('only animated exit has the longer bounded route deadline', (
    tester,
  ) async {
    final transport = _Transport();
    final runtime = UnityAvatarRuntime(
      transport: transport,
      agentSpaceTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(runtime.onClose);
    await transport.emit(const MethodCall('ready'));
    Object? failure;
    bool finished = false;
    final animated = runtime
        .leaveAgentSpace(sessionId: 'room:deadline', animated: true)
        .then<void>(
          (_) {
            finished = true;
          },
          onError: (Object error) {
            failure = error;
          },
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 15));
    expect(finished, isFalse);
    expect(failure, isNull);
    await tester.pump(const Duration(milliseconds: 6));
    await animated;
    expect(failure, isA<TimeoutException>());
    failure = null;
    final forced = runtime
        .leaveAgentSpace(sessionId: 'room:deadline')
        .catchError((Object error) {
          failure = error;
        });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 11));
    await forced;
    expect(failure, isA<TimeoutException>());
  });

  test('invalid session and points never reach the renderer', () async {
    final transport = _Transport();
    final runtime = UnityAvatarRuntime(transport: transport);
    addTearDown(runtime.onClose);
    await transport.emit(const MethodCall('ready'));
    transport.calls.clear();
    await expectLater(
      runtime.enterAgentSpace(sessionId: 'invalid room'),
      throwsArgumentError,
    );
    await expectLater(
      runtime.enterAgentSpace(sessionId: 'room:6\n'),
      throwsArgumentError,
    );
    await expectLater(
      runtime.enterAgentSpace(sessionId: 'a' * 129),
      throwsArgumentError,
    );
    expect(
      () => runtime.moveAgentSpaceAtScreenPoint(
        sessionId: 'room:6',
        x: double.nan,
        y: .2,
      ),
      throwsArgumentError,
    );
    expect(
      () => runtime.moveAgentSpaceAtScreenPoint(
        sessionId: 'room:6',
        x: 1.1,
        y: .2,
      ),
      throwsArgumentError,
    );
    expect(transport.calls, isEmpty);
  });
}

Map<String, Object?> _receipt(MethodCall call) {
  final args = call.arguments as Map;
  return {
    'method': call.method,
    'requestId': args['requestId'],
    'sessionId': args['sessionId'],
    'ok': true,
    'code': '',
  };
}

Map<String, Object?> _replacementReceipt(MethodCall call) => {
  'method': call.method,
  'requestId': (call.arguments as Map)['requestId'],
  'ok': true,
};

final class _Transport implements UnityAvatarTransport {
  final calls = <MethodCall>[];
  UnityAvatarMethodCallHandler? handler;
  bool autoReceipt = false;
  String? failMethod;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (method == failMethod) throw PlatformException(code: 'not_ready');
    if (autoReceipt &&
        (method == 'enterAgentSpace' ||
            method == 'leaveAgentSpace' ||
            method == 'requestAgentSpaceMoveAtScreenPoint')) {
      final args = Map<String, Object?>.from(arguments as Map);
      await emit(
        MethodCall('commandResult', {
          'requestId': args['requestId'],
          'sessionId': args['sessionId'],
          'method': method,
          'ok': true,
          'code': '',
        }),
      );
    }
    return null;
  }

  Future<dynamic> emit(MethodCall call) => handler!(call);
  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? value) =>
      handler = value;
  @override
  void dispose() => handler = null;
}
