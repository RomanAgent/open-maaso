import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/realtime_action_cursor_store.dart';
import 'package:maaso/src/core/services/realtime_action_stream_service.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    appServices.put(SecureStorageService());
  });

  tearDown(appServices.reset);

  test('SSE parser preserves id, event, comments, and split CRLF data', () {
    final parser = RealtimeActionSseParser();

    expect(parser.add(': connected\r'), isEmpty);
    expect(parser.add('\n\r\n'), isEmpty);
    final frames = parser.add(
      'id: 41\r\nevent: realtime.action\r\n'
      'data: {"first":\r\n'
      'data: "second"}\r\n\r\n',
    );
    expect(frames, hasLength(1));
    expect(frames.single.id, '41');
    expect(frames.single.event, 'realtime.action');
    expect(frames.single.data, '{"first":\n"second"}');
  });

  test(
    'legacy stream executes a bare envelope with its captured locale',
    () async {
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;
      final seen = Completer<(AgentActionEnvelope, AppLocale)>();
      final client = _StaticSseClient(
        'data: {"reply":"hi","actions":[{"type":"avatar.react","mood":"happy"}]}\n\n',
      );
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: client,
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (envelope) {
          if (!seen.isCompleted) {
            seen.complete((envelope, AgentPromptCatalog.currentLocale));
          }
        },
      );

      await service.connect(_legacySession());
      locale.locale.value = AppLocale.en;

      final result = await seen.future.timeout(const Duration(seconds: 1));
      expect(result.$1.reply, 'hi');
      expect(result.$1.actions.single.type, 'avatar.react');
      expect(result.$2, AppLocale.zh);

      await service.disconnect();
    },
  );

  test(
    'default legacy stream reports rejected generated surfaces and stops',
    () async {
      final surface = appServices.put(SurfaceRuntime());
      final rejected = Completer<Object>();
      final terminal = Completer<Object>();
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: _StaticSseClient('''
data: {"reply":"","actions":[{"type":"surface.show","surface":{"title":"Remote surface","kind":"fullscreen","rendering":"dom","html":"<main>unsafe</main>","css":"","js":"","manifest":{"events":[],"actions":[]}}}]}

'''),
        onExecutionError: (error, _, _) {
          if (!rejected.isCompleted) rejected.complete(error);
        },
        onTerminalFailure: (error, _) {
          if (!terminal.isCompleted) terminal.complete(error);
        },
      );

      await service.connect(_legacySession());

      final error = await rejected.future.timeout(const Duration(seconds: 1));
      expect(error, isA<StateError>());
      expect(error.toString(), contains('realtime action execution failed'));
      expect(
        await terminal.future.timeout(const Duration(seconds: 1)),
        same(error),
      );
      expect(surface.isVisible.value, isFalse);
      expect(surface.activeProject.value, isNull);

      await service.disconnect();
    },
  );

  test('unfenced realtime rejects enforce before injected execution', () async {
    final contract = await _installRealtimeContract(readOnly: true);
    final terminal = Completer<Object>();
    var executions = 0;
    final service = RealtimeActionStreamService(
      baseUri: _baseUri,
      httpClient: _StaticSseClient(
        'data: {"reply":"","actions":[{"type":"avatar.react","mood":"happy"}]}\n\n',
      ),
      actionContract: contract.service,
      productionActionCatalog: contract.catalog,
      requirePinnedActionContract: true,
      reconnectDelay: (_) => const Duration(minutes: 1),
      executeEnvelope: (_) => executions += 1,
      onTerminalFailure: (error, _) {
        if (!terminal.isCompleted) terminal.complete(error);
      },
    );

    await service.connect(_legacySession());

    final error = await terminal.future.timeout(const Duration(seconds: 1));
    expect(error, isA<StateError>());
    expect(error.toString(), contains('unfenced enforce'));
    expect(executions, 0);
    await service.disconnect();
  });

  test('unfenced realtime keeps exact off and shadow behavior', () async {
    for (final mode in <FeatureRolloutMode>[
      FeatureRolloutMode.off,
      FeatureRolloutMode.shadow,
    ]) {
      final contract = await _installRealtimeContract(
        readOnly: true,
        mode: mode,
      );
      final executed = Completer<void>();
      var executions = 0;
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: _StaticSseClient(
          'data: {"reply":"","actions":[{"type":"avatar.react","mood":"happy"}]}\n\n',
        ),
        actionContract: contract.service,
        productionActionCatalog: contract.catalog,
        requirePinnedActionContract: true,
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (_) {
          executions += 1;
          if (!executed.isCompleted) executed.complete();
        },
      );

      await service.connect(_legacySession());
      await executed.future.timeout(const Duration(seconds: 1));

      expect(executions, 1, reason: mode.name);
      await service.disconnect();
      await appServices.delete<ActionContractV2Service>(force: true);
      await appServices.delete<ProductionActionDefinitionCatalog>(force: true);
    }
  });

  test(
    'legacy fenced stream executes then commits and dedupes a legal gap',
    () async {
      final authority = await _authorityHarness();
      final cursor = _MemoryCursorStore(initial: 40);
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final secondFinished = Completer<void>();
      final operations = <String>[];
      cursor.onClaim = (sequence) {
        operations.add('claim:$sequence');
      };
      final body = [
        _runtimeEvent(sequence: 41, eventId: 'event_0041', mood: 'first'),
        _runtimeEvent(sequence: 41, eventId: 'event_0041', mood: 'first'),
        _runtimeEvent(sequence: 44, eventId: 'event_0044', mood: 'second'),
      ].join();
      final client = _StaticSseClient(body);
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: client,
        cursorStore: cursor,
        accessTokenProvider: () async => 'access-token',
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (envelope) async {
          final mood = envelope.actions.single['mood'];
          operations.add('execute:$mood:start');
          if (mood == 'first') {
            firstStarted.complete();
            await releaseFirst.future;
          }
          operations.add('execute:$mood:end');
          if (mood == 'second' && !secondFinished.isCompleted) {
            secondFinished.complete();
          }
        },
      );

      await service.connect(_fencedSession(), authority: authority.authority);
      await firstStarted.future.timeout(const Duration(seconds: 1));

      expect(operations, <String>['execute:first:start']);
      expect(cursor.claims, isEmpty);
      expect(client.requests, hasLength(1));
      final request = client.requests.single;
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(_header(request, 'authorization'), 'Bearer access-token');
      expect(_header(request, 'last-event-id'), '40');
      expect(_header(request, 'x-maaso-runtime-agent-id'), 'self');
      expect(
        _header(request, 'x-maaso-runtime-lease-id'),
        authority.authority.leaseId,
      );
      expect(_header(request, 'x-maaso-runtime-lease-epoch'), '1');
      expect(
        _header(request, 'x-maaso-runtime-instance-id'),
        authority.authority.runtimeInstanceId,
      );
      expect(
        _header(request, 'x-maaso-runtime-presence-session-id'),
        authority.authority.presenceSessionId,
      );
      expect(
        _header(request, 'x-maaso-runtime-holder-proof'),
        authority.holderProof,
      );

      releaseFirst.complete();
      await secondFinished.future.timeout(const Duration(seconds: 1));
      await _waitUntil(() => cursor.claims.length == 2);

      expect(operations, <String>[
        'execute:first:start',
        'execute:first:end',
        'claim:41',
        'execute:second:start',
        'execute:second:end',
        'claim:44',
      ]);
      expect(cursor.claims, <int>[41, 44]);
      expect(cursor.value, 44);

      await service.disconnect();
    },
  );

  test('fenced stream rejects inconsistent durable metadata', () async {
    final authority = await _authorityHarness();
    final cases = <String, String>{
      'SSE id': _runtimeEvent(
        sequence: 2,
        frameSequence: 1,
        eventId: 'event_id_mismatch',
      ),
      'subject': _runtimeEvent(
        sequence: 2,
        eventId: 'event_subject_mismatch',
        subjectId: 'ms_other_session',
      ),
      'session': _runtimeEvent(
        sequence: 2,
        eventId: 'event_session_mismatch',
        sessionId: 'ms_other_session',
      ),
      'lease epoch': _runtimeEvent(
        sequence: 2,
        eventId: 'event_epoch_mismatch',
        leaseEpoch: 2,
      ),
      'RTC generation': _runtimeEvent(
        sequence: 2,
        eventId: 'event_generation_mismatch',
        rtcGeneration: 4,
      ),
      'extra wrapper key': _runtimeEvent(
        sequence: 2,
        eventId: 'event_extra_wrapper',
        wrapperExtras: const <String, Object?>{'unexpected': true},
      ),
      'extra payload key': _runtimeEvent(
        sequence: 2,
        eventId: 'event_extra_payload',
        payloadExtras: const <String, Object?>{'unexpected': true},
      ),
    };

    for (final entry in cases.entries) {
      final cursor = _MemoryCursorStore();
      final terminal = Completer<Object>();
      var executions = 0;
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: _StaticSseClient(entry.value),
        cursorStore: cursor,
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (_) => executions += 1,
        onTerminalFailure: (error, _) {
          if (!terminal.isCompleted) terminal.complete(error);
        },
      );

      await service.connect(_fencedSession(), authority: authority.authority);

      final error = await terminal.future.timeout(const Duration(seconds: 1));
      expect(error, isA<FormatException>(), reason: entry.key);
      expect(executions, 0, reason: entry.key);
      expect(cursor.claims, isEmpty, reason: entry.key);
      await service.disconnect();
    }
  });

  test(
    'failed legacy fenced execution neither commits nor admits later events',
    () async {
      final authority = await _authorityHarness();
      final cursor = _MemoryCursorStore();
      final executionError = Completer<Object>();
      final terminal = Completer<Object>();
      final executed = <String>[];
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: _StaticSseClient(
          _runtimeEvent(sequence: 1, eventId: 'event_failure_1', mood: 'fail') +
              _runtimeEvent(
                sequence: 2,
                eventId: 'event_failure_2',
                mood: 'later',
              ),
        ),
        cursorStore: cursor,
        executeEnvelope: (envelope) {
          final mood = envelope.actions.single['mood'].toString();
          executed.add(mood);
          throw StateError('synthetic execution failure');
        },
        onExecutionError: (error, _, _) {
          if (!executionError.isCompleted) executionError.complete(error);
        },
        onTerminalFailure: (error, _) {
          if (!terminal.isCompleted) terminal.complete(error);
        },
      );

      await service.connect(_fencedSession(), authority: authority.authority);

      final error = await executionError.future.timeout(
        const Duration(seconds: 1),
      );
      expect(error, isA<StateError>());
      expect(
        await terminal.future.timeout(const Duration(seconds: 1)),
        same(error),
      );
      expect(executed, <String>['fail']);
      expect(cursor.claims, isEmpty);
      expect(cursor.value, 0);

      await service.disconnect();
    },
  );

  test(
    'fenced stream never follows redirects or accepts another origin',
    () async {
      final authority = await _authorityHarness();
      final redirectClient = _StatusClient(
        statusCode: 307,
        headers: const <String, String>{
          'location': 'https://evil.example.test/steal',
          'content-type': 'application/json',
        },
        body: '{"code":"TEMPORARY_REDIRECT"}',
      );
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: redirectClient,
        cursorStore: _MemoryCursorStore(),
      );

      await expectLater(
        service.connect(_fencedSession(), authority: authority.authority),
        throwsA(
          isA<RealtimeBackendException>().having(
            (error) => error.statusCode,
            'statusCode',
            307,
          ),
        ),
      );
      expect(redirectClient.requests, hasLength(1));
      expect(redirectClient.requests.single.followRedirects, isFalse);
      expect(redirectClient.requests.single.maxRedirects, 0);

      await expectLater(
        service.connect(
          _fencedSession(
            actionStreamUri: Uri.parse(
              'https://evil.example.test/v1/realtime/sessions/ms_session_1/actions',
            ),
          ),
          authority: authority.authority,
        ),
        throwsStateError,
      );
      expect(redirectClient.requests, hasLength(1));

      await service.shutdown();
    },
  );

  test('reconnect resumes from the last durably claimed sequence', () async {
    final authority = await _authorityHarness();
    final cursor = _MemoryCursorStore();
    final client = _ReconnectSseClient(
      firstBody: _runtimeEvent(
        sequence: 1,
        eventId: 'event_reconnect_1',
        mood: 'first',
      ),
      secondBody: _runtimeEvent(
        sequence: 3,
        eventId: 'event_reconnect_3',
        mood: 'second',
      ),
    );
    final executed = <String>[];
    final secondExecuted = Completer<void>();
    final service = RealtimeActionStreamService(
      baseUri: _baseUri,
      httpClient: client,
      cursorStore: cursor,
      reconnectDelay: (_) => Duration.zero,
      executeEnvelope: (envelope) {
        final mood = envelope.actions.single['mood'].toString();
        executed.add(mood);
        if (mood == 'second' && !secondExecuted.isCompleted) {
          secondExecuted.complete();
        }
      },
    );

    await service.connect(_fencedSession(), authority: authority.authority);
    await secondExecuted.future.timeout(const Duration(seconds: 1));
    await _waitUntil(() => cursor.value == 3);

    expect(executed, <String>['first', 'second']);
    expect(cursor.claims, <int>[1, 3]);
    expect(client.requests, hasLength(2));
    expect(_header(client.requests[0], 'last-event-id'), '0');
    expect(_header(client.requests[1], 'last-event-id'), '1');
    expect(
      client.requests.every((request) => !request.followRedirects),
      isTrue,
    );

    await service.disconnect();
    await client.close();
  });

  test(
    'background reconnect retries one 401 with a fresh bearer and claimed cursor',
    () async {
      final authority = await _authorityHarness();
      final cursor = _MemoryCursorStore();
      final client = _UnauthorizedReconnectSseClient(
        initialBody: _runtimeEvent(
          sequence: 1,
          eventId: 'event_reauth_1',
          mood: 'first',
        ),
        resumedBody:
            _runtimeEvent(
              sequence: 1,
              eventId: 'event_reauth_1',
              mood: 'duplicate',
            ) +
            _runtimeEvent(
              sequence: 2,
              eventId: 'event_reauth_2',
              mood: 'second',
            ),
      );
      final tokens = <String>[
        'initial-token',
        'expired-token',
        'refreshed-token',
      ];
      var tokenReads = 0;
      final executed = <String>[];
      final secondExecuted = Completer<void>();
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: client,
        cursorStore: cursor,
        reconnectDelay: (_) => Duration.zero,
        accessTokenProvider: () async => tokens[tokenReads++],
        executeEnvelope: (envelope) {
          final mood = envelope.actions.single['mood'].toString();
          executed.add(mood);
          if (mood == 'second' && !secondExecuted.isCompleted) {
            secondExecuted.complete();
          }
        },
      );

      await service.connect(_fencedSession(), authority: authority.authority);
      await secondExecuted.future.timeout(const Duration(seconds: 1));
      await _waitUntil(() => cursor.value == 2);

      expect(client.requests, hasLength(3));
      expect(tokenReads, 3);
      expect(
        _header(client.requests[0], 'authorization'),
        'Bearer initial-token',
      );
      expect(_header(client.requests[0], 'last-event-id'), '0');
      expect(
        _header(client.requests[1], 'authorization'),
        'Bearer expired-token',
      );
      expect(_header(client.requests[1], 'last-event-id'), '1');
      expect(
        _header(client.requests[2], 'authorization'),
        'Bearer refreshed-token',
      );
      expect(_header(client.requests[2], 'last-event-id'), '1');
      expect(executed, <String>['first', 'second']);
      expect(cursor.claims, <int>[1, 2]);

      await service.disconnect();
      await client.close();
    },
  );

  test(
    'enforced realtime claims then rejects a mutation before execution',
    () async {
      final contract = await _installRealtimeContract(readOnly: false);
      final authority = await _authorityHarness();
      final cursor = _MemoryCursorStore();
      final terminal = Completer<Object>();
      var executions = 0;
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: _StaticSseClient(
          _runtimeEvent(sequence: 1, eventId: 'event_contract_reject_1'),
        ),
        cursorStore: cursor,
        actionContract: contract.service,
        productionActionCatalog: contract.catalog,
        requirePinnedActionContract: true,
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (_) => executions += 1,
        onTerminalFailure: (error, _) {
          if (!terminal.isCompleted) terminal.complete(error);
        },
      );

      await service.connect(_fencedSession(), authority: authority.authority);
      final error = await terminal.future.timeout(const Duration(seconds: 1));

      expect(error, isA<StateError>());
      expect(executions, 0);
      expect(cursor.claims, <int>[1]);
      expect(cursor.value, 1);
      await service.disconnect();
    },
  );

  test('enforced realtime claims before one read-only execution', () async {
    final contract = await _installRealtimeContract(readOnly: true);
    final authority = await _authorityHarness();
    final cursor = _MemoryCursorStore();
    final executed = Completer<void>();
    var executions = 0;
    final service = RealtimeActionStreamService(
      baseUri: _baseUri,
      httpClient: _StaticSseClient(
        _runtimeEvent(sequence: 1, eventId: 'event_contract_read_1'),
      ),
      cursorStore: cursor,
      actionContract: contract.service,
      productionActionCatalog: contract.catalog,
      requirePinnedActionContract: true,
      reconnectDelay: (_) => const Duration(minutes: 1),
      executeEnvelope: (_) {
        executions += 1;
        if (!executed.isCompleted) executed.complete();
      },
    );

    await service.connect(_fencedSession(), authority: authority.authority);
    await executed.future.timeout(const Duration(seconds: 1));
    await _waitUntil(() => cursor.value == 1);

    expect(executions, 1);
    expect(cursor.claims, <int>[1]);
    await service.disconnect();
  });

  test(
    'enforced claim failure abandons its admission before stopping',
    () async {
      final contract = await _installRealtimeContract(readOnly: true);
      final authority = await _authorityHarness();
      final terminal = Completer<Object>();
      var executions = 0;
      final service = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: _StaticSseClient(
          _runtimeEvent(sequence: 1, eventId: 'event_claim_failure_1'),
        ),
        cursorStore: _FailingClaimCursorStore(),
        actionContract: contract.service,
        productionActionCatalog: contract.catalog,
        requirePinnedActionContract: true,
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (_) => executions += 1,
        onTerminalFailure: (error, _) {
          if (!terminal.isCompleted) terminal.complete(error);
        },
      );

      await service.connect(_fencedSession(), authority: authority.authority);
      await terminal.future.timeout(const Duration(seconds: 1));

      expect(executions, 0);
      expect(contract.service.pendingTicketCount, 0);
      expect(contract.audit.records.last.stage, ActionAuditStage.result);
      expect(contract.audit.records.last.outcome, ActionAuditOutcome.cancelled);
      expect(contract.audit.records.last.code, 'realtime_claim_unavailable');
      await service.disconnect();
    },
  );

  test('authority fenced during enforce claim cannot reach effect', () async {
    final contract = await _installRealtimeContract(readOnly: true);
    final authority = await _authorityHarness();
    final cursor = _MemoryCursorStore()
      ..onClaim = (_) => authority.coordinator.fence();
    final terminal = Completer<Object>();
    var executions = 0;
    final service = RealtimeActionStreamService(
      baseUri: _baseUri,
      httpClient: _StaticSseClient(
        _runtimeEvent(sequence: 1, eventId: 'event_stale_claim_1'),
      ),
      cursorStore: cursor,
      actionContract: contract.service,
      productionActionCatalog: contract.catalog,
      requirePinnedActionContract: true,
      reconnectDelay: (_) => const Duration(minutes: 1),
      executeEnvelope: (_) => executions += 1,
      onTerminalFailure: (error, _) {
        if (!terminal.isCompleted) terminal.complete(error);
      },
    );

    await service.connect(_fencedSession(), authority: authority.authority);
    await terminal.future.timeout(const Duration(seconds: 1));

    expect(executions, 0);
    expect(cursor.value, 1);
    expect(contract.service.pendingTicketCount, 0);
    expect(contract.audit.records.last.code, 'realtime_claim_unavailable');
    await service.disconnect();
  });

  test(
    'a claimed event is not replayed after effect failure and service rebuild',
    () async {
      final contract = await _installRealtimeContract(readOnly: true);
      final authority = await _authorityHarness();
      final cursor = _MemoryCursorStore();
      final firstTerminal = Completer<Object>();
      final executions = <String>[];
      final first = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: _StaticSseClient(
          _runtimeEvent(
            sequence: 1,
            eventId: 'event_before_effect_failure',
            mood: 'first',
          ),
        ),
        cursorStore: cursor,
        actionContract: contract.service,
        productionActionCatalog: contract.catalog,
        requirePinnedActionContract: true,
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (envelope) {
          executions.add(envelope.actions.single['mood'].toString());
          throw StateError('synthetic effect failure');
        },
        onTerminalFailure: (error, _) {
          if (!firstTerminal.isCompleted) firstTerminal.complete(error);
        },
      );

      await first.connect(_fencedSession(), authority: authority.authority);
      await firstTerminal.future.timeout(const Duration(seconds: 1));
      expect(executions, <String>['first']);
      expect(cursor.value, 1);
      await first.disconnect();

      final nextExecuted = Completer<void>();
      final replayClient = _StaticSseClient(
        _runtimeEvent(
              sequence: 1,
              eventId: 'event_after_effect_failure',
              mood: 'duplicate',
            ) +
            _runtimeEvent(
              sequence: 2,
              eventId: 'event_after_effect_failure_2',
              mood: 'next',
            ),
      );
      final replay = RealtimeActionStreamService(
        baseUri: _baseUri,
        httpClient: replayClient,
        cursorStore: cursor,
        actionContract: contract.service,
        productionActionCatalog: contract.catalog,
        requirePinnedActionContract: true,
        reconnectDelay: (_) => const Duration(minutes: 1),
        executeEnvelope: (envelope) {
          final mood = envelope.actions.single['mood'].toString();
          executions.add(mood);
          if (mood == 'next' && !nextExecuted.isCompleted) {
            nextExecuted.complete();
          }
        },
      );

      await replay.connect(_fencedSession(), authority: authority.authority);
      await nextExecuted.future.timeout(const Duration(seconds: 1));
      expect(executions, <String>['first', 'next']);
      expect(cursor.value, 2);
      expect(cursor.claims, <int>[1, 2]);
      expect(_header(replayClient.requests.single, 'last-event-id'), '1');
      await replay.disconnect();
    },
  );
}

final Uri _baseUri = Uri.parse('${MaasoEnvironment.test.baseUrl}/');
const String _sessionId = 'ms_session_1';

RealtimeSession _legacySession() => RealtimeSession(
  sessionId: 'ms_legacy_1',
  locale: 'en',
  rtcAppId: 'volc-app-id',
  roomId: 'room_legacy_1',
  userId: 'user_legacy_1',
  agentUserId: 'agent_legacy_1',
  taskId: 'task_legacy_1',
  rtcToken: 'rtc-token',
  actionStreamUri: _baseUri.resolve(
    '/v1/realtime/sessions/ms_legacy_1/actions',
  ),
  createdAt: DateTime.utc(2026, 8, 21, 12),
);

RealtimeSession _fencedSession({Uri? actionStreamUri}) => RealtimeSession(
  sessionId: _sessionId,
  locale: 'en',
  rtcAppId: 'volc-app-id',
  roomId: 'room_session_1',
  userId: 'user_session_1',
  agentUserId: 'agent_session_1',
  taskId: 'task_session_1',
  rtcToken: 'rtc-token',
  actionStreamUri:
      actionStreamUri ??
      _baseUri.resolve('/v1/realtime/sessions/$_sessionId/actions'),
  createdAt: DateTime.utc(2026, 8, 21, 12),
  leaseEpoch: 1,
  rtcGeneration: 3,
);

String _runtimeEvent({
  required int sequence,
  required String eventId,
  int? frameSequence,
  int leaseEpoch = 1,
  int rtcGeneration = 3,
  String sessionId = _sessionId,
  String? subjectId,
  String mood = 'thinking',
  Map<String, Object?> wrapperExtras = const <String, Object?>{},
  Map<String, Object?> payloadExtras = const <String, Object?>{},
}) {
  final payload = <String, Object?>{
    'sessionId': sessionId,
    'rtcGeneration': rtcGeneration,
    'envelope': <String, Object?>{
      'reply': '',
      'actions': <Object?>[
        <String, Object?>{'type': 'avatar.react', 'mood': mood},
      ],
    },
    ...payloadExtras,
  };
  final wrapper = <String, Object?>{
    'eventId': eventId,
    'sequence': sequence,
    'type': 'realtime.action',
    'leaseEpoch': leaseEpoch,
    'subjectType': 'realtime_session',
    'subjectId': subjectId ?? sessionId,
    'payload': payload,
    'createdAt': '2026-08-21T12:00:00Z',
    ...wrapperExtras,
  };
  return 'id: ${frameSequence ?? sequence}\n'
      'event: realtime.action\n'
      'data: ${jsonEncode(wrapper)}\n\n';
}

String? _header(http.BaseRequest request, String name) {
  final normalized = name.toLowerCase();
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == normalized) return entry.value;
  }
  return null;
}

Future<
  ({
    ActionContractV2Service service,
    ProductionActionDefinitionCatalog catalog,
    _RealtimeAuditSink audit,
  })
>
_installRealtimeContract({
  required bool readOnly,
  FeatureRolloutMode mode = FeatureRolloutMode.enforce,
}) async {
  final now = DateTime.utc(2026, 8, 30, 8);
  final flags = await MaasoFeatureFlagService(
    store: _RealtimeFlagStore(),
    compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
      MaasoFeatureFlag.actionContractV2: FeatureRolloutMode.enforce,
    },
    clock: () => now,
  ).init();
  await flags.assign(
    flag: MaasoFeatureFlag.actionContractV2,
    mode: mode,
    revision: 1,
    expiresAt: now.add(const Duration(hours: 1)),
  );
  final catalog = ProductionActionDefinitionCatalog.intrinsics()
    ..register(
      ProductionActionDefinition(
        definition: ActionDefinition(
          id: 'avatar.react',
          inputSchema: const <String, dynamic>{
            'type': 'object',
            'properties': <String, Object?>{
              'mood': <String, Object?>{'type': 'string'},
            },
            'required': <String>['mood'],
            'additionalProperties': false,
          },
          outputSchema: const <String, dynamic>{
            'type': 'object',
            'properties': <String, Object?>{},
            'additionalProperties': false,
          },
          scopes: const <AgentActionScope>{AgentActionScope.chat},
          risk: readOnly ? ActionRisk.readOnly : ActionRisk.localMutation,
          consequencePolicy: ActionConsequencePolicy.reversible,
          targetResolver: (_) => 'avatar:presentation',
          handler: (_) => throw StateError('metadata handler must not run'),
        ),
        channels: const <ActionContractChannel>{ActionContractChannel.realtime},
        enforcementEligibility: readOnly
            ? ActionEnforcementEligibility.readOnly
            : ActionEnforcementEligibility.reversibleLocal,
      ),
    );
  final audit = _RealtimeAuditSink();
  final service = ActionContractV2Service(
    featureFlags: flags,
    catalog: catalog,
    audit: audit,
    accountScope: 'account-a',
    accountGeneration: 7,
    mountIsCurrent: () => true,
  );
  appServices.put<ProductionActionDefinitionCatalog>(catalog);
  appServices.put<ActionContractV2Service>(service);
  return (service: service, catalog: catalog, audit: audit);
}

final class _RealtimeAuditSink implements ActionContractV2AuditSink {
  final List<ActionContractAuditRecord> records = <ActionContractAuditRecord>[];

  @override
  String record(ActionContractAuditRecord record) {
    records.add(record);
    return 'audit:${record.definition.id}';
  }
}

final class _RealtimeFlagStore implements MaasoFeatureFlagAssignmentStore {
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      rows.map(Map<String, Object?>.from).toList(growable: false);

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    rows.removeWhere((row) => row['flag'] == assignment.flag.key);
    rows.add(assignment.toJson());
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for realtime test condition');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

final class _MemoryCursorStore implements RealtimeActionCursorStore {
  _MemoryCursorStore({this.initial = 0}) : value = initial;

  final int initial;
  int value;
  final List<RealtimeActionCursorKey> reads = <RealtimeActionCursorKey>[];
  final List<int> claims = <int>[];
  void Function(int sequence)? onClaim;

  @override
  Future<int> read(RealtimeActionCursorKey key) async {
    reads.add(key);
    return value;
  }

  @override
  Future<bool> claim(RealtimeActionCursorKey key, int sequence) async {
    if (sequence <= value) return false;
    claims.add(sequence);
    value = sequence;
    onClaim?.call(sequence);
    return true;
  }

  @override
  Future<void> commit(RealtimeActionCursorKey key, int sequence) async {
    await claim(key, sequence);
  }
}

final class _FailingClaimCursorStore implements RealtimeActionCursorStore {
  @override
  Future<int> read(RealtimeActionCursorKey key) async => 0;

  @override
  Future<bool> claim(RealtimeActionCursorKey key, int sequence) async {
    throw StateError('synthetic durable claim failure');
  }

  @override
  Future<void> commit(RealtimeActionCursorKey key, int sequence) async {
    throw StateError('legacy commit must not run');
  }
}

final class _StaticSseClient extends http.BaseClient {
  _StaticSseClient(this.body);

  final String body;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(body)]),
      200,
      headers: const <String, String>{'content-type': 'text/event-stream'},
      request: request,
    );
  }
}

final class _StatusClient extends http.BaseClient {
  _StatusClient({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      statusCode,
      headers: headers,
      request: request,
    );
  }
}

final class _ReconnectSseClient extends http.BaseClient {
  _ReconnectSseClient({required this.firstBody, required this.secondBody});

  final String firstBody;
  final String secondBody;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final StreamController<List<int>> _second = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (requests.length == 1) {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(firstBody)),
        200,
        headers: const <String, String>{'content-type': 'text/event-stream'},
        request: request,
      );
    }
    if (requests.length == 2) {
      scheduleMicrotask(() => _second.add(utf8.encode(secondBody)));
      return http.StreamedResponse(
        _second.stream,
        200,
        headers: const <String, String>{'content-type': 'text/event-stream'},
        request: request,
      );
    }
    throw StateError('unexpected third realtime stream request');
  }

  @override
  Future<void> close() => _second.close();
}

final class _UnauthorizedReconnectSseClient extends http.BaseClient {
  _UnauthorizedReconnectSseClient({
    required this.initialBody,
    required this.resumedBody,
  });

  final String initialBody;
  final String resumedBody;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final StreamController<List<int>> _resumed = StreamController<List<int>>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    switch (requests.length) {
      case 1:
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(initialBody)),
          200,
          headers: const <String, String>{'content-type': 'text/event-stream'},
          request: request,
        );
      case 2:
        return http.StreamedResponse(
          Stream<List<int>>.value(
            utf8.encode('{"code":"UNAUTHORIZED","message":"expired"}'),
          ),
          401,
          headers: const <String, String>{'content-type': 'application/json'},
          request: request,
        );
      case 3:
        scheduleMicrotask(() => _resumed.add(utf8.encode(resumedBody)));
        return http.StreamedResponse(
          _resumed.stream,
          200,
          headers: const <String, String>{'content-type': 'text/event-stream'},
          request: request,
        );
      default:
        throw StateError('401 reconnect retried more than once');
    }
  }

  @override
  Future<void> close() => _resumed.close();
}

final class _AuthorityHarness {
  const _AuthorityHarness({
    required this.coordinator,
    required this.authority,
    required this.holderProof,
  });

  final AccountDeviceLeaseCoordinator coordinator;
  final AccountDeviceLeaseRequestAuthority authority;
  final String holderProof;
}

Future<_AuthorityHarness> _authorityHarness() async {
  final identity = await AppInstallationIdentityService(
    store: _MemoryInstallationIdentityStore(),
    randomBytes: (length) => List<int>.filled(length, 0x11),
  ).init();
  final gateway = _AuthorityGateway();
  final coordinator = AccountDeviceLeaseCoordinator(
    identity: identity,
    gateway: gateway,
    randomBytes: (length) => List<int>.filled(length, 0x22),
    monotonicNow: () => Duration.zero,
    wallClock: () => _authorityNow,
  );
  await coordinator.acquire(
    environment: MaasoEnvironment.test,
    accountUuid: 'account-1',
    deviceLabel: 'Test device',
    platform: 'macos',
    appVersion: '1.0.0',
  );
  return _AuthorityHarness(
    coordinator: coordinator,
    authority: coordinator.requireCurrentRequestAuthority(),
    holderProof: gateway.holderProof!,
  );
}

final DateTime _authorityNow = DateTime.utc(2026, 8, 21, 12);

final class _MemoryInstallationIdentityStore
    implements AppInstallationIdentityStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<bool> write(String key, String value) async {
    _values[key] = value;
    return true;
  }
}

final class _AuthorityGateway implements AccountDeviceLeaseGateway {
  AccountDevicePresenceReceipt? _presence;
  AccountDeviceLeaseReceipt? _lease;
  String? holderProof;

  @override
  Future<AccountDevicePresenceOperationResult> openPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    required String requestId,
  }) async {
    final presence = _presence ??= AccountDevicePresenceReceipt(
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: 'presence_session_1',
      generation: 1,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
      openedAt: _authorityNow,
      lastSeenAt: _authorityNow,
      expiresAt: _authorityNow.add(const Duration(minutes: 1)),
      remainingTtl: const Duration(minutes: 1),
      renewAfter: const Duration(seconds: 20),
    );
    return AccountDevicePresenceOperationResult(
      presence: presence,
      replayed: false,
    );
  }

  @override
  Future<AccountDeviceLeaseOperationResult> acquireLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String presenceSessionId,
    required String holderProof,
    required String requestId,
  }) async {
    this.holderProof = holderProof;
    final holder = AccountDeviceLeaseHolder(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      deviceLabel: 'Test device',
      platform: 'macos',
      lastSeenAt: _authorityNow,
    );
    final lease = _lease ??= AccountDeviceLeaseReceipt(
      agentId: agentId,
      leaseId: 'lease_session_1',
      epoch: 1,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      expiresAt: _authorityNow.add(const Duration(seconds: 45)),
      remainingTtl: const Duration(seconds: 45),
      renewAfter: const Duration(seconds: 15),
      holder: holder,
    );
    return AccountDeviceLeaseOperationResult(lease: lease, replayed: false);
  }

  @override
  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async =>
      AccountDevicePresenceOperationResult(presence: presence, replayed: false);

  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async => AccountDeviceLeaseOperationResult(lease: lease, replayed: false);

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    _lease = null;
    return AccountDeviceLeaseReleaseResult(
      released: true,
      stale: false,
      epoch: lease.epoch + 1,
    );
  }

  @override
  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    _presence = null;
    return AccountDevicePresenceCloseResult(
      closed: true,
      stale: false,
      generation: presence.generation,
    );
  }

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async => AccountDeviceLeaseSnapshot(
    state: _lease == null
        ? AccountDeviceLeaseRemoteState.inactive
        : AccountDeviceLeaseRemoteState.active,
    lease: _lease,
  );
}
