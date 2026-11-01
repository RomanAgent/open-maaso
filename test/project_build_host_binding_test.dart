import 'support/project_bundle_install_authority.dart';
import 'project_bundle_deletion_test.dart' show deletionProof;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/project_build/application/project_build_host_binding.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DBService database;
  late AgentTaskJobStore jobs;
  late ProjectBuildHostBinding binding;
  late Map<String, Object?> fixture;
  late ProjectBuildV2Candidate candidate;
  late ProjectBuildHostConfiguration configuration;
  var current = true, foreground = true;
  var appletScope = 'https://example.invalid|owner';
  var now = DateTime.utc(2026, 9, 30);
  var workerReady = true;
  final requests = <http.Request>[];
  Completer<http.Response>? delayed;
  Map<String, Object?> readiness() => {
    'schemaVersion': 2,
    'enabled': true,
    'workerReady': workerReady,
    'verifierKeyIds': configuration.trustedKeys.keys.toList(),
    'profile': 'maaso.project.verification.v2',
    'runtime': 'runc',
    'productionIsolation': false,
  };
  http.Response response(Object? data) => http.Response(
    jsonEncode({'code': 'OK', 'message': '', 'traceId': 'unit', 'data': data}),
    200,
  );
  setUp(() async {
    current = true;
    foreground = true;
    appletScope = 'https://example.invalid|owner';
    now = DateTime.utc(2026, 9, 30);
    workerReady = true;
    delayed = null;
    requests.clear();
    fixture = Map<String, Object?>.from(
      jsonDecode(
            File('tool/fixtures/project_build_wire_v2.json').readAsStringSync(),
          )
          as Map,
    );
    candidate = ProjectBuildV2Candidate.fromJson(
      projectBuildV2Object(fixture['candidateDocument']),
    );
    configuration = ProjectBuildHostConfiguration.parse(
      enableCreation: true,
      trustedKeysBase64: base64Encode(
        utf8.encode(jsonEncode(fixture['trustedVerifierKeys'])),
      ),
      debugBuild: true,
      allowDevelopmentIsolation: true,
    );
    directory = await Directory.systemTemp.createTemp('project-binding-');
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: directory.path,
    );
    jobs = await AgentTaskJobStore(
      persistence: SembastAgentTaskPersistence(database),
    ).init();
    binding = ProjectBuildHostBinding(
      database: database,
      accountScope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner',
      ),
      applicationSupportRoot: directory,
      creatorScope: 'test|owner',
      appletScope: appletScope,
      configuration: configuration,
      jobs: jobs,
      baseUri: Uri.parse('https://example.invalid/'),
      accessToken: () async => 'synthetic',
      isCurrent: () => current,
      isForeground: () => foreground,
      authorizeCloudText: () async {},
      runtimeForAgent: (_) => null,
      currentAppletScope: () => appletScope,
      presentCandidate: (_, _, _) async => true,
      now: () => now,
      httpClient: MockClient((request) async {
        requests.add(request);
        if (delayed != null) return delayed!.future;
        if (request.url.path.endsWith('/readiness')) {
          return response(readiness());
        }
        return http.Response('', 404);
      }),
    );
  });
  tearDown(() async {
    await binding.deactivateAndDrain();
    await jobs.deactivateAndDrain();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'confirmed deletion cleans scoped pointers and both play stores without touching another owner',
    () async {
      final permit = await binding.verification.verifyReport(
        candidate.bundle,
        candidate.report,
      );
      final installed = await testInstallBundle(
        binding.installations,
        candidate.bundle,
        expectedScopeKey: binding.installations.scopeKey,
        expectedCurrentCandidateDigest: null,
        permit: permit,
        verificationReport: candidate.report,
      );
      await binding.persistInstalled(installed, 'self');
      final other = binding.widgetFor(
        installed,
        reportDigest: permit.reportDigest,
        agentId: 'self',
      );
      AppletLocalOwnership.stamp(
        other,
        scopeKey: 'https://example.invalid|other',
      );
      await database.saveAgentWidget(other);
      expect(binding.play.projectBuildScopeKey, 'test|owner');
      expect(binding.previewPlay.projectBuildScopeKey, 'test|owner');
      final wrong = await deletionProof(candidate.bundle, scope: 'test|other');
      await expectLater(
        binding.cleanupDeletedProject(wrong, {}),
        throwsStateError,
      );
      expect(await database.getAllWidgets(), hasLength(2));
      final proof = await deletionProof(candidate.bundle);
      await binding.installations.purgeDeletedProject(
        proof,
        expectedScopeKey: binding.installations.scopeKey,
        expectedProjectBuildScopeKey: 'test|owner',
      );
      await binding.cleanupDeletedProject(proof, {});
      await binding.cleanupDeletedProject(proof, {});
      final rows = await database.getAllWidgets();
      expect(rows, hasLength(1));
      expect(
        AppletLocalOwnership.storedScopeKey(rows.single),
        'https://example.invalid|other',
      );
    },
  );

  test(
    'offline restart hydrates committed absence before a stale widget may present',
    () async {
      final oldPermit = await binding.verification.verifyReport(
        candidate.bundle,
        candidate.report,
      );
      final installed = await testInstallBundle(
        binding.installations,
        candidate.bundle,
        expectedScopeKey: binding.installations.scopeKey,
        expectedCurrentCandidateDigest: null,
        permit: oldPermit,
        verificationReport: candidate.report,
      );
      await binding.persistInstalled(installed, 'self');
      final runtime = SurfaceRuntime();
      // No committed discovery yet is unknown, not an empty owner list.
      await runtime.showInstalledBundle(
        installed,
        permit: oldPermit,
        hostServices: binding.hostServices,
      );
      expect(runtime.document.value, isNotNull);
      await runtime.close();
      await binding.repository.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson({
          'schemaVersion': 2,
          'projects': <Object?>[],
        }),
        expectedScopeKey: 'test|owner',
      );
      expect(
        await database.getAllWidgets(),
        hasLength(1),
        reason: 'simulate a crash before the pointer cleanup callback',
      );
      await binding.deactivateAndDrain();
      binding = ProjectBuildHostBinding(
        database: database,
        accountScope: AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'owner',
        ),
        applicationSupportRoot: directory,
        creatorScope: 'test|owner',
        appletScope: appletScope,
        configuration: configuration,
        jobs: jobs,
        baseUri: Uri.parse('https://example.invalid/'),
        accessToken: () async => 'synthetic',
        isCurrent: () => current,
        isForeground: () => foreground,
        authorizeCloudText: () async {},
        runtimeForAgent: (_) => null,
        currentAppletScope: () => appletScope,
        httpClient: MockClient((request) async {
          requests.add(request);
          throw http.ClientException('offline');
        }),
      );
      final reopened = await binding.installations.openCandidate(
        candidate.bundle.candidateDigest,
        expectedScopeKey: binding.installations.scopeKey,
      );
      final permit = await binding.verification.verifyReport(
        reopened!.bundle,
        reopened.verificationReport,
      );
      await expectLater(
        runtime.showInstalledBundle(
          reopened,
          permit: permit,
          hostServices: binding.hostServices,
        ),
        throwsStateError,
      );
      expect(runtime.document.value, isNull);
      expect(
        requests,
        isEmpty,
        reason: 'hydration uses only the existing local repository',
      );
      expect(await database.getAllWidgets(), hasLength(1));
      expect(
        await binding.installations.openCandidate(
          candidate.bundle.candidateDigest,
          expectedScopeKey: binding.installations.scopeKey,
        ),
        isNotNull,
      );
      await runtime.showInstalledBundle(
        reopened,
        permit: permit,
        hostServices: binding.hostServices,
        preview: true,
      );
      expect(runtime.document.value, isNotNull);
      await runtime.close();
    },
  );

  test(
    'trusted configuration is bounded, immutable and development isolation cannot escape debug',
    () {
      final release = ProjectBuildHostConfiguration.parse(
        enableCreation: true,
        trustedKeysBase64: base64Encode(
          utf8.encode(jsonEncode(fixture['trustedVerifierKeys'])),
        ),
        debugBuild: false,
        allowDevelopmentIsolation: true,
      );
      expect(release.allowDevelopmentIsolation, isFalse);
      expect(() => release.trustedKeys.clear(), throwsUnsupportedError);
      expect(
        () => release.trustedKeys.values.first[0] = 0,
        throwsUnsupportedError,
      );
      expect(
        ProjectBuildHostConfiguration.parse(
          enableCreation: true,
          trustedKeysBase64: '',
          debugBuild: true,
        ).enableCreation,
        isFalse,
      );
      expect(
        () => ProjectBuildHostConfiguration.parse(
          enableCreation: true,
          trustedKeysBase64: 'not base64',
          debugBuild: true,
        ),
        throwsFormatException,
      );
      expect(
        () => ProjectBuildHostConfiguration.parse(
          enableCreation: true,
          trustedKeysBase64: 'x' * 25000,
          debugBuild: true,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'construction never sends a request; only fresh server readiness enables creation',
    () async {
      expect(requests, isEmpty);
      expect(binding.tasks.canSubmit, isFalse);
      await binding.refreshReadiness();
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path, '/v1/project-builds/v2/readiness');
      expect(binding.tasks.canSubmit, isTrue);
      now = now.add(const Duration(seconds: 31));
      expect(binding.tasks.canSubmit, isFalse);
      workerReady = false;
      await binding.refreshReadiness();
      expect(binding.tasks.canSubmit, isFalse);
    },
  );
  test(
    'same-account origin changes revoke readiness before any additional token or request',
    () async {
      await binding.refreshReadiness();
      expect(binding.creationReady, isTrue);
      appletScope = 'https://changed.invalid|owner';
      expect(binding.creationReady, isFalse);
      await binding.refreshReadiness();
      expect(requests, hasLength(1));
    },
  );
  test(
    'a retired account cannot receive delayed readiness or resume dispatch',
    () async {
      delayed = Completer<http.Response>();
      final operation = binding.refreshReadiness();
      await Future<void>.delayed(Duration.zero);
      current = false;
      delayed!.complete(response(readiness()));
      await operation;
      expect(binding.creationReady, isFalse);
      expect(binding.tasks.canSubmit, isFalse);
    },
  );
  test(
    'preview creates no widget; accepted pointer persistence is scoped and idempotent',
    () async {
      final staged = await binding.installations.stageCandidate(
        candidate.bundle,
        expectedScopeKey: binding.installations.scopeKey,
        verificationReport: candidate.report,
      );
      expect(await database.getAllWidgets(), isEmpty);
      await expectLater(
        binding.persistInstalled(staged, 'self'),
        throwsStateError,
      );
      final installed = await testInstallBundle(
        binding.installations,
        candidate.bundle,
        expectedScopeKey: binding.installations.scopeKey,
        expectedCurrentCandidateDigest: null,
        verificationReport: candidate.report,
        permit: await binding.verification.verifyReport(
          candidate.bundle,
          candidate.report,
        ),
      );
      await Future.wait([
        binding.persistInstalled(installed, 'self'),
        binding.persistInstalled(installed, 'self'),
      ]);
      final records = await database.getAllWidgets();
      expect(records, hasLength(1));
      expect(AppletLocalOwnership.storedScopeKey(records.single), appletScope);
      expect(records.single.kind, 'surface');
      expect(records.single.spec['rendering'], 'projectBundle');
      final pointer = records.single.spec['bundleReference']! as Map;
      expect(
        pointer.keys,
        unorderedEquals([
          'packageSchema',
          'projectId',
          'revisionId',
          'candidateDigest',
          'reportDigest',
        ]),
      );
      expect(pointer['candidateDigest'], candidate.bundle.candidateDigest);
      expect(records.single.spec.containsKey('html'), isFalse);
      expect(records.single.spec.containsKey('initialData'), isFalse);
      expect(binding.repository.scopeKey, 'test|owner');
      expect(binding.hostServices.playService!.scopeKey, 'test|owner');
      expect(
        binding.hostServices.previewPlayService!.scopeKey,
        'test|owner|preview',
      );
      current = false;
      await expectLater(
        binding.persistInstalled(installed, 'self'),
        throwsStateError,
      );
      expect(await database.getAllWidgets(), hasLength(1));
    },
  );
  test(
    'owned inventory reconciliation only removes v2 pointers in the mounted scope',
    () async {
      final installed = await testInstallBundle(
        binding.installations,
        candidate.bundle,
        expectedScopeKey: binding.installations.scopeKey,
        expectedCurrentCandidateDigest: null,
        verificationReport: candidate.report,
        permit: await binding.verification.verifyReport(
          candidate.bundle,
          candidate.report,
        ),
      );
      await binding.persistInstalled(installed, 'self');
      final other = binding.widgetFor(
        installed,
        reportDigest: candidate.reference.reportDigest,
        agentId: 'self',
      );
      AppletLocalOwnership.stamp(
        other,
        scopeKey: 'https://example.invalid|other',
      );
      await database.saveAgentWidget(other);
      await binding.reconcileOwnedProjects({});
      final remaining = await database.getAllWidgets();
      expect(remaining, hasLength(1));
      expect(
        AppletLocalOwnership.storedScopeKey(remaining.single),
        'https://example.invalid|other',
      );
    },
  );
}
