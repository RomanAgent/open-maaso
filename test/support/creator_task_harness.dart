import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/creator/application/creator_image_tasks.dart';
import 'package:maaso/src/features/creator/data/creator_draft_repository.dart';
import 'package:maaso/src/features/creator/data/creator_task_gateway.dart';
import 'package:maaso/src/features/creator/data/image_generation_gateway.dart';
import 'package:maaso/src/features/creator/domain/creator_draft.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:sembast/sembast_memory.dart';
import 'creator_task_fixtures.dart';

class CreatorFakeServer {
  final requests = <http.Request>[];
  final receipts = <String, CreatorTaskReceipt>{};
  final events = <CreatorTaskSnapshot>[];
  bool loseCreateAck = false;
  bool loseCommandAck = false;
  bool offline = false;
  bool badArtifact = false;
  Completer<void>? pause;
  final entered = Completer<void>();
  int get creates => requests
      .where((r) => r.method == 'POST' && r.url.path == '/v1/tasks')
      .length;
  int get commands => requests
      .where((r) => r.method == 'POST' && r.url.path != '/v1/tasks')
      .length;
  void transition(CreatorTaskStatus status, {int? attempt}) => events.add(
    taskSnapshot(
      events.length + 1,
      status,
      attempt: attempt ?? events.last.attempt,
    ),
  );
  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    if (!entered.isCompleted) entered.complete();
    if (offline) throw http.ClientException('offline');
    if (r.headers['authorization'] != 'Bearer synthetic-token') {
      throw StateError('wrong auth');
    }
    Object data;
    if (r.method == 'POST') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final nonce = body['requestId'] as String;
      final previous = receipts[nonce];
      if (previous != null) {
        data = previous.toJson();
      } else if (r.url.path == '/v1/tasks') {
        if (events.isNotEmpty) throw StateError('duplicate new admission');
        events.add(taskSnapshot(1, CreatorTaskStatus.queued));
        final receipt = taskReceipt(request: nonce);
        receipts[nonce] = receipt;
        data = receipt.toJson();
        if (loseCreateAck) {
          loseCreateAck = false;
          throw http.ClientException('accepted reply lost');
        }
      } else {
        if (body['expectedAttemptId'] != events.last.attemptId) {
          throw StateError('wrong attempt');
        }
        final retry = r.url.path.endsWith('/retry');
        transition(
          retry ? CreatorTaskStatus.queued : CreatorTaskStatus.cancelled,
          attempt: events.last.attempt + (retry ? 1 : 0),
        );
        final receipt = taskReceipt(
          request: nonce,
          sequence: events.length,
          attempt: events.last.attempt,
        );
        receipts[nonce] = receipt;
        data = receipt.toJson();
        if (loseCommandAck) {
          loseCommandAck = false;
          throw http.ClientException('command reply lost');
        }
      }
    } else if (r.url.path.endsWith('/events')) {
      final after = int.parse(r.url.queryParameters['afterSequence']!);
      data = {
        'events': [
          for (final event in events.where((v) => v.sequence > after))
            {'sequence': event.sequence, 'task': event.toJson()},
        ],
        'nextSequence': events.last.sequence,
        'hasMore': false,
      };
    } else if (r.url.path.endsWith('/result')) {
      final artifact = events.last.artifact!.toJson();
      if (badArtifact) artifact['assetId'] = 'unrelated';
      data = {
        'artifact': artifact,
        'assetUrl': 'https://media.example.invalid/image.png',
      };
    } else {
      data = events.last.toJson();
    }
    await pause?.future;
    return http.Response(
      jsonEncode({
        'code': 'OK',
        'message': '',
        'data': data,
        'traceId': 'request_1',
      }),
      200,
    );
  }
}

class CreatorTestAssets
    implements ImageGenerationGateway, CreatorTaskAssetDownloader {
  CreatorTestAssets(this.requestContextKey);
  @override
  final String requestContextKey;
  @override
  bool get isAvailable => true;
  int legacyCalls = 0;
  int downloads = 0;
  String localPath = '/test/creator/image.png';
  bool sealed = false;
  bool valid = true;
  Future<void> Function()? beforeValidation;
  @override
  void cancelPendingTaskDownloads() {
    sealed = true;
  }

  @override
  Future<void> deleteLocalAsset(CreatorAssetRef asset) async {}
  @override
  Future<CreatorAssetRef> generate({
    required String prompt,
    required String aspectRatio,
    required String style,
    required String idempotencyKey,
    required String expectedContextKey,
  }) async {
    legacyCalls++;
    throw StateError('legacy generation must not be called');
  }

  @override
  Future<CreatorAssetRef> downloadTaskAsset({
    required CreatorTaskArtifact artifact,
    required Uri assetUrl,
    required String expectedContextKey,
    required bool Function() canContinue,
  }) async {
    if (sealed || !canContinue()) throw StateError('retired');
    downloads++;
    return CreatorAssetRef(
      id: artifact.assetId,
      localPath: localPath,
      contentType: artifact.contentType,
      sha256: artifact.sha256,
      bytes: artifact.bytes,
      width: artifact.width,
      height: artifact.height,
    );
  }

  @override
  Future<bool> validateTaskAsset(
    CreatorAssetRef asset,
    CreatorTaskArtifact artifact, {
    required String expectedContextKey,
    required bool Function() canContinue,
  }) async {
    await beforeValidation?.call();
    return !sealed && valid && canContinue() && artifact.matchesAsset(asset);
  }
}

class CreatorTaskHarness {
  final server = CreatorFakeServer();
  final changes = ChangeNotifier();
  late AuthSessionService auth;
  late AppEnvironmentService environment;
  late DBService database;
  late CreatorDraftRepository repository;
  late AgentTaskJobStore jobs;
  late CreatorImageTasks tasks;
  late CreatorTestAssets assets;
  late CreatorDraft draft;
  bool current = true;
  bool expectPersistenceFailure = false;
  int authorizationCalls = 0;
  bool allowAuthorization = true;
  int nonce = 0;
  String get scope => '${environment.environment.value.key}|owner';
  String get appletScope => '${environment.baseUrl}|owner';
  Future<void> init({AgentTaskPersistence? persistence}) async {
    appServices.put<SecureStorageService>(_MemorySecrets());
    environment = appServices.put(AppEnvironmentService());
    await environment.init();
    auth = appServices.put(
      AuthSessionService(
        httpClient: MockClient((_) async => throw StateError('no refresh')),
      ),
    );
    auth.session.value = MaasoAuthSession(
      accountUuid: 'owner',
      accessToken: 'synthetic-token',
      refreshToken: 'fake',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'creator-task-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    repository = CreatorDraftRepository(
      database: database,
      environment: environment,
      auth: auth,
      mountedScopeKey: scope,
      isCurrent: () => current,
    );
    jobs = appServices.put(
      await AgentTaskJobStore(
        persistence: persistence ?? SembastAgentTaskPersistence(database),
      ).init(),
    );
    assets = CreatorTestAssets(scope);
    tasks = appServices.put(
      CreatorImageTasks(
        jobs: jobs,
        repository: repository,
        gateway: HttpCreatorTaskGateway(
          baseUri: () => Uri.parse('https://example.invalid/'),
          contextKey: () => repository.currentScopeKey,
          accessToken: () async => 'synthetic-token',
          isCurrent: () => current,
          available: true,
          client: MockClient(server.handle),
        ),
        assets: assets,
        creatorScopeKey: scope,
        appletScopeKey: appletScope,
        isCurrent: () => current,
        authorize: () async {
          authorizationCalls++;
          if (!allowAuthorization) throw StateError('consent required');
        },
        contextChanges: changes,
        reactiveContext: [auth.session, environment.environment],
        isForeground: () => false,
        requestId: () => 'request_${++nonce}',
      ),
    );
    final now = DateTime.now();
    draft = CreatorDraft(
      id: 'existing_image_draft',
      scopeKey: scope,
      kind: CreatorDraftKind.illustratedPost,
      status: CreatorDraftStatus.draft,
      title: 'Ocean',
      summary: 'local',
      blocks: const [
        CreatorDraftBlock(type: 'paragraph', text: 'A quiet coast.'),
      ],
      disclosure: creatorDisclosureFor(CreatorDraftKind.illustratedPost),
      generationDisclosure: creatorGenerationDisclosureFor(
        CreatorDraftKind.illustratedPost,
      ),
      sources: const [],
      imagePrompt: 'blue ocean',
      createdAt: now,
      updatedAt: now,
    );
    await repository.save(draft);
  }

  AgentTaskJob get latest => tasks.taskForDraft(draft.id)!;
  Future<void> start() async {
    await tasks.enqueue(draft, aspectRatio: '1:1', style: 'natural');
    await tasks.synchronize(latest.taskId);
  }

  Future<void> finish() async {
    server.transition(CreatorTaskStatus.running);
    server.transition(CreatorTaskStatus.completed);
    await tasks.synchronize(latest.taskId);
  }

  Future<void> close() async {
    if (server.pause != null && !server.pause!.isCompleted) {
      server.pause!.complete();
    }
    if (expectPersistenceFailure) {
      try {
        await tasks.deactivateAndDrain();
      } on StateError catch (e) {
        if (!e.message.toString().contains('task_persistence_failed')) rethrow;
      }
      try {
        await jobs.deactivateAndDrain();
      } on StateError catch (e) {
        if (!e.message.toString().contains('task_persistence_failed')) rethrow;
      }
    } else {
      await tasks.deactivateAndDrain();
      await jobs.deactivateAndDrain();
    }
    await appServices.reset();
    await database.close();
    changes.dispose();
  }
}

class _MemorySecrets extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
