import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace_persistence.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_source_fixture.dart';

const _instruction = 'Create the requested scoring game with every screen.';
const _transient = LLMResponseIntegrityException.publicFailure(
  'modelUnavailable',
  retryable: true,
);
const _scope = 'account-a/test/game';
const _task = 'stable-task-lineage';

GeneratedGameArtifact _producer(
  LLMClient client, {
  SourceWorkspaceSnapshot? initial,
  FutureOr<void> Function(SourceWorkspaceSnapshot)? onDraft,
  bool Function()? shouldCancel,
  Future<void> Function(Duration)? retryDelay,
  GeneratedTaskCheckpointObserver? onCheckpoint,
}) => GeneratedGameArtifact(
  client: client,
  instruction: _instruction,
  surfaceId: 'host-owned-retry-game',
  zh: false,
  initialDraft: initial,
  onDraft: onDraft,
  shouldCancel: shouldCancel,
  onCheckpoint: onCheckpoint,
  retryDelay: retryDelay ?? (_) async {},
);

String _messages(List<Message> messages) =>
    jsonEncode(messages.map((message) => message.toJson()).toList());

SourceWorkspaceSnapshot _copy(SourceWorkspaceSnapshot value) =>
    SourceWorkspaceSnapshot.fromJson(jsonDecode(jsonEncode(value.toJson())));

Map _surface(AgentActionEnvelope result) =>
    result.actions.single['surface'] as Map;

String _read(String id, {int start = 0, int bytes = 64}) => jsonEncode({
  'read': {'fileId': id, 'startByte': start, 'maxBytes': bytes},
});

String _patch(String before, String after, {String id = 'game.js'}) =>
    jsonEncode({
      'fileId': id,
      'baseHash': sourceWorkspaceDigest(before),
      'edits': [
        {'oldText': before, 'newText': after},
      ],
    });

Future<DBService> _database(String path) =>
    DBService().init(factory: databaseFactoryMemory, path: path);

Future<SourceWorkspaceSnapshot?> _load(DBService db, {String scope = _scope}) =>
    SourceWorkspacePersistence(db).read(
      scopeKey: scope,
      jobId: _task,
      requirementSha256: sourceWorkspaceDigest(_instruction),
      requireCurrent: () {},
    );

Future<void> _save(
  DBService db,
  SourceWorkspaceSnapshot snapshot,
  int attempt,
) => SourceWorkspacePersistence(db).write(
  scopeKey: _scope,
  jobId: _task,
  attempt: attempt,
  snapshot: snapshot,
  requireCurrent: () {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'five automatic retries keep the failed logical request unchanged',
    () async {
      final client = SourceFixtureClient([
        for (var i = 0; i < 5; i++) _transient,
        ...sourceFixtureResponses(),
      ]);
      final delays = <Duration>[];
      final drafts = <SourceWorkspaceSnapshot>[];
      final checkpoints = <GeneratedTaskCheckpoint>[];
      final result = await _producer(
        client,
        onDraft: drafts.add,
        retryDelay: (delay) async => delays.add(delay),
        onCheckpoint: (checkpoint, {publicSummary}) =>
            checkpoints.add(checkpoint),
      ).generate();

      expect(client.requests, hasLength(9));
      expect(delays, hasLength(5));
      expect(
        checkpoints.where(
          (value) => value == GeneratedTaskCheckpoint.modelRetrying,
        ),
        hasLength(5),
      );
      expect(delays.every((delay) => delay > Duration.zero), isTrue);
      expect(
        client.requests.take(6).map(_messages).toSet(),
        hasLength(1),
        reason:
            'A transient failure must not rerun planning or change its context.',
      );
      expect(_surface(result)['js'], sourceJs);
      expect(drafts.last.files.every((file) => file.complete), isTrue);
      expect(drafts.last.toJson()['executionCheckpoint'], isNull);
    },
  );

  test(
    'six failed dispatches retain the exact unfinished prefix and request',
    () async {
      const prefix = 'let score=';
      final client = SourceFixtureClient([
        jsonEncode(sourcePlan),
        jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        jsonEncode(boundSourceChunk('game.js', prefix, done: false)),
        for (var i = 0; i < 6; i++) _transient,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final delays = <Duration>[];
      await expectLater(
        _producer(
          client,
          onDraft: drafts.add,
          retryDelay: (delay) async => delays.add(delay),
        ).generate(),
        throwsA(same(_transient)),
      );

      expect(client.requests, hasLength(10));
      expect(delays, hasLength(5));
      expect(client.requests.skip(4).map(_messages).toSet(), hasLength(1));
      expect(drafts.last.files.where((file) => file.complete), hasLength(2));
      expect(drafts.last.files.last.source, prefix);
      expect(drafts.last.toJson()['executionCheckpoint'], isNotNull);

      final continuation = SourceFixtureClient([
        jsonEncode(
          boundSourceChunk(
            'game.js',
            sourceJs.substring(prefix.length),
            prefix: prefix,
          ),
        ),
      ]);
      final resumed = await _producer(
        continuation,
        initial: _copy(drafts.last),
      ).generate();
      expect(continuation.requests, hasLength(1));
      expect(
        _messages(continuation.requests.single),
        _messages(client.requests.last),
      );
      expect(_surface(resumed)['js'], sourceJs);
    },
  );

  test(
    'a source read survives closing and reopening the database without another lookup',
    () async {
      var db = await _database('generation-retry-read.db');
      addTearDown(() => db.close());
      final client = SourceFixtureClient([
        jsonEncode(sourcePlan),
        jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        _read('screen.html'),
        for (var i = 0; i < 6; i++) _transient,
      ]);
      await expectLater(
        _producer(
          client,
          onDraft: (snapshot) => _save(db, snapshot, 1),
        ).generate(),
        throwsA(same(_transient)),
      );
      final failedRequest = _messages(client.requests.last);
      expect(failedRequest, contains('readResult'));
      expect(client.requests, hasLength(10));
      await db.close();
      db = await _database('generation-retry-read.db');
      final draft = await _load(db);
      expect(draft, isNotNull);
      expect(await _load(db, scope: 'account-b/test/game'), isNull);

      final continuation = SourceFixtureClient([
        jsonEncode(boundSourceChunk('game.js', sourceJs)),
      ]);
      final result = await _producer(
        continuation,
        initial: draft,
        onDraft: (snapshot) => _save(db, snapshot, 2),
      ).generate();
      expect(continuation.requests, hasLength(1));
      expect(_messages(continuation.requests.single), failedRequest);
      expect(_surface(result)['html'], sourceHtml);
      expect(_surface(result)['css'], sourceCss);
      expect(_surface(result)['js'], sourceJs);
      expect((await _load(db))!.toJson()['executionCheckpoint'], isNull);
      expect(await db.getAllWidgets(), isEmpty);
    },
  );

  test(
    'a restarted repair keeps its exact edit request and inspected source',
    () async {
      var db = await _database('generation-retry-repair.db');
      addTearDown(() => db.close());
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        _read('screen.html'),
        for (var i = 0; i < 6; i++) _transient,
      ]);
      final producer = _producer(
        client,
        onDraft: (snapshot) => _save(db, snapshot, 1),
      );
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(same(_transient)),
      );
      final pending = _messages(client.requests.last);
      expect(pending, contains('smallest complete set of exact edits'));
      expect(pending, contains('recentReadResults'));
      await db.close();
      db = await _database('generation-retry-repair.db');
      final draft = await _load(db);
      const fixed = '$sourceJs\nconst recovered=true;';
      final continuation = SourceFixtureClient([_patch(sourceJs, fixed)]);
      final result = await _producer(
        continuation,
        initial: draft,
        onDraft: (snapshot) => _save(db, snapshot, 2),
      ).generate();
      expect(continuation.requests, hasLength(1));
      expect(_messages(continuation.requests.single), pending);
      expect(_surface(result)['js'], fixed);
      expect((await _load(db))!.toJson()['executionCheckpoint'], isNull);
    },
  );

  test(
    'a restarted repair skips completed files and finishes its remaining queue',
    () async {
      const helper = 'const helperReady=true;';
      const tail = 'const tailReady=true;';
      final plan = {
        ...sourcePlan,
        'files': [
          ...(sourcePlan['files'] as List).take(2),
          {
            'id': 'helper.js',
            'kind': 'js',
            'purpose': 'Shared helper',
            'dependsOn': ['screen.html'],
          },
          {
            ...(sourcePlan['files'] as List).last as Map,
            'dependsOn': ['helper.js'],
          },
          {
            'id': 'tail.js',
            'kind': 'js',
            'purpose': 'End-of-game detail',
            'dependsOn': ['game.js'],
          },
        ],
      };
      String unchanged(String id, String source) => jsonEncode({
        'fileId': id,
        'baseHash': sourceWorkspaceDigest(source),
        'edits': [],
      });
      final client = SourceFixtureClient([
        jsonEncode(plan),
        jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        jsonEncode(boundSourceChunk('helper.js', helper)),
        jsonEncode(boundSourceChunk('game.js', sourceJs)),
        jsonEncode(boundSourceChunk('tail.js', tail)),
        unchanged('helper.js', helper),
        _read('screen.html'),
        for (var i = 0; i < 6; i++) _transient,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      final producer = _producer(client, onDraft: drafts.add);
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(same(_transient)),
      );
      expect(client.requests, hasLength(14));
      final pending = _messages(client.requests.last);
      const fixed = '$sourceJs\nconst queueRecovered=true;';
      final continuation = SourceFixtureClient([
        _patch(sourceJs, fixed),
        unchanged('tail.js', tail),
      ]);
      final result = await _producer(
        continuation,
        initial: _copy(drafts.last),
      ).generate();

      expect(continuation.requests, hasLength(2));
      expect(_messages(continuation.requests.first), pending);
      expect(
        continuation.requests.last.first.content,
        contains('File binding: {"fileId":"tail.js"'),
      );
      expect(
        continuation.requests.any(
          (request) => request.first.content.contains(
            'File binding: {"fileId":"helper.js"',
          ),
        ),
        isFalse,
      );
      expect(_surface(result)['js'], '$helper\n;\n$fixed\n;\n$tail');
    },
  );

  test(
    'a process stop at the repair to rewrite checkpoint resumes source writing',
    () async {
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        jsonEncode(boundSourceChunk('game.js', 'let score=', done: false)),
      ]);
      SourceWorkspaceSnapshot? durable;
      const stopped = GeneratedTaskFailure(
        GeneratedTaskFailureCode.interrupted,
      );
      final producer = _producer(
        client,
        onDraft: (snapshot) {
          durable = _copy(snapshot);
          if (snapshot.files.any(
            (file) =>
                file.plan.id == 'game.js' &&
                file.source.isEmpty &&
                file.previousSource == sourceJs,
          )) {
            // Model a process ending after this transaction was durable but
            // before the delivered rewrite chunk reached its source commit.
            throw stopped;
          }
        },
      );
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(same(stopped)),
      );
      expect(client.requests, hasLength(5));
      expect(durable!.executionCheckpoint!.operation, 'write');
      expect(durable!.files.last.source, isEmpty);
      expect(durable!.files.last.previousSource, sourceJs);
      final fixed = sourceJs.replaceFirst('let score=0;', 'let score=1;');
      final continuation = SourceFixtureClient([
        jsonEncode(boundSourceChunk('game.js', fixed)),
      ]);
      final result = await _producer(continuation, initial: durable).generate();

      expect(continuation.requests, hasLength(1));
      final prompt = continuation.requests.single.first.content;
      expect(prompt, contains('current byte cursor'));
      expect(prompt, contains('"baseCursor":0'));
      expect(prompt, isNot(contains('smallest complete set of exact edits')));
      expect(_surface(result)['js'], fixed);
      expect(_surface(result)['html'], sourceHtml);
      expect(_surface(result)['css'], sourceCss);
    },
  );

  test(
    'truncated repair fallback retains writing mode and the remaining repair queue',
    () async {
      const tail = 'const tailReady=true;';
      final plan = {
        ...sourcePlan,
        'files': [
          ...(sourcePlan['files'] as List),
          {
            'id': 'tail.js',
            'kind': 'js',
            'purpose': 'Retained game detail',
            'dependsOn': ['game.js'],
          },
        ],
      };
      final fixed = sourceJs.replaceFirst('let score=0;', 'let score=1;');
      final truncated = ProjectSourceResponse(
        visibleText: _patch(sourceJs, fixed),
        termination: ProjectSourceTermination.knownLength,
      );
      final client = SourceFixtureClient([
        jsonEncode(plan),
        jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        jsonEncode(boundSourceChunk('game.js', sourceJs)),
        jsonEncode(boundSourceChunk('tail.js', tail)),
        truncated,
        truncated,
      ]);
      SourceWorkspaceSnapshot? durable;
      const stopped = GeneratedTaskFailure(
        GeneratedTaskFailureCode.interrupted,
      );
      final producer = _producer(
        client,
        onDraft: (snapshot) {
          durable = _copy(snapshot);
          if (snapshot.files.any(
            (file) =>
                file.plan.id == 'game.js' &&
                file.source.isEmpty &&
                file.previousSource == sourceJs,
          )) {
            throw stopped;
          }
        },
      );
      final original = await producer.generate();
      await expectLater(
        producer.repair(
          original,
          'surface worker first frame rejected: runtime_failed',
        ),
        throwsA(same(stopped)),
      );
      expect(client.requests, hasLength(7));
      expect(durable!.executionCheckpoint, isNotNull);
      expect(durable!.executionCheckpoint!.operation, 'write');
      expect(
        durable!.files
            .singleWhere((file) => file.plan.id == 'game.js')
            .previousSource,
        sourceJs,
      );
      final continuation = SourceFixtureClient([
        jsonEncode(boundSourceChunk('game.js', fixed)),
        jsonEncode({
          'fileId': 'tail.js',
          'baseHash': sourceWorkspaceDigest(tail),
          'edits': [],
        }),
      ]);
      final result = await _producer(continuation, initial: durable).generate();

      expect(continuation.requests, hasLength(2));
      expect(
        continuation.requests.first.first.content,
        contains('current byte cursor'),
      );
      expect(
        continuation.requests.first.first.content,
        contains('"baseCursor":0'),
      );
      expect(
        continuation.requests.last.first.content,
        contains('File binding: {"fileId":"tail.js"'),
      );
      expect(_surface(result)['js'], '$fixed\n;\n$tail');
      expect(_surface(result)['html'], sourceHtml);
      expect(_surface(result)['css'], sourceCss);
    },
  );

  test(
    'checkpoint persistence failure stops before the first model dispatch',
    () async {
      final client = SourceFixtureClient(sourceFixtureResponses());
      final storageFailure = StateError('synthetic private storage detail');
      await expectLater(
        _producer(client, onDraft: (_) => throw storageFailure).generate(),
        throwsA(anyOf(same(storageFailure), isA<GeneratedTaskFailure>())),
      );
      expect(client.requests, isEmpty);
    },
  );

  test(
    'an uncommitted source append is replayed once from its old cursor',
    () async {
      final client = SourceFixtureClient(sourceFixtureResponses());
      SourceWorkspaceSnapshot? durable;
      final storageFailure = StateError(
        'synthetic append transaction rollback',
      );
      await expectLater(
        _producer(
          client,
          onDraft: (snapshot) {
            if (snapshot.files.any(
              (file) => file.plan.id == 'screen.html' && file.complete,
            )) {
              throw storageFailure;
            }
            durable = _copy(snapshot);
          },
        ).generate(),
        throwsA(anyOf(same(storageFailure), isA<GeneratedTaskFailure>())),
      );
      expect(client.requests, hasLength(2));
      expect(durable, isNotNull);
      expect(durable!.files.every((file) => file.source.isEmpty), isTrue);
      final continuation = SourceFixtureClient(
        sourceFixtureResponses().skip(1).toList(),
      );
      final result = await _producer(continuation, initial: durable).generate();
      expect(continuation.requests, hasLength(3));
      expect(
        _messages(continuation.requests.first),
        _messages(client.requests.last),
      );
      expect(_surface(result)['html'], sourceHtml);
    },
  );

  test(
    'cancellation during retry backoff never dispatches a second request',
    () async {
      final client = SourceFixtureClient([
        _transient,
        ...sourceFixtureResponses(),
      ]);
      var cancelled = false;
      final drafts = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(
          client,
          shouldCancel: () => cancelled,
          onDraft: drafts.add,
          retryDelay: (_) async => cancelled = true,
        ).generate(),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
      expect(drafts.last.toJson()['executionCheckpoint'], isNotNull);
    },
  );

  test(
    'production retry waiting is interruptible before the next backoff expires',
    () async {
      final client = SourceFixtureClient([_transient]);
      var cancelled = false;
      Timer? cancelTimer;
      addTearDown(() => cancelTimer?.cancel());
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: _instruction,
        surfaceId: 'host-owned-retry-game',
        zh: false,
        shouldCancel: () => cancelled,
        onCheckpoint: (checkpoint, {publicSummary}) {
          if (checkpoint == GeneratedTaskCheckpoint.modelRetrying) {
            cancelTimer = Timer(const Duration(milliseconds: 10), () {
              cancelled = true;
            });
          }
        },
      );
      await expectLater(
        producer.generate().timeout(const Duration(seconds: 1)),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'code',
            GeneratedTaskFailureCode.interrupted,
          ),
        ),
      );
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'revoked permission during backoff blocks another dispatched model request',
    () async {
      final inner = SourceFixtureClient([
        _transient,
        ...sourceFixtureResponses(),
      ]);
      var permitted = true;
      final denied = StateError('synthetic revoked account permission');
      final client = privacyGuardedLLMClient(inner, () async {
        if (!permitted) throw denied;
      });
      await expectLater(
        _producer(
          client,
          retryDelay: (_) async {
            permitted = false;
          },
        ).generate(),
        throwsA(same(denied)),
      );
      expect(inner.requests, hasLength(1));
      expect(inner.ordinaryCalls, 0);
    },
  );

  test(
    'checkpoint request corruption is rejected before any recovery dispatch',
    () async {
      final client = SourceFixtureClient([
        for (var i = 0; i < 6; i++) _transient,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, onDraft: drafts.add).generate(),
        throwsA(same(_transient)),
      );
      final json = jsonDecode(jsonEncode(drafts.last.toJson())) as Map;
      final checkpoint = json['executionCheckpoint'] as Map;
      checkpoint['systemPrompt'] = '${checkpoint['systemPrompt']} corrupted';
      final continuation = SourceFixtureClient(sourceFixtureResponses());
      await expectLater(
        Future<void>(() async {
          final restored = SourceWorkspaceSnapshot.fromJson(json);
          await _producer(continuation, initial: restored).generate();
        }),
        throwsA(isA<FormatException>()),
      );
      expect(continuation.requests, isEmpty);
    },
  );

  test(
    'a changed workspace rejects a frozen request instead of replaying stale context',
    () async {
      final client = SourceFixtureClient([
        jsonEncode(sourcePlan),
        jsonEncode(boundSourceChunk('screen.html', sourceHtml)),
        for (var i = 0; i < 6; i++) _transient,
      ]);
      final drafts = <SourceWorkspaceSnapshot>[];
      await expectLater(
        _producer(client, onDraft: drafts.add).generate(),
        throwsA(same(_transient)),
      );
      final json =
          jsonDecode(jsonEncode(drafts.last.toJson())) as Map<String, dynamic>;
      final files = json['files'] as List;
      (files.first as Map)['source'] = '$sourceHtml<!-- externally changed -->';
      final continuation = SourceFixtureClient(sourceFixtureResponses());
      await expectLater(
        Future<void>(() async {
          final modified = SourceWorkspaceSnapshot.fromJson(json);
          await _producer(continuation, initial: modified).generate();
        }),
        throwsA(
          anyOf(
            isA<SourceWorkspaceProtocolException>(),
            isA<GeneratedTaskFailure>(),
          ),
        ),
      );
      expect(continuation.requests, isEmpty);
    },
  );

  test(
    'schema one drafts without execution state keep source cursor recovery',
    () async {
      const prefix = 'let score=';
      final blueprint = SourceBlueprint.fromJson(sourcePlan);
      final legacy = SourceWorkspaceSnapshot(
        requirementSha256: sourceWorkspaceDigest(_instruction),
        experienceType: 'game',
        blueprint: blueprint,
        blueprintComplete: true,
        files: [
          SourceFileSnapshot(
            plan: blueprint.files[0],
            source: sourceHtml,
            complete: true,
          ),
          SourceFileSnapshot(
            plan: blueprint.files[1],
            source: sourceCss,
            complete: true,
          ),
          SourceFileSnapshot(plan: blueprint.files[2], source: prefix),
        ],
        activeFileId: 'game.js',
      ).toJson()..remove('executionCheckpoint');
      legacy['schemaVersion'] = 1;
      final client = SourceFixtureClient([
        jsonEncode(
          boundSourceChunk(
            'game.js',
            sourceJs.substring(prefix.length),
            prefix: prefix,
          ),
        ),
      ]);
      final result = await _producer(
        client,
        initial: SourceWorkspaceSnapshot.fromJson(legacy),
      ).generate();
      expect(client.requests, hasLength(1));
      expect(_surface(result)['js'], sourceJs);
    },
  );

  test(
    'partial failed HTTP output is discarded while retry uses a fresh request ID',
    () async {
      final requests = <Map<String, dynamic>>[];
      final responses = [
        _success(sourcePlan),
        _success(boundSourceChunk('screen.html', sourceHtml)),
        _success(boundSourceChunk('skin.css', sourceCss)),
        http.Response(
          '${_delta('PRIVATE_FAILED_PARTIAL_NOT_SOURCE')}'
          'event: completion\ndata: {"status":"incomplete","finishReason":""}\n\n'
          'event: error\ndata: {"code":"MODEL_STREAM_INCOMPLETE","retryable":true}\n\n',
          200,
          headers: _headers,
        ),
        _success(boundSourceChunk('game.js', sourceJs)),
      ];
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test'),
        model: 'synthetic',
        accessTokenProvider: () async => 'synthetic',
        httpClient: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return responses.removeAt(0);
        }),
      );
      final drafts = <SourceWorkspaceSnapshot>[];
      final result = await _producer(client, onDraft: drafts.add).generate();
      expect(requests, hasLength(5));
      expect(requests[4]['messages'], requests[3]['messages']);
      expect(
        requests.map((request) => request['turnId']).toSet(),
        hasLength(5),
      );
      expect(_surface(result)['js'], sourceJs);
      expect(
        jsonEncode(drafts.map((draft) => draft.toJson()).toList()),
        isNot(contains('PRIVATE_FAILED_PARTIAL_NOT_SOURCE')),
      );
    },
  );

  for (final code in [
    'modelAuthentication',
    'modelQuotaExceeded',
    'modelContextLimit',
    'modelSafetyBlocked',
    'responseInvalid',
  ]) {
    test('nonretryable $code does not trigger transport replay', () async {
      final error = LLMResponseIntegrityException.publicFailure(code);
      final client = SourceFixtureClient([error]);
      final delays = <Duration>[];
      await expectLater(
        _producer(
          client,
          retryDelay: (delay) async => delays.add(delay),
        ).generate(),
        throwsA(same(error)),
      );
      expect(client.requests, hasLength(1));
      expect(delays, isEmpty);
    });
  }
}

const _headers = {
  'content-type': 'text/event-stream; charset=utf-8',
  'x-maaso-output-format': 'json_object',
  'x-maaso-generation-mode': 'project_source',
};

String _delta(String value) =>
    'event: reply.delta\ndata: ${jsonEncode({'delta': value})}\n\n';

http.Response _success(Object value) => http.Response(
  '${_delta(jsonEncode(value))}'
  'event: completion\ndata: {"finishReason":"stop","status":"complete"}\n\n'
  'event: done\ndata: [DONE]\n\n',
  200,
  headers: _headers,
);
