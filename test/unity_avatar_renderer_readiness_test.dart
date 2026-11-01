import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_command_dispatch_sink.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    AvatarProductionOwnership.resetForTest();
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    final authority = appServices
        .maybeFind<AvatarProjectionProductionAuthority>();
    if (authority != null) {
      try {
        await authority.sealAndDrain();
      } on Object {
        // Renderer-loss cases deliberately retain the exact reset fence.
      }
    }
    await appServices.reset();
    AvatarProductionOwnership.resetForTest();
  });

  test(
    'iOS engine readiness waits for its attached native presentation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final transport = _ReadinessTransport();
      final runtime = appServices.put(UnityAvatarRuntime(transport: transport));
      await runtime.prepareView();
      final id = (transport.calls.last.arguments! as Map)['presentationId'];
      await transport.emit(const MethodCall('ready'));
      expect(runtime.isReady.value, isTrue);
      expect(runtime.presentationReady.value, isFalse);
      expect(
        await transport.emit(
          MethodCall('presentationState', {
            'presentationId': 'obsolete',
            'attached': true,
          }),
        ),
        isFalse,
      );
      expect(runtime.presentationReady.value, isFalse);
      await transport.emit(
        MethodCall('presentationState', {
          'presentationId': id,
          'attached': true,
        }),
      );
      expect(runtime.presentationReady.value, isTrue);
      await transport.emit(
        MethodCall('presentationState', {
          'presentationId': id,
          'attached': false,
        }),
      );
      expect(runtime.presentationReady.value, isFalse);
      expect(runtime.isReady.value, isTrue);
    },
  );

  test(
    'iOS attachment before engine ready becomes presentable only at ready',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final transport = _ReadinessTransport();
      final runtime = appServices.put(UnityAvatarRuntime(transport: transport));
      await runtime.prepareView();
      final id = (transport.calls.last.arguments! as Map)['presentationId'];
      await transport.emit(
        MethodCall('presentationState', {
          'presentationId': id,
          'attached': true,
        }),
      );
      expect(runtime.presentationReady.value, isFalse);
      await transport.emit(const MethodCall('ready'));
      expect(runtime.presentationReady.value, isTrue);
    },
  );

  for (final boundary in ['pause', 'detach', 'unready', 'close']) {
    test('iOS $boundary fences a delayed attachment receipt', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final transport = _ReadinessTransport();
      final runtime = appServices.put(UnityAvatarRuntime(transport: transport));
      final owner = Object();
      runtime.retainNativeView(owner);
      await runtime.prepareView();
      final id = (transport.calls.last.arguments! as Map)['presentationId'];
      await transport.emit(const MethodCall('ready'));
      final oldReceipt = MethodCall('presentationState', {
        'presentationId': id,
        'attached': true,
      });
      await transport.emit(oldReceipt);
      expect(runtime.presentationReady.value, isTrue);
      switch (boundary) {
        case 'pause':
          await runtime.pause();
        case 'detach':
          await runtime.releaseNativeView(owner);
        case 'unready':
          await transport.emit(const MethodCall('unready'));
        case 'close':
          runtime.closeLifecycle();
      }
      expect(runtime.presentationReady.value, isFalse);
      if (boundary == 'close') return;
      expect(await transport.emit(oldReceipt), isFalse);
      await runtime.prepareView();
      final replacementId =
          (transport.calls.last.arguments! as Map)['presentationId'];
      expect(replacementId, isNot(id));
      await transport.emit(const MethodCall('ready'));
      expect(await transport.emit(oldReceipt), isFalse);
      expect(runtime.presentationReady.value, isFalse);
      await transport.emit(
        MethodCall('presentationState', {
          'presentationId': replacementId,
          'attached': true,
        }),
      );
      expect(runtime.presentationReady.value, isTrue);
      if (boundary != 'detach') await runtime.releaseNativeView(owner);
    });
  }

  test('non-iOS presentation retains the engine readiness contract', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final transport = _ReadinessTransport();
    final runtime = appServices.put(UnityAvatarRuntime(transport: transport));
    expect(runtime.presentationReady, same(runtime.isReady));
    await transport.emit(const MethodCall('ready'));
    expect(runtime.presentationReady.value, isTrue);
    await runtime.prepareView();
    expect(transport.calls.last.arguments, isEmpty);
  });

  test(
    'unready to ready restores a real arbiter epoch while visibility awaits',
    () async {
      final transport = _ReadinessTransport();
      final runtime = appServices.put(UnityAvatarRuntime(transport: transport));
      final active = appServices.put(ActiveAvatarRuntime()..register(runtime));
      final flags = appServices.put(await _enforcedFlags());
      await transport.emit(const MethodCall('ready'));
      final authority = appServices.put(
        AvatarProjectionProductionAuthority(
          accountGeneration: 27,
          featureFlags: flags,
          activeAvatarRuntime: active,
          renderer: runtime,
          dispatchSink: runtime.commandDispatchSink,
          mountIsCurrent: () => true,
        ),
      );
      await _flush(authority);
      expect(authority.phase, AvatarProductionAuthorityPhase.enforcing);
      final firstGeneration = authority.rendererGeneration;

      await transport.emit(const MethodCall('unready'));
      await _flush(authority);
      final unavailableGeneration = authority.rendererGeneration;
      expect(unavailableGeneration, greaterThan(firstGeneration));
      expect(runtime.isReady.value, isFalse);
      transport.calls.clear();

      final visibility = transport.holdNext('setLocalAvatarVisible');
      addTearDown(visibility.release);
      final reconnect = transport.emit(const MethodCall('ready'));
      await visibility.entered.future;
      // Readiness is public while this unrelated native write is suspended.
      // The real production authority and real sink must already agree.
      expect(runtime.isReady.value, isTrue);
      await _flush(authority);
      expect(authority.phase, AvatarProductionAuthorityPhase.enforcing);
      expect(authority.rendererGeneration, greaterThan(unavailableGeneration));
      final reset = transport.calls.singleWhere(
        (call) => call.method == UnityAvatarCommandDispatchSink.resetMethod,
      );
      expect(
        (reset.arguments! as Map)['targetRendererGeneration'],
        authority.rendererGeneration,
      );
      expect(
        (await authority.applyCameraFraming(
          mode: 'upper_body',
          source: AvatarCommandSource.explicitUser,
        )).applied,
        isTrue,
      );
      expect(
        (runtime.commandDispatchSink as UnityAvatarCommandDispatchSink)
            .pendingReceiptCount,
        0,
      );
      visibility.release();
      expect(await reconnect, isTrue);
      await _flush(authority);
      expect(authority.phase, AvatarProductionAuthorityPhase.enforcing);
    },
  );

  for (final method in const [
    'setLocalAvatarVisible',
    'setExpression',
    'setViewportSafeArea',
    'setWorldTimeOfDay',
  ]) {
    for (final reconnectFirst in [false, true]) {
      test('late ready at $method cannot replay after '
          '${reconnectFirst ? "a newer ready" : "unready"}', () async {
        final transport = _ReadinessTransport();
        final runtime = appServices.put(
          UnityAvatarRuntime(transport: transport),
        );
        await runtime.setExpressionParams(
          const AvatarExpressionParams(happy: 0.4),
        );
        await runtime.setViewportSafeArea(
          const AvatarViewportSafeArea(top: 0.1, bottom: 0.2),
        );
        await runtime.setWorldLighting(AvatarWorldLighting.day);
        await runtime.resetAvatarForAccountBoundary(
          'unity://masso/avatar_agent',
        );
        transport.calls.clear();
        final held = transport.holdNext(method);
        addTearDown(held.release);
        final oldReady = transport.emit(const MethodCall('ready'));
        await held.entered.future;
        await transport.emit(const MethodCall('unready'));
        expect(runtime.isReady.value, isFalse);

        if (reconnectFirst) {
          expect(await transport.emit(const MethodCall('ready')), isTrue);
          await _settleNativeCallbacks();
          expect(transport.loads, hasLength(1));
        }
        final callsBeforeLateReturn = transport.calls.length;
        held.release();
        expect(await oldReady, isFalse);
        await _settleNativeCallbacks();
        expect(transport.calls, hasLength(callsBeforeLateReturn));
        expect(runtime.isReady.value, reconnectFirst);
        expect(transport.loads, hasLength(reconnectFirst ? 1 : 0));

        if (!reconnectFirst) {
          // The stale replay must leave the deferred account reset for the
          // next legitimate receiver, rather than consuming it offscreen.
          expect(await transport.emit(const MethodCall('ready')), isTrue);
          await _settleNativeCallbacks();
          expect(transport.loads, hasLength(1));
        }
        // The current receiver's acknowledged asset is cached normally.
        await runtime.loadAvatar('unity://masso/avatar_agent');
        expect(transport.loads, hasLength(1));
      });
    }
  }

  test('closing the runtime retires a suspended ready replay', () async {
    final transport = _ReadinessTransport();
    final runtime = appServices.put(UnityAvatarRuntime(transport: transport));
    await runtime.resetAvatarForAccountBoundary('unity://masso/avatar_agent');
    final held = transport.holdNext('setLocalAvatarVisible');
    addTearDown(held.release);
    final ready = transport.emit(const MethodCall('ready'));
    await held.entered.future;
    runtime.closeLifecycle();
    final callsBeforeLateReturn = transport.calls.length;
    held.release();
    expect(await ready, isFalse);
    await _settleNativeCallbacks();
    expect(transport.calls, hasLength(callsBeforeLateReturn));
    expect(transport.loads, isEmpty);
    expect(
      (runtime.commandDispatchSink as UnityAvatarCommandDispatchSink).isClosed,
      isTrue,
    );
  });
}

Future<void> _flush(AvatarProjectionProductionAuthority authority) async {
  for (var attempt = 0; attempt < 4; attempt++) {
    authority.phase;
    await Future<void>.delayed(Duration.zero);
    await authority.waitForIdle();
  }
}

Future<void> _settleNativeCallbacks() async {
  for (var attempt = 0; attempt < 4; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<MaasoFeatureFlagService> _enforcedFlags() async {
  final flags = await MaasoFeatureFlagService(
    store: _ReadinessFlagStore(),
    compileMaximums: const {
      MaasoFeatureFlag.avatarProjectionV2: FeatureRolloutMode.enforce,
    },
  ).init();
  await flags.assign(
    flag: MaasoFeatureFlag.avatarProjectionV2,
    mode: FeatureRolloutMode.enforce,
    revision: 1,
    expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
  );
  return flags;
}

final class _ReadinessFlagStore implements MaasoFeatureFlagAssignmentStore {
  final Map<MaasoFeatureFlag, Map<String, Object?>> _rows = {};

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      _rows.values.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    _rows[assignment.flag] = assignment.toJson();
  }
}

final class _ReadinessGate {
  _ReadinessGate(this.method);
  final String method;
  final entered = Completer<void>();
  final resumed = Completer<void>();

  void release() {
    if (!resumed.isCompleted) resumed.complete();
  }
}

/// The only fake is the platform transport. The production runtime, command
/// sink, authority, arbiter, ownership fences and receipt matching are real.
final class _ReadinessTransport implements UnityAvatarTransport {
  final List<MethodCall> calls = [];
  UnityAvatarMethodCallHandler? _handler;
  _ReadinessGate? _nextGate;

  List<MethodCall> get loads =>
      calls.where((call) => call.method == 'loadAvatar').toList();

  _ReadinessGate holdNext(String method) => _nextGate = _ReadinessGate(method);

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    final gate = _nextGate;
    if (gate != null && gate.method == method) {
      _nextGate = null;
      gate.entered.complete();
      await gate.resumed.future;
    }
    Map<String, Object?>? result;
    if (method == UnityAvatarCommandDispatchSink.commandMethod ||
        method == UnityAvatarCommandDispatchSink.resetMethod) {
      result = Map<String, Object?>.from(arguments! as Map)
        ..remove('payloadJson')
        ..addAll({'method': method, 'ok': true, 'code': ''});
    } else if (method == 'loadAvatar') {
      result = {
        'method': method,
        'requestId': (arguments! as Map)['requestId'],
        'ok': true,
      };
    }
    if (result != null) {
      final receipt = result;
      scheduleMicrotask(() {
        final handler = _handler;
        if (handler != null) {
          unawaited(handler(MethodCall('commandResult', receipt)));
        }
      });
    }
    return null;
  }

  Future<dynamic> emit(MethodCall call) {
    final handler = _handler;
    if (handler == null) throw StateError('renderer_handler_missing');
    return handler(call);
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {
    _handler = handler;
  }

  @override
  void dispose() => _handler = null;
}
