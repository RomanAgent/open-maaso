import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/services/account_runtime_drain_barrier.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/realtime_action_stream_service.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';

void main() {
  test('one failed drain does not prevent other safety drains', () async {
    final barrier = AccountRuntimeDrainBarrier();
    final notificationError = StateError('notification drain failed');
    var runtimeDrained = false;
    var micDrained = false;
    var rtcDrained = false;

    await Future.wait<void>(<Future<void>>[
      barrier.run('notification', () => throw notificationError),
      barrier.run('runtime', () async {
        runtimeDrained = true;
      }),
      barrier.run('microphone', () async {
        micDrained = true;
      }),
      barrier.run('rtc', () async {
        rtcDrained = true;
      }),
    ], eagerError: false);

    expect(runtimeDrained, isTrue);
    expect(micDrained, isTrue);
    expect(rtcDrained, isTrue);
    expect(barrier.errors.map((item) => item.stage), ['notification']);
    expect(barrier.throwFirst, throwsA(same(notificationError)));
  });

  test(
    'live retirement starts synchronously beside an unrelated hung drain',
    () async {
      final barrier = AccountRuntimeDrainBarrier();
      final hung = Completer<void>();
      var liveRetirementStarted = false;

      final unrelatedDrain = barrier.run('unrelated', () => hung.future);
      final liveDrain = barrier.run('live_host', () {
        liveRetirementStarted = true;
      });

      expect(liveRetirementStarted, isTrue);
      hung.complete();
      await Future.wait<void>(<Future<void>>[unrelatedDrain, liveDrain]);
    },
  );

  test(
    'registry shutdown drains admitted account work and fences late work',
    () async {
      final registry = AgentRuntimeRegistry();
      final entered = Completer<void>();
      final release = Completer<void>();
      var lateOptionalRan = false;

      final operation = registry.runRequiredAccountOperation(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      var shutdownCompleted = false;
      final shutdown = registry.shutdown().then(
        (_) => shutdownCompleted = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(shutdownCompleted, isFalse);
      expect(registry.isRetiring, isTrue);

      await registry.runAccountOperation(() async {
        lateOptionalRan = true;
      });
      expect(lateOptionalRan, isFalse);
      expect(
        () => registry.runRequiredAccountOperation(() async {}),
        throwsStateError,
      );

      release.complete();
      await operation;
      await shutdown;
      expect(shutdownCompleted, isTrue);
      await registry.shutdown();
    },
  );

  test(
    'action-stream shutdown drains an admitted envelope and rejects reconnect',
    () async {
      final client = _ControlledSseClient();
      final executionStarted = Completer<void>();
      final releaseExecution = Completer<void>();
      var executions = 0;
      final service = RealtimeActionStreamService(
        baseUri: _realtimeBaseUri,
        httpClient: client,
        executeEnvelope: (_) async {
          executions += 1;
          if (!executionStarted.isCompleted) executionStarted.complete();
          await releaseExecution.future;
        },
      );

      await service.connect(_legacyRealtimeSession());
      client.add(
        'data: {"reply":"","actions":[{"type":"avatar.react","mood":"happy"}]}\n\n',
      );
      await executionStarted.future;

      var shutdownCompleted = false;
      final shutdown = service.shutdown().then((_) => shutdownCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(shutdownCompleted, isFalse);

      client.add(
        'data: {"reply":"","actions":[{"type":"avatar.react","mood":"thinking"}]}\n\n',
      );
      await Future<void>.delayed(Duration.zero);
      expect(executions, 1);

      releaseExecution.complete();
      await shutdown;
      expect(shutdownCompleted, isTrue);
      await expectLater(
        service.connect(_legacyRealtimeSession()),
        throwsStateError,
      );
      await client.closeStream();
    },
  );

  test(
    'account producers and teardown are wired through the drain boundary',
    () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final accountDrainStart = mainSource.indexOf(
        'Future<void> _drainAccountRuntimeProducers()',
      );
      final accountDrainEnd = mainSource.indexOf(
        'void _registerDefaultVadServices()',
        accountDrainStart,
      );
      expect(accountDrainStart, greaterThanOrEqualTo(0));
      expect(accountDrainEnd, greaterThan(accountDrainStart));
      // Shared-lease retirement has its own live-host cleanup. Every ordering
      // assertion below concerns the full account drain and its local runtime.
      final accountDrainSource = mainSource.substring(
        accountDrainStart,
        accountDrainEnd,
      );
      final home = File(
        'lib/src/features/home/application/home_controller.dart',
      ).readAsStringSync();
      final u2a = File(
        'lib/src/features/chat/application/u2a_chat_controller.dart',
      ).readAsStringSync();
      for (final operation in <String>[
        '_sendTracedActive',
        '_maybeStartupGreetingActive',
        '_maybeBootstrapSoulInterviewActive',
        '_onProactiveActive',
        '_onCommittedProactiveActive',
      ]) {
        expect(home, contains(operation));
      }
      expect(home, contains('_registry.runAccountOperation'));
      expect(home, isNot(contains('AgentTaskJobStore(), permanent: true')));
      expect(
        u2a,
        contains('_registry.runAccountOperation(_loadMessagesActive)'),
      );
      expect(
        u2a,
        matches(
          RegExp(
            r'_registry\.runAccountOperation\(\s*'
            r'\(\) => _sendMessageActive\(text, generation\),?\s*\)',
          ),
        ),
      );

      expect(mainSource, contains('final taskJobs = await putOwnedAsync('));
      expect(
        mainSource,
        contains('SembastAgentTaskPersistence(mountedDatabase)'),
      );
      expect(
        mainSource,
        contains('AgentTaskJobStore>()?.deactivateAndDrain()'),
      );
      expect(mainSource, contains('runtimeRegistry.runAccountOperation'));
      expect(mainSource, contains('deactivateAccountAndDrain()'));
      expect(mainSource, contains("'agent_runtime'"));
      expect(mainSource, contains("'episode_store'"));
      expect(mainSource, contains("'outreach_feedback'"));
      expect(mainSource, contains("'llm_proxy_cache'"));
      expect(mainSource, contains("'microphone'"));
      expect(mainSource, contains("barrier.run('rtc'"));
      final feedbackDrainStart = accountDrainSource.indexOf(
        "final outreachFeedbackDrain = barrier.run('outreach_feedback'",
      );
      final feedbackReconcile = accountDrainSource.indexOf(
        'await collector.reconcile(',
        feedbackDrainStart,
      );
      final feedbackProducerWait = accountDrainSource.substring(
        feedbackDrainStart,
        feedbackReconcile,
      );
      expect(
        feedbackProducerWait,
        contains('proactiveNotificationDrain'),
        reason: 'the collector must outlive admitted OS scheduler ledger work',
      );
      final presenceStop = accountDrainSource.indexOf(
        'maybeFind<AgentPresenceService>()?.stop()',
      );
      final registryShutdown = accountDrainSource.indexOf(
        'runtimeRegistry?.shutdown()',
      );
      final runtimeDrainStart = accountDrainSource.indexOf(
        "final runtimeDrain = barrier.run(",
      );
      final memoryWriteDrainStart = accountDrainSource.indexOf(
        "final memoryWriteDrain = barrier.run('memory_write_coordinator'",
      );
      final episodeStoreDrainStart = accountDrainSource.indexOf(
        "final episodeStoreDrain = barrier.run('episode_store'",
      );
      final outreachFeedbackDrainStart = accountDrainSource.indexOf(
        "final outreachFeedbackDrain = barrier.run('outreach_feedback'",
      );
      final episodeMigrationPause = accountDrainSource.indexOf(
        'maybeFind<EpisodeStore>()?.requestMigrationPause()',
      );
      final llmProxyDrain = accountDrainSource.indexOf(
        'maybeFind<LLMProxyService>()',
      );
      final databaseClose = mainSource.indexOf('await database?.close()');
      final producerFenceDrain = mainSource.indexOf(
        'await _drainAccountRuntimeProducers()',
      );
      final ownerStart = mainSource.indexOf(
        'Future<AccountRuntimeLease> _mountAgentExecution(',
      );
      final ownerDelete = mainSource.indexOf(
        'for (final type in ownedTypes.reversed)',
        ownerStart,
      );
      final ownerFenceComplete = mainSource.indexOf(
        'await producerFenceHandle.complete()',
        ownerStart,
      );
      expect(ownerDelete, greaterThan(ownerStart));
      expect(ownerFenceComplete, greaterThan(ownerDelete));
      expect(presenceStop, greaterThanOrEqualTo(0));
      expect(episodeMigrationPause, greaterThanOrEqualTo(0));
      expect(episodeMigrationPause, lessThan(registryShutdown));
      expect(registryShutdown, greaterThan(presenceStop));
      expect(runtimeDrainStart, greaterThanOrEqualTo(0));
      expect(memoryWriteDrainStart, greaterThan(runtimeDrainStart));
      expect(episodeStoreDrainStart, greaterThan(memoryWriteDrainStart));
      expect(outreachFeedbackDrainStart, greaterThan(episodeStoreDrainStart));
      final memoryWriteDrainSource = accountDrainSource.substring(
        memoryWriteDrainStart,
        episodeStoreDrainStart,
      );
      expect(memoryWriteDrainSource, contains('await runtimeDrain;'));
      expect(
        memoryWriteDrainSource,
        contains('maybeFind<MemoryWriteCoordinator>()?.deactivateAndDrain()'),
      );
      expect(
        memoryWriteDrainSource.indexOf('await runtimeDrain;'),
        lessThan(
          memoryWriteDrainSource.indexOf(
            'maybeFind<MemoryWriteCoordinator>()?.deactivateAndDrain()',
          ),
        ),
      );
      final episodeStoreDrainSource = accountDrainSource.substring(
        episodeStoreDrainStart,
        outreachFeedbackDrainStart,
      );
      expect(episodeStoreDrainSource, contains('await memoryWriteDrain;'));
      expect(
        episodeStoreDrainSource,
        contains('maybeFind<EpisodeStore>()?.deactivateAndDrain()'),
      );
      expect(
        episodeStoreDrainSource.indexOf('memoryWriteDrain'),
        lessThan(
          episodeStoreDrainSource.indexOf(
            'maybeFind<EpisodeStore>()?.deactivateAndDrain()',
          ),
        ),
      );
      expect(llmProxyDrain, greaterThan(registryShutdown));
      expect(producerFenceDrain, greaterThanOrEqualTo(0));
      expect(databaseClose, greaterThan(producerFenceDrain));
    },
  );
}

final Uri _realtimeBaseUri = Uri.parse('${MaasoEnvironment.test.baseUrl}/');

RealtimeSession _legacyRealtimeSession() => RealtimeSession(
  sessionId: 'ms_runtime_drain',
  locale: 'en',
  rtcAppId: 'volc-app-id',
  roomId: 'room_runtime_drain',
  userId: 'user_runtime_drain',
  agentUserId: 'agent_runtime_drain',
  taskId: 'task_runtime_drain',
  rtcToken: 'rtc-token',
  actionStreamUri: _realtimeBaseUri.resolve(
    '/v1/realtime/sessions/ms_runtime_drain/actions',
  ),
  createdAt: DateTime.utc(2026, 8, 21, 12),
);

class _ControlledSseClient extends http.BaseClient {
  final StreamController<List<int>> _controller = StreamController<List<int>>();

  void add(String value) => _controller.add(utf8.encode(value));

  Future<void> closeStream() => _controller.close();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        _controller.stream,
        200,
        headers: const {'content-type': 'text/event-stream'},
        request: request,
      );
}
