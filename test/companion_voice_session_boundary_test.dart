import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/app_agent_shell.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_boundary.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/presentation/companion/companion_session_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'account teardown drains a gated companion turn before DB close',
    () async {
      final events = <String>[];
      final database = _RecordingDatabase(events);
      final runtime = _GatedRuntime(events);
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _FixedRuntimeRegistry(runtime),
      );
      final boundary = CompanionVoiceSessionBoundary()..attach(controller);
      addTearDown(() {
        boundary.detach(controller);
        controller.dispose();
      });

      controller.activate();
      controller.inputController.text = 'stay with me';
      final send = controller.sendVoiceMessage();
      await runtime.started.future;

      var teardownCompleted = false;
      final teardown = () async {
        await boundary.deactivateAndDrain();
        await database.close();
        teardownCompleted = true;
      }();
      await Future<void>.delayed(Duration.zero);

      expect(
        runtime.cancelCalls,
        0,
        reason: 'account draining must not issue an unqualified runtime cancel',
      );
      expect(controller.active, isFalse);
      expect(database.closed, isFalse);
      expect(teardownCompleted, isFalse);

      runtime.release.complete(ExecutionResult.success('done'));
      await teardown;
      await send;

      expect(database.closed, isTrue);
      expect(events.last, 'db.close');
      expect(
        events.indexOf('runtime.complete'),
        lessThan(events.indexOf('db.close')),
      );

      final eventCountAfterDrain = events.length;
      controller.activate();
      controller.inputController.text = 'start a stale turn';
      await controller.sendVoiceMessage();
      expect(controller.active, isFalse);
      expect(events, hasLength(eventCountAfterDrain));
    },
  );

  test('late attached controller joins the retiring account drain', () async {
    final aRuntime = _GatedRuntime(<String>[]);
    final aController = CompanionVoiceSessionController(
      database: _RecordingDatabase(<String>[]),
      runtimeRegistry: _FixedRuntimeRegistry(aRuntime),
    );
    final boundary = CompanionVoiceSessionBoundary()..attach(aController);
    addTearDown(() {
      boundary.detach(aController);
      aController.dispose();
    });

    aController.activate();
    aController.inputController.text = 'A is still speaking';
    final aTurn = aController.sendVoiceMessage();
    await aRuntime.started.future;

    var drainCompleted = false;
    final drain = boundary.deactivateAndDrain().then(
      (_) => drainCompleted = true,
    );
    expect(boundary.isRetiring, isTrue);

    final bRuntime = _GatedRuntime(<String>[]);
    final bController = CompanionVoiceSessionController(
      database: _RecordingDatabase(<String>[]),
      runtimeRegistry: _FixedRuntimeRegistry(bRuntime),
    );
    addTearDown(() {
      boundary.detach(bController);
      bController.dispose();
    });
    bController.activate();
    bController.inputController.text = 'late account-A controller';
    final bTurn = bController.sendVoiceMessage();
    await bRuntime.started.future;

    boundary.attach(bController);
    await Future<void>.delayed(Duration.zero);
    expect(
      bRuntime.cancelCalls,
      0,
      reason: 'a retired controller can revoke only its captured turn',
    );

    aRuntime.release.complete(ExecutionResult.success('A done'));
    await aTurn;
    await Future<void>.delayed(Duration.zero);
    expect(
      drainCompleted,
      isFalse,
      reason: 'a controller attached during retirement must join the drain',
    );

    bRuntime.release.complete(ExecutionResult.success('late done'));
    await Future.wait<void>(<Future<void>>[bTurn, drain]);
    expect(drainCompleted, isTrue);
    expect(boundary.hasAttachedControllers, isFalse);

    await boundary.activateAccount();
    expect(boundary.isRetiring, isFalse);
    final nextController = CompanionVoiceSessionController(
      database: _RecordingDatabase(<String>[]),
      runtimeRegistry: _FixedRuntimeRegistry(_GatedRuntime(<String>[])),
    );
    boundary.attach(nextController);
    nextController.activate();
    expect(nextController.active, isTrue);
    boundary.detach(nextController);
    nextController.dispose();
  });

  test(
    'final seal waits for a gated controller attached after first drain',
    () async {
      final boundary = CompanionVoiceSessionBoundary();
      await boundary.deactivateAndDrain();

      final events = <String>[];
      final database = _RecordingDatabase(events);
      final runtime = _GatedRuntime(events);
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _FixedRuntimeRegistry(runtime),
      );
      addTearDown(() {
        boundary.detach(controller);
        controller.dispose();
      });
      controller.activate();
      controller.inputController.text = 'attached after first drain';
      final turn = controller.sendVoiceMessage();
      await runtime.started.future;
      boundary.attach(controller);

      var accountDisposeCompleted = false;
      final accountDispose = () async {
        await boundary.sealAndDrain();
        await database.close();
        accountDisposeCompleted = true;
      }();
      await Future<void>.delayed(Duration.zero);

      expect(accountDisposeCompleted, isFalse);
      expect(database.closed, isFalse);
      runtime.release.complete(ExecutionResult.success('finished'));
      await Future.wait<void>(<Future<void>>[turn, accountDispose]);

      expect(accountDisposeCompleted, isTrue);
      expect(
        events.indexOf('runtime.complete'),
        lessThan(events.indexOf('db.close')),
      );
    },
  );

  testWidgets(
    'AppAgentShell attaches and detaches its account voice controller',
    (tester) async {
      final boundary = appServices.put(CompanionVoiceSessionBoundary());
      final activeAvatar = appServices.put(ActiveAvatarRuntime());
      activeAvatar.register(_ReadyAvatarRuntime()..isReady.value = true);
      appServices.put(DBService());
      appServices.put(AgentRuntimeRegistry());
      final coordinator = AgentUiControlCoordinator();

      Widget shell() => MaterialApp(
        home: AppAgentShell(
          coordinator: coordinator,
          child: const ColoredBox(color: Colors.white),
        ),
      );

      await tester.pumpWidget(shell());
      await tester.pump();

      expect(find.byType(CompanionSessionScope), findsOneWidget);
      expect(boundary.hasAttachedControllers, isTrue);

      await appServices.delete<AgentRuntimeRegistry>();
      await appServices.delete<DBService>();
      await tester.pumpWidget(shell());
      await tester.pump();
      await tester.pump();

      expect(find.byType(CompanionSessionScope), findsNothing);
      expect(boundary.hasAttachedControllers, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await coordinator.dispose();
    },
  );

  test('main drains companion voice before deleting account services', () {
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

    final drain = producerDrainBody.indexOf("'companion_voice'");
    final drainWait = producerDrainBody.indexOf(
      'await Future.wait<void>(<Future<void>>[',
    );
    final producerFence = source.indexOf(
      'fenceRuntime: producerFence.fenceAndDrain',
    );
    final drainProducers = disposeBody.indexOf(
      'await _drainAccountRuntimeProducers()',
    );
    final finalSeal = disposeBody.indexOf('?.sealAndDrain()');
    final deleteConsumers = disposeBody.indexOf('for (final type');
    final closeDatabase = disposeBody.indexOf('await database?.close()');

    expect(drain, greaterThanOrEqualTo(0));
    expect(drain, lessThan(drainWait));
    expect(producerFence, greaterThanOrEqualTo(0));
    expect(producerFence, lessThan(disposeStart));
    expect(drainProducers, greaterThanOrEqualTo(0));
    expect(finalSeal, greaterThan(drainProducers));
    expect(finalSeal, lessThan(deleteConsumers));
    expect(deleteConsumers, greaterThan(drainProducers));
    expect(closeDatabase, greaterThan(deleteConsumers));
    expect(
      source.indexOf('CompanionVoiceSessionBoundary(), permanent: true'),
      greaterThanOrEqualTo(0),
    );
  });
}

class _RecordingDatabase extends DBService {
  _RecordingDatabase(this.events);

  final List<String> events;
  bool closed = false;

  @override
  Future<List<ChatMessage>> getRecentMessages(
    String sessionId, {
    int limit = 8,
  }) async => const <ChatMessage>[];

  @override
  Future<int> saveChatMessage(ChatMessage message) async {
    events.add(message.isUserMessage ? 'db.save.user' : 'db.save.agent');
    return events.length;
  }

  @override
  Future<void> close() async {
    closed = true;
    events.add('db.close');
  }
}

class _FixedRuntimeRegistry extends AgentRuntimeRegistry {
  _FixedRuntimeRegistry(this.runtime);

  final AgentRuntime runtime;

  @override
  AgentRuntime? get(String agentId) => runtime;
}

class _GatedRuntime extends AgentRuntime {
  _GatedRuntime(this.events)
    : super(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const <String>[],
          catchphrase: '',
        ),
        llmClient: _UnusedLlmClient(),
      );

  final List<String> events;
  final Completer<void> started = Completer<void>();
  final Completer<ExecutionResult> release = Completer<ExecutionResult>();
  int cancelCalls = 0;

  @override
  Stream<String> get onLocalReplyDelta => const Stream<String>.empty();

  @override
  Future<ExecutionResult> chat(
    String text,
    List<Message> history, {
    TurnOrigin origin = TurnOrigin.user,
    String? currentUserText,
    StreamingAudioSink? liveAudioSink,
    String? expectedAppletScopeKey,
  }) async {
    events.add('runtime.start');
    if (!started.isCompleted) started.complete();
    final result = await release.future;
    events.add('runtime.complete');
    return result;
  }

  @override
  void cancelCurrent() {
    cancelCalls += 1;
    events.add('runtime.cancel');
  }
}

class _UnusedLlmClient implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReadyAvatarRuntime extends AvatarRuntime {
  @override
  final AvatarBackendKind backendKind = AvatarBackendKind.unity;

  @override
  final isReady = false.obs;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
