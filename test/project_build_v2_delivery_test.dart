import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart' as crypto;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_gateway.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart'
    show ProjectBuildSnapshot;
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_verification.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'support/project_bundle_v2_fixture.dart';

const scope = 'test|owner';
Map<String, Object?> fixture() => projectBuildV2Object(
  const ProjectJsonCanonicalizer(
    maxBytes: 37 * 1024 * 1024,
  ).parse(File('tool/fixtures/project_build_wire_v2.json').readAsStringSync()),
);
List<Map<String, Object?>> events(Map<String, Object?> f) =>
    (projectBuildV2Object(f['eventsPage'])['events']! as List)
        .map(projectBuildV2Object)
        .toList();
ProjectBuildV2EventPage page(Map<String, Object?> f, int after, int until) =>
    ProjectBuildV2EventPage.fromJson(
      {
        'events': events(f).sublist(after, until),
        'nextTaskSequence': until,
        'hasMore': false,
      },
      taskId: projectBuildV2Object(f['snapshot'])['taskId']! as String,
      afterTaskSequence: after,
    );
http.Response ok(Object? value) => http.Response(
  jsonEncode({
    'code': 'OK',
    'message': 'ok',
    'traceId': 'v2-fixture',
    'data': value,
  }),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

class Harness {
  Harness({this.appletScope = scope});
  final String appletScope;
  bool foreground = true;
  bool creationReady = true;
  final f = fixture();
  final inventory = projectBuildV2Object(
    const ProjectJsonCanonicalizer(maxBytes: 37 * 1024 * 1024).parse(
      File(
        'tool/fixtures/project_build_inventory_wire_v2.json',
      ).readAsStringSync(),
    ),
  );
  bool deleted = false;
  final Map<String, Object?> documents = {};
  late DBService db;
  late Directory directory;
  late AgentTaskJobStore jobs;
  late ProjectBuildV2Repository repo;
  late ProjectBuildV2Tasks tasks;
  late ProjectBundleInstallationStore installations;
  late ProjectBundleVerificationService verifier;
  bool current = true,
      online = true,
      loseCreate = false,
      loseAccept = false,
      visible = true;
  int head = 0, nonce = 0, presentations = 0, installed = 0;
  bool failPointer = false;
  Future<void> Function()? authorizing;
  final posts = <Map<String, Object?>>[];
  final cursors = <int>[];
  Future<void> Function(http.Request)? beforePost;
  Completer<void>? candidateWait;
  Future<http.Response?> Function(http.Request)? specialRequest;
  int cleanupCount = 0;
  bool failCleanup = false;
  Future<void> Function(Set<String>)? reconciling;
  String get taskId => projectBuildV2Object(f['snapshot'])['taskId']! as String;
  Future<void> init({bool enabled = true}) async {
    final doc = projectBuildV2Object(inventory['revisionDocument']);
    documents[doc['revisionId']! as String] = doc;
    directory = await Directory.systemTemp.createTemp(
      'maaso-v2-delivery-test-',
    );
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'v2-${directory.path}',
    );
    installations = ProjectBundleInstallationStore(
      database: db.raw,
      projectBuildScopeKey: scope,
      accountScope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner',
      ),
      applicationSupportRoot: directory,
      isCurrent: () => current,
    );
    verifier = ProjectBundleVerificationService(
      trustedKeys: projectBuildV2Object(
        f['trustedVerifierKeys'],
      ).map((key, value) => MapEntry(key, base64Decode(value! as String))),
      isCurrent: () => current,
      allowDevelopmentIsolation: true,
    );
    await mount(enabled: enabled);
  }

  Future<void> mount({bool enabled = true}) async {
    jobs = await AgentTaskJobStore(
      persistence: SembastAgentTaskPersistence(db),
    ).init();
    repo = ProjectBuildV2Repository(
      database: db,
      scopeKey: scope,
      isCurrent: () => current,
    );
    tasks = ProjectBuildV2Tasks(
      jobs: jobs,
      repository: repo,
      gateway: HttpProjectBuildV2Gateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => scope,
        accessToken: () async => 'synthetic',
        isCurrent: () => current,
        client: MockClient(handle),
      ),
      scopeKey: scope,
      appletScopeKey: appletScope,
      isForeground: () => foreground,
      isCreationReady: () => creationReady,
      isCurrent: () => current,
      authorize: () async {
        await authorizing?.call();
      },
      canRecoverDispatch: () async => enabled,
      enableCreation: enabled,
      pollInterval: const Duration(hours: 1),
      requestId: () => 'v2_request_${nonce++}',
      installation: installations,
      verification: verifier,
      presentCandidate: (entry, permit, preview) async {
        expect(entry.isCurrent && permit.isCurrent, isTrue);
        if (preview) {
          expect(
            await installations.openCurrent(
              entry.bundle.manifest.projectId,
              expectedScopeKey: installations.scopeKey,
            ),
            isNull,
          );
        }
        presentations++;
        return visible;
      },
      reconcileOwnedProjects: (ids) async {
        await reconciling?.call(ids);
      },
      cleanupDeletedProject: (proof, roots) async {
        cleanupCount++;
        if (failCleanup) throw StateError('fixture_cleanup_error');
      },
      persistInstalled: (entry, agent) async {
        if (failPointer) throw StateError('fixture_disk_error');
        expect(entry.isAccepted, isTrue);
        expect(entry.isCurrent, isTrue);
        installed++;
      },
    );
  }

  Future<http.Response> handle(http.Request request) async {
    if (!online) throw http.ClientException('fixture_offline');
    expect(request.url.path, startsWith('/v1/project-builds/v2'));
    final special = await specialRequest?.call(request);
    if (special != null) return special;
    if (request.method == 'POST') {
      final body = projectBuildV2Object(jsonDecode(request.body));
      posts.add(body);
      await beforePost?.call(request);
      final accept = request.url.path.endsWith('/accept');
      head = accept ? 4 : 3;
      final receipt = {
        ...projectBuildV2Object(f[accept ? 'acceptReceipt' : 'createReceipt']),
        'requestId': body['requestId'],
      };
      if (accept && loseAccept) {
        loseAccept = false;
        throw http.ClientException('lost accept ACK');
      }
      if (!accept && loseCreate) {
        loseCreate = false;
        throw http.ClientException('lost create ACK');
      }
      return ok(receipt);
    }
    if (request.url.path.endsWith('/projects')) {
      return ok(
        deleted || head < 4
            ? {'schemaVersion': 2, 'projects': []}
            : inventory['projects'],
      );
    }
    if (request.url.path.contains('/projects/')) {
      if (deleted) return http.Response(jsonEncode({'code': 'NOT_FOUND'}), 404);
      return ok(
        request.url.path.endsWith('/revisions')
            ? inventory['revisions']
            : documents[request.url.pathSegments.last],
      );
    }
    if (request.url.path.endsWith('/candidate')) {
      await candidateWait?.future;
      return ok(f['candidateDocument']);
    }
    if (request.url.path.endsWith('/events')) {
      final after = int.parse(
        request.url.queryParameters['afterTaskSequence']!,
      );
      cursors.add(after);
      return ok({
        'events': events(f).sublist(after, head),
        'nextTaskSequence': head,
        'hasMore': false,
      });
    }
    return ok(events(f)[head - 1]['snapshot']);
  }

  Future<AgentTaskJob> enqueue() async {
    final job = await tasks.enqueue(
      projectKind: ProjectBuildKind.applet,
      requirements: 'Build an offline task list.',
    );
    await tasks.synchronize(job.taskId);
    return latest(job.taskId);
  }

  AgentTaskJob latest(String root) =>
      jobs.latestForTask(root, appletScopeKey: appletScope, agentId: 'self')!;
  Future<void> waitUntil(bool Function() ready) async {
    final watch = Stopwatch()..start();
    while (!ready()) {
      if (watch.elapsed > const Duration(seconds: 10)) {
        throw StateError('fixture_ui_did_not_settle');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    await tasks.deactivateAndDrain();
    await jobs.flush();
    await installations.deactivateAndDrain();
    verifier.deactivate();
    await db.raw.close();
    await directory.delete(recursive: true);
  }
}

Future<void> useTwoSignedRevisions(Harness h) async {
  final original = ProjectBuildV2Candidate.fromJson(
    projectBuildV2Object(h.f['candidateDocument']),
  );
  final newer = productionBundleFixture(revision: 3);
  final key = await crypto.Ed25519().newKeyPair();
  Future<Map<String, Object?>> reportFor(
    ValidatedProjectBundleV2 bundle,
  ) async {
    final payload = {
      ...projectBuildV2Object(original.report['payload']),
      'projectId': bundle.manifest.projectId,
      'revisionId': bundle.manifest.revisionId,
      'candidateDigest': bundle.candidateDigest,
      'contentDigest': bundle.manifest.contentDigest,
      'artifactDigest': bundle.manifest.artifactDigest,
    };
    final signature = await crypto.Ed25519().sign(
      const ProjectJsonCanonicalizer().canonicalBytes(payload),
      keyPair: key,
    );
    return {
      'payload': payload,
      'keyId': 'inventory-unit',
      'signature': base64Encode(signature.bytes),
    };
  }

  final oldReport = await reportFor(original.bundle),
      newReport = await reportFor(newer);
  final oldHash = projectBundleV2JsonDigest(oldReport),
      newHash = projectBundleV2JsonDigest(newReport);
  final oldDoc = {
    ...projectBuildV2Object(h.f['candidateDocument']),
    'report': oldReport,
    'reportDigest': oldHash,
  };
  h.f['candidateDocument'] = oldDoc;
  final rawEvents = List<Object?>.from(
    projectBuildV2Object(h.f['eventsPage'])['events']! as List,
  );
  for (var index = 0; index < rawEvents.length; index++) {
    final event = projectBuildV2Object(rawEvents[index]),
        snapshot = projectBuildV2Object(
          projectBuildV2Object(rawEvents[index])['snapshot'],
        );
    if (snapshot['candidate'] != null) {
      snapshot['candidate'] = {
        ...projectBuildV2Object(snapshot['candidate']),
        'reportDigest': oldHash,
      };
    }
    if (snapshot['savedRevision'] != null) {
      snapshot['savedRevision'] = {
        ...projectBuildV2Object(snapshot['savedRevision']),
        'reportDigest': oldHash,
      };
    }
    rawEvents[index] = {...event, 'snapshot': snapshot};
  }
  h.f['eventsPage'] = {
    ...projectBuildV2Object(h.f['eventsPage']),
    'events': rawEvents,
  };
  h.f['snapshot'] = projectBuildV2Object(rawEvents.last)['snapshot'];
  h.f['acceptReceipt'] = {
    ...projectBuildV2Object(h.f['acceptReceipt']),
    'reportDigest': oldHash,
  };
  final newDoc = {
    ...oldDoc,
    'taskId': 'pb_task_00000000-0000-0000-0000-000000000019',
    'runId': 'pb_run_00000000-0000-0000-0000-000000000020',
    'candidateId': 'pb_candidate_00000000-0000-0000-0000-000000000021',
    'revisionId': newer.manifest.revisionId,
    'baseRevision': newer.manifest.baseRevision,
    'baseHeadVersion': 1,
    'candidateDigest': newer.candidateDigest,
    'reportDigest': newHash,
    'bundle': jsonDecode(const ProjectBundleV2Codec().encode(newer)),
    'report': newReport,
  };
  h.documents[original.reference.revisionId] = oldDoc;
  h.documents[newer.manifest.revisionId] = newDoc;
  final oldDescriptor = {
    ...projectBuildV2Object(
      (projectBuildV2Object(h.inventory['revisions'])['revisions']! as List)
          .single,
    ),
    'reportDigest': oldHash,
  };
  h.inventory['revisions'] = {
    ...projectBuildV2Object(h.inventory['revisions']),
    'currentRevisionId': newer.manifest.revisionId,
    'currentHeadVersion': 2,
    'revisions': [
      oldDescriptor,
      {
        'revisionId': newer.manifest.revisionId,
        'baseRevision': original.reference.revisionId,
        'candidateDigest': newer.candidateDigest,
        'reportDigest': newHash,
        'createdAt': '2026-09-28T09:00:00Z',
      },
    ],
  };
  final project = projectBuildV2Object(
    (projectBuildV2Object(h.inventory['projects'])['projects']! as List).single,
  );
  h.inventory['projects'] = {
    'schemaVersion': 2,
    'projects': [
      {
        ...project,
        'currentRevisionId': newer.manifest.revisionId,
        'revisionCount': 2,
        'headVersion': 2,
        'updatedAt': '2026-09-28T09:00:00Z',
      },
    ],
  };
  await h.tasks.deactivateAndDrain();
  h.verifier.deactivate();
  h.verifier = ProjectBundleVerificationService(
    trustedKeys: {'inventory-unit': (await key.extractPublicKey()).bytes},
    isCurrent: () => h.current,
    allowDevelopmentIsolation: true,
  );
  await h.mount(enabled: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'fresh committed owner discovery clears prior absence before delivering a new save',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      final seen = <Set<String>>[];
      h.reconciling = (ids) async {
        final persisted = await h.repo.readOwnedProjects(
          expectedScopeKey: scope,
        );
        expect(
          persisted!.projects.map((p) => p.projectId).toSet(),
          ids,
          reason: 'callback receives committed complete authority',
        );
        seen.add(Set.of(ids));
        h.installations.reconcileOwnedPresentations(
          ids,
          expectedScopeKey: h.installations.scopeKey,
        );
      };
      await h.tasks.restoreSavedProjects();
      expect(seen, isNotEmpty);
      expect(seen.every((ids) => ids.isEmpty), isTrue);
      final job = await h.enqueue();
      expect(
        await h.tasks.preview(job.id, expectedAttempt: 1),
        isTrue,
        reason: 'an unsaved preview is not withdrawn by empty owned inventory',
      );
      expect(await h.tasks.accept(job.id, expectedAttempt: 1), isTrue);
      final saved = h.latest(job.taskId),
          id = saved.projectBuildV2!.snapshot!.projectId;
      expect(seen.last, contains(id));
      expect(h.installed, 1);
      expect(h.tasks.canOpen(saved), isTrue);
      expect(await h.tasks.open(saved.id, expectedAttempt: 1), isTrue);
    },
  );
  test(
    'owner reconciliation that retires the account stops delivery after the callback',
    () async {
      final h = Harness();
      await h.init(enabled: false);
      addTearDown(h.close);
      h.head = 4;
      h.reconciling = (ids) async {
        expect(ids, isNotEmpty);
        h.current = false;
      };
      await h.tasks.restoreSavedProjects();
      expect(h.installed, 0);
      expect(h.presentations, 0);
      h.current = true;
      expect(
        await h.installations.openCurrent(
          projectBuildV2Object(h.f['snapshot'])['projectId']! as String,
          expectedScopeKey: h.installations.scopeKey,
        ),
        isNull,
      );
    },
  );

  test(
    'completed offline delivery stays usable on network failure but authenticated task withdrawal disables open',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      final initial = await h.enqueue();
      expect(await h.tasks.preview(initial.id, expectedAttempt: 1), isTrue);
      expect(await h.tasks.accept(initial.id, expectedAttempt: 1), isTrue);
      expect(h.tasks.canOpen(h.latest(initial.taskId)), isTrue);
      h.online = false;
      await h.tasks.synchronize(initial.taskId);
      expect(h.tasks.canOpen(h.latest(initial.taskId)), isTrue);
      expect(await h.tasks.open(initial.id, expectedAttempt: 1), isTrue);
      h.online = true;
      h.specialRequest = (request) async =>
          request.method == 'GET' &&
              request.url.path == '/v1/project-builds/v2/${h.taskId}'
          ? http.Response(
              jsonEncode({
                'code': 'NOT_FOUND',
                'message': '',
                'traceId': 'unit',
              }),
              404,
            )
          : null;
      await h.tasks.synchronize(initial.taskId);
      final withdrawn = h.latest(initial.taskId);
      expect(withdrawn.projectBuildV2!.syncIssue, 'rejected:task_unavailable');
      expect(h.tasks.canOpen(withdrawn), isFalse);
      final presentations = h.presentations;
      expect(await h.tasks.open(withdrawn.id, expectedAttempt: 1), isFalse);
      expect(h.presentations, presentations);
      expect(
        await h.installations.openCandidate(
          withdrawn.projectBuildV2!.snapshot!.candidate!.candidateDigest,
          expectedScopeKey: h.installations.scopeKey,
        ),
        isNotNull,
        reason:
            'task withdrawal is an open fence, not an invented project deletion receipt',
      );
    },
  );

  testWidgets(
    'native card exposes save only after real presentation acknowledgement',
    (tester) async {
      await appServices.reset();
      appServices.testMode = true;
      AppLocalization.updateLocale(const Locale('zh', 'CN'));
      final h = Harness(appletScope: 'device-legacy');
      addTearDown(() async {
        await h.close();
        await appServices.reset();
      });
      final job = (await tester.runAsync(() async {
        await h.init();
        return h.enqueue();
      }))!;
      h.foreground = false;
      appServices.put(h.jobs);
      appServices.put(h.tasks);
      h.foreground = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AgentTaskChatCard(
                reference: h.jobs.cardFor(job).taskReference!,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('home.task.preview_result'.tr), findsOneWidget);
      expect(find.text('project_build.task.save_result'.tr), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('home.task.preview_result'.tr));
        await h.waitUntil(() => h.tasks.canAccept(h.latest(job.taskId)));
      });
      await tester.pump();
      expect(h.presentations, 1);
      expect(find.text('project_build.task.save_result'.tr), findsOneWidget);
      expect(h.installed, 0);
      await tester.runAsync(() async {
        await tester.tap(find.text('project_build.task.save_result'.tr));
        await h.waitUntil(() => h.tasks.canOpen(h.latest(job.taskId)));
      });
      await tester.pump();
      expect(h.installed, 1);
      expect(find.text('home.task.open_result'.tr), findsOneWidget);
      expect(find.text('project_build.task.save_result'.tr), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'owned inventory restores original Agent without inventing task history and reopens offline',
    () async {
      final h = Harness();
      await h.init(enabled: false);
      addTearDown(h.close);
      h.head = 4;
      await h.tasks.restoreSavedProjects();
      expect(h.tasks.inventoryIssue.value, isEmpty);
      expect(h.installed, 1);
      expect(h.jobs.jobs, isEmpty);
      expect(await h.repo.list(expectedScopeKey: scope), isEmpty);
      expect(h.posts, isEmpty);
      final inventory = (await h.tasks.savedProjects())!;
      expect(inventory.projects.single.agentId, 'self');
      h.online = false;
      expect(
        await h.tasks.openSavedRevision(
          inventory.projects.single.projectId,
          inventory.projects.single.currentRevisionId,
        ),
        isTrue,
      );
      expect(h.presentations, 1);
    },
  );
  test(
    'deleted owned project cannot be resurrected from staged completed task bytes',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      final job = await h.enqueue();
      await h.tasks.preview(job.id, expectedAttempt: 1);
      h.deleted = true;
      await h.tasks.accept(job.id, expectedAttempt: 1);
      expect(h.installed, 0);
      expect(h.tasks.canOpen(h.latest(job.taskId)), isFalse);
      expect(
        await h.installations.openCurrent(
          projectBuildV2Object(h.f['snapshot'])['projectId']! as String,
          expectedScopeKey: h.installations.scopeKey,
        ),
        isNull,
      );
    },
  );
  test(
    'owned revision chain rejects forks cycles omissions and foreign scoped proof',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      final raw = projectBuildV2Object(h.inventory['revisions']);
      final descriptor = projectBuildV2Object(
        (raw['revisions']! as List).single,
      );
      expect(
        () => ProjectBuildV2OwnedRevisions.fromJson({
          ...raw,
          'revisions': [
            {...descriptor, 'baseRevision': descriptor['revisionId']},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => ProjectBuildV2OwnedRevisions.fromJson({
          ...raw,
          'revisions': [
            descriptor,
            {
              ...descriptor,
              'revisionId': 'pb_revision_00000000-0000-0000-0000-000000000099',
              'candidateDigest': 'f' * 64,
            },
          ],
        }),
        throwsFormatException,
      );
      await h.repo.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson(h.inventory['projects']),
        expectedScopeKey: scope,
      );
      final proofs = await h.repo.recordOwnedRevisions(
        ProjectBuildV2OwnedRevisions.fromJson(raw),
        expectedScopeKey: scope,
      );
      expect(proofs.single.scopeKey, scope);
      await expectLater(
        h.repo.ownedRevision(
          proofs.single.projectId,
          proofs.single.revisionId,
          expectedScopeKey: 'test|other',
        ),
        throwsStateError,
      );
      await h.repo.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson({
          'schemaVersion': 2,
          'projects': [],
        }),
        expectedScopeKey: scope,
      );
      expect(
        await h.repo.ownedRevision(
          proofs.single.projectId,
          proofs.single.revisionId,
          expectedScopeKey: scope,
        ),
        isNull,
      );
    },
  );
  test(
    'saved history opens offline while old task and stale inventory cannot roll back current head',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      await useTwoSignedRevisions(h);
      h.head = 4;
      await h.tasks.restoreSavedProjects();
      expect(h.tasks.inventoryIssue.value, isEmpty);
      final owned = ProjectBuildV2OwnedRevisions.fromJson(
        h.inventory['revisions'],
      );
      expect(
        (await h.installations.openCurrent(
          owned.projectId,
          expectedScopeKey: h.installations.scopeKey,
        ))!.bundle.manifest.revisionId,
        owned.currentRevisionId,
      );
      await h.repo.prepareCreate(
        ProjectBuildV2CreateRequest.fromJson(
          projectBuildV2Object(h.f['createRequest']),
        ),
        expectedScopeKey: scope,
      );
      await h.repo.recordReceipt(
        ProjectBuildV2Receipt.fromJson(
          projectBuildV2Object(h.f['createReceipt']),
        ),
        expectedScopeKey: scope,
      );
      await h.repo.applyPage(
        h.taskId,
        page(h.f, 0, 4),
        expectedScopeKey: scope,
      );
      await h.tasks.restore();
      final job = h.jobs.jobs.single;
      expect(h.tasks.canOpen(job), isTrue);
      expect(
        (await h.installations.openCurrent(
          owned.projectId,
          expectedScopeKey: h.installations.scopeKey,
        ))!.bundle.manifest.revisionId,
        owned.currentRevisionId,
      );
      final historical = owned.revisions.first;
      h.online = false;
      expect(
        await h.tasks.openSavedRevision(owned.projectId, historical.revisionId),
        isTrue,
      );
      h.online = true;
      h.inventory['revisions'] = {
        'schemaVersion': 2,
        'projectId': owned.projectId,
        'currentRevisionId': historical.revisionId,
        'revisions': [historical.toJson()],
      };
      final project = projectBuildV2Object(
        (projectBuildV2Object(h.inventory['projects'])['projects']! as List)
            .single,
      );
      h.inventory['projects'] = {
        'schemaVersion': 2,
        'projects': [
          {
            ...project,
            'currentRevisionId': historical.revisionId,
            'revisionCount': 1,
          },
        ],
      };
      await h.tasks.restoreSavedProjects();
      expect(h.tasks.inventoryIssue.value, isNotEmpty);
      expect(
        (await h.installations.openCurrent(
          owned.projectId,
          expectedScopeKey: h.installations.scopeKey,
        ))!.bundle.manifest.revisionId,
        owned.currentRevisionId,
      );
    },
  );
  test(
    'readiness closes model admission without blocking owned inventory recovery',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      h.creationReady = false;
      h.head = 4;
      expect(h.tasks.canSubmit, isFalse);
      await expectLater(
        h.tasks.enqueue(
          projectKind: ProjectBuildKind.applet,
          requirements: 'x',
        ),
        throwsStateError,
      );
      await h.tasks.restoreSavedProjects();
      expect(h.installed, 1);
      expect(h.posts, isEmpty);
      h.creationReady = true;
      expect(h.tasks.canSubmit, isTrue);
    },
  );
  test(
    'readiness revoked during token wait blocks dispatch at the HTTP boundary',
    () async {
      final token = Completer<String>();
      var permitted = true, posts = 0;
      final gateway = HttpProjectBuildV2Gateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => scope,
        accessToken: () => token.future,
        isCurrent: () => true,
        client: MockClient((_) async {
          posts++;
          return ok(fixture()['createReceipt']);
        }),
      );
      final work = gateway.create(
        request: ProjectBuildV2CreateRequest.fromJson(
          projectBuildV2Object(fixture()['createRequest']),
        ),
        expectedContextKey: scope,
        canDispatch: () => permitted,
      );
      permitted = false;
      token.complete('synthetic');
      await expectLater(
        work,
        throwsA(
          isA<ProjectBuildV2RequestException>().having(
            (e) => e.code,
            'code',
            'project_build_dispatch_revoked',
          ),
        ),
      );
      expect(posts, 0);
      await gateway.deactivateAndDrain();
    },
  );
  test(
    'cancelled initiating turn cannot create an intent after authorization or queue wait',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      final gate = Completer<void>();
      h.authorizing = () => gate.future;
      var currentTurn = true;
      final work = h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'stopped before durable admission',
        canContinue: () => currentTurn,
      );
      final cancelled = expectLater(
        work,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'project_build_turn_cancelled',
          ),
        ),
      );
      final queued = h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'stopped in admission queue',
        canContinue: () => currentTurn,
      );
      final queuedCancelled = expectLater(
        queued,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'project_build_turn_cancelled',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      currentTurn = false;
      gate.complete();
      await cancelled;
      await queuedCancelled;
      expect(h.posts, isEmpty);
      expect(h.jobs.jobs, isEmpty);
      expect(await h.repo.pendingRequests(expectedScopeKey: scope), isEmpty);
    },
  );
  test(
    'creation stays closed by default and an invisible preview cannot grant save',
    () async {
      final h = Harness();
      await h.init(enabled: false);
      addTearDown(h.close);
      await expectLater(
        h.tasks.enqueue(
          projectKind: ProjectBuildKind.applet,
          requirements: 'x',
        ),
        throwsStateError,
      );
      expect(h.posts, isEmpty);
      expect(await h.repo.pendingRequests(expectedScopeKey: scope), isEmpty);
      await h.tasks.deactivateAndDrain();
      await h.mount();
      final job = await h.enqueue();
      h.visible = false;
      expect(await h.tasks.preview(job.id, expectedAttempt: 1), isFalse);
      expect(h.tasks.canAccept(h.latest(job.taskId)), isFalse);
      expect(await h.tasks.accept(job.id, expectedAttempt: 1), isFalse);
      expect(h.posts.length, 1);
      expect(h.installed, 0);
    },
  );
  test(
    'candidate identity cannot change between preview and completed even without local accept',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      await h.enqueue();
      final changed = projectBuildV2Object(jsonDecode(jsonEncode(h.f)));
      final last = events(changed).last;
      final snapshot = projectBuildV2Object(last['snapshot']);
      final changedReference = {
        ...projectBuildV2Object(snapshot['candidate']),
        'reportDigest': 'a' * 64,
      };
      final wrong = {
        ...last,
        'snapshot': {
          ...snapshot,
          'candidate': changedReference,
          'savedRevision': {
            ...projectBuildV2Object(snapshot['savedRevision']),
            'reportDigest': 'a' * 64,
          },
        },
      };
      final body = {
        'events': [wrong],
        'nextTaskSequence': 4,
        'hasMore': false,
      };
      await expectLater(
        h.repo.applyPage(
          h.taskId,
          ProjectBuildV2EventPage.fromJson(
            body,
            taskId: h.taskId,
            afterTaskSequence: 3,
          ),
          expectedScopeKey: scope,
        ),
        throwsStateError,
      );
      expect(
        (await h.repo.read(
          h.taskId,
          expectedScopeKey: scope,
        ))!.appliedTaskSequence,
        3,
      );
    },
  );
  test(
    'shared Go fixture is strict V2; V1 refuses delivery states; report verifies',
    () async {
      final f = fixture(),
          snapshot = ProjectBuildV2Snapshot.fromJson(
            projectBuildV2Object(fixture()['snapshot']),
          );
      expect(snapshot.status, ProjectBuildV2Status.completed);
      expect(
        () => ProjectBuildSnapshot.fromJson(snapshot.toJson()),
        throwsFormatException,
      );
      final candidate = ProjectBuildV2Candidate.fromJson(
        projectBuildV2Object(f['candidateDocument']),
      );
      expect(candidate.matches(snapshot), isTrue);
      final revised = productionBundleFixture(revision: 3);
      final revisedDoc = {
        ...projectBuildV2Object(f['candidateDocument']),
        'candidateDigest': revised.candidateDigest,
        'revisionId': revised.manifest.revisionId,
        'baseRevision': revised.manifest.baseRevision,
        'baseHeadVersion': revised.manifest.baseRevision == null ? null : 1,
        'bundle': jsonDecode(const ProjectBundleV2Codec().encode(revised)),
      };
      final revisedCandidate = ProjectBuildV2Candidate.fromJson(revisedDoc);
      final revisedSnapshot = ProjectBuildV2Snapshot.fromJson({
        ...snapshot.toJson(),
        'candidate': revisedCandidate.reference.toJson(),
        'savedRevision': {
          ...snapshot.savedRevision!.toJson(),
          'revisionId': revised.manifest.revisionId,
          'candidateDigest': revised.candidateDigest,
          'headVersion': revised.manifest.baseRevision == null ? 1 : 2,
        },
      });
      expect(
        revisedCandidate.matches(revisedSnapshot),
        isFalse,
        reason:
            'candidate requirementRevision cannot differ from task revision',
      );

      final wrongKind = ProjectBuildV2Snapshot.fromJson({
        ...snapshot.toJson(),
        'projectKind': 'game',
      });
      expect(candidate.matches(wrongKind), isFalse);
      final candidateDocument = projectBuildV2Object(f['candidateDocument']);
      expect(
        () => ProjectBuildV2Snapshot.fromJson({
          ...snapshot.toJson(),
          'requirementRevision': 2,
        }),
        throwsFormatException,
      );
      expect(candidate.bundle.manifest.requirementRevision, 1);
      expect(candidateDocument['projectId'], snapshot.projectId);

      final verifier = ProjectBundleVerificationService(
        trustedKeys: projectBuildV2Object(
          f['trustedVerifierKeys'],
        ).map((k, v) => MapEntry(k, base64Decode(v! as String))),
        isCurrent: () => true,
        allowDevelopmentIsolation: true,
      );
      final permit = await verifier.verifyReport(
        candidate.bundle,
        candidate.report,
        expectedReportDigest: candidate.reference.reportDigest,
      );
      expect(permit.candidateDigest, candidate.bundle.candidateDigest);
      expect(
        () => candidate.report['signature'] = 'forged',
        throwsUnsupportedError,
      );
      expect(
        () => ProjectBuildV2Snapshot.fromJson(
          {...snapshot.toJson()}..remove('savedRevision'),
        ),
        throwsFormatException,
      );
      final input = ProjectBuildV2CreateRequest.fromJson(
        projectBuildV2Object(f['createRequest']),
      );
      expect(input.projectId, isNull);
      expect(
        () => ProjectBuildV2CreateRequest(
          requestId: 'request_123',
          agentId: 'self',
          projectKind: ProjectBuildKind.applet,
          requirements: 'x',
          projectId: snapshot.projectId,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'gateway rejects duplicate HTTP keys before map decoding and retires stalled token',
    () async {
      final f = fixture(),
          task = projectBuildV2Object(f['snapshot'])['taskId']! as String;
      final gateway = HttpProjectBuildV2Gateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => scope,
        accessToken: () async => 'fixture',
        isCurrent: () => true,
        client: MockClient(
          (_) async => http.Response(
            '{"code":"OK","code":"OK","message":"ok","traceId":"x","data":${jsonEncode(f['snapshot'])}}',
            200,
          ),
        ),
      );
      await expectLater(
        gateway.snapshot(taskId: task, expectedContextKey: scope),
        throwsA(isA<ProjectBuildV2RequestException>()),
      );
      await gateway.deactivateAndDrain();
      final stalled = HttpProjectBuildV2Gateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => scope,
        accessToken: () => Completer<String>().future,
        isCurrent: () => true,
      );
      final pending = stalled.snapshot(taskId: task, expectedContextKey: scope);
      final error = expectLater(
        pending,
        throwsA(isA<ProjectBuildV2RequestException>()),
      );
      await stalled.deactivateAndDrain().timeout(const Duration(seconds: 1));
      await error;
    },
  );
  test(
    'real journal to signed preview to durable accept to offline pointer; no premature save',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      h.beforePost = (request) async {
        final pending = await h.repo.pendingRequests(expectedScopeKey: scope);
        expect(
          pending.any(
            (r) => r.requestId == jsonDecode(request.body)['requestId'],
          ),
          isTrue,
        );
        expect(h.jobs.jobs.single.projectBuildV2!.pendingCommand, isNotNull);
      };
      final job = await h.enqueue();
      expect(job.isProjectBuildV2, isTrue);
      expect(job.isProjectBuild, isFalse);
      expect(job.stage, AgentTaskStage.previewReady);
      expect(job.status, AgentTaskJobStatus.awaitingInput);
      expect(h.tasks.canAccept(job), isFalse);
      expect(h.installed, 0);
      expect(await h.tasks.preview(job.id, expectedAttempt: 1), isTrue);
      expect(h.tasks.canAccept(h.latest(job.taskId)), isTrue);
      expect(h.installed, 0);
      expect(await h.tasks.accept(job.id, expectedAttempt: 1), isTrue);
      final saved = h.latest(job.taskId);
      expect(saved.status, AgentTaskJobStatus.completed);
      expect(saved.projectBuildV2!.appliedTaskSequence, 4);
      expect(h.tasks.canControl(saved, retry: true), isFalse);
      expect(h.tasks.canOpen(saved), isTrue);
      expect(h.installed, 1);
      h.online = false;
      expect(await h.tasks.open(saved.id, expectedAttempt: 1), isTrue);
      expect(h.presentations, 2);
      expect(h.cursors, containsAllInOrder([0, 3]));
      await h.tasks.deactivateAndDrain();
      await h.mount(enabled: false);
      await h.tasks.restore();
      final reopened = h.jobs.jobs.single;
      expect(h.tasks.canOpen(reopened), isTrue);
      expect(await h.tasks.open(reopened.id, expectedAttempt: 1), isTrue);
      expect(h.installed, 1);
    },
  );
  test(
    'ACK loss + restart replays original create and accept nonces; accepted horizon replays',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      h.loseCreate = true;
      var job = await h.enqueue();
      expect(job.projectBuildV2!.snapshot, isNull);
      final first = h.posts.first['requestId'];
      await h.tasks.deactivateAndDrain();
      await h.mount();
      await h.tasks.restore();
      job = h.jobs.jobs.single;
      expect(h.posts.last['requestId'], first);
      expect(job.stage, AgentTaskStage.previewReady);
      await h.tasks.preview(job.id, expectedAttempt: 1);
      h.loseAccept = true;
      await h.tasks.accept(job.id, expectedAttempt: 1);
      final acceptNonce = h.posts.last['requestId'];
      expect(h.installed, 0);
      await h.tasks.deactivateAndDrain();
      await h.mount(enabled: false);
      await h.tasks.restore();
      expect(h.posts.last['requestId'], acceptNonce);
      expect(h.jobs.jobs.single.status, AgentTaskJobStatus.completed);
      expect(h.installed, 1);
    },
  );
  test(
    'receipt ahead of UI and terminal journal recovers installation after crash',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      final job = await h.enqueue();
      await h.tasks.preview(job.id, expectedAttempt: 1);
      final command = ProjectBuildV2Command.fromJson(
        projectBuildV2Object(h.f['acceptRequest']),
        operation: ProjectBuildV2Operation.accept,
      );
      await h.repo.prepareCommand(h.taskId, command, expectedScopeKey: scope);
      await h.repo.recordReceipt(
        ProjectBuildV2Receipt.fromJson(
          projectBuildV2Object(h.f['acceptReceipt']),
        ),
        expectedScopeKey: scope,
      );
      h.head = 4;
      await h.tasks.deactivateAndDrain();
      await h.mount(enabled: false);
      await h.tasks.restore();
      expect(h.jobs.jobs.single.projectBuildV2!.appliedTaskSequence, 4);
      expect(h.installed, 1);
      expect(h.posts.length, 1);
    },
  );
  test(
    'failed local pointer commit is retryable and never presents as offline available',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      var job = await h.enqueue();
      await h.tasks.preview(job.id, expectedAttempt: 1);
      h.failPointer = true;
      await h.tasks.accept(job.id, expectedAttempt: 1);
      job = h.latest(job.taskId);
      expect(job.status, AgentTaskJobStatus.completed);
      expect(h.tasks.canOpen(job), isFalse);
      h.failPointer = false;
      await h.tasks.synchronize(job.taskId);
      expect(h.tasks.canOpen(h.latest(job.taskId)), isTrue);
      expect(h.posts.where((p) => p.containsKey('candidateDigest')).length, 1);
    },
  );
  test(
    'late candidate after account change cannot present, accept or install',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      final job = await h.enqueue();
      h.candidateWait = Completer<void>();
      final preview = h.tasks.preview(job.id, expectedAttempt: 1);
      final error = expectLater(preview, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      h.current = false;
      h.candidateWait!.complete();
      await error;
      expect(h.presentations, 0);
      expect(h.installed, 0);
      expect(h.tasks.canAccept(job), isFalse);
    },
  );
  test(
    'repository rejects accept receipt mismatch in both event orders',
    () async {
      final h = Harness();
      await h.init();
      addTearDown(h.close);
      await h.enqueue();
      final command = ProjectBuildV2Command.fromJson(
        projectBuildV2Object(h.f['acceptRequest']),
        operation: ProjectBuildV2Operation.accept,
      );
      await h.repo.prepareCommand(h.taskId, command, expectedScopeKey: scope);
      final wrong = {
        ...projectBuildV2Object(h.f['acceptReceipt']),
        'reportDigest': 'f' * 64,
      };
      await h.repo.applyPage(
        h.taskId,
        page(h.f, 3, 4),
        expectedScopeKey: scope,
      );
      await expectLater(
        h.repo.recordReceipt(
          ProjectBuildV2Receipt.fromJson(wrong),
          expectedScopeKey: scope,
        ),
        throwsStateError,
      );
      await h.repo.recordReceipt(
        ProjectBuildV2Receipt.fromJson(
          projectBuildV2Object(h.f['acceptReceipt']),
        ),
        expectedScopeKey: scope,
      );
      expect(
        (await h.repo.read(
          h.taskId,
          expectedScopeKey: scope,
        ))!.appliedTaskSequence,
        4,
      );
    },
  );
}
