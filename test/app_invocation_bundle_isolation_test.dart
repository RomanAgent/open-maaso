import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_store.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_bundle_install_authority.dart';
import 'support/project_bundle_v2_fixture.dart';
import 'support/project_bundle_verified_fixture.dart';
import 'support/surface_play_example_factory_fixture.dart';

ValidatedProjectBundleV2 _withCurrentSdk(ValidatedProjectBundleV2 original) {
  final sdk = File(
    'assets/project_runtime/maaso_project_sdk_v2.js',
  ).readAsStringSync();
  final source = utf8.decode(original.files['src/main.js']!);
  final css = utf8.decode(original.files['src/styles.css']!);
  final runtime =
      '<!doctype html><html><head><meta charset="utf-8">'
      '<style>$css</style></head><body><main id="maaso-project-root"></main>'
      '<script>globalThis.__MAASO_CONFIG__=__MAASO_CONFIG_JSON__;</script>'
      '<script>$sdk</script><script>$source</script></body></html>';
  final files = [
    for (final file in original.manifest.files)
      ProjectBundleV2File(
        path: file.path,
        mimeType: file.mimeType,
        role: file.role,
        bytes: file.path == 'dist/index.html'
            ? utf8.encode(runtime)
            : original.files[file.path]!,
      ),
  ];
  final manifest = original.manifest;
  return const ProjectBundleV2Codec().verify(
    ProjectBundleV2Manifest.create(
      projectId: manifest.projectId,
      revisionId: manifest.revisionId,
      contentManifestId: manifest.contentManifestId,
      requirementRevision: manifest.requirementRevision,
      requirementDigest: manifest.requirementDigest,
      baseRevision: manifest.baseRevision,
      projectKind: manifest.projectKind,
      files: files.map((file) => file.metadata),
    ),
    files,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DBService database;
  late ProjectBundleInstallationStore installations;
  late AppInvocationStore journal;
  final presentations = <SurfaceBundlePresentation>[];
  final games = <SurfacePlayService>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('invocation-bundle-');
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: directory.path,
    );
    installations = ProjectBundleInstallationStore(
      database: database.raw,
      accountScope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'owner',
      ),
      applicationSupportRoot: directory,
      projectBuildScopeKey: 'test|owner',
      isCurrent: () => true,
    );
    journal = AppInvocationStore(
      database: database.raw,
      scopeKey: 'test|owner',
      mountId: 'mount-one',
      processId: 'process-one',
      isCurrent: () => true,
    );
  });
  tearDown(() async {
    for (final host in presentations) {
      await host.close();
    }
    presentations.clear();
    for (final game in games) {
      await game.deactivateAndDrain();
    }
    games.clear();
    await journal.deactivateAndDrain();
    await installations.deactivateAndDrain();
    await database.close();
    await directory.delete(recursive: true);
  });
  Future<AppInvocationRunRecord> admit(
    ValidatedProjectBundleV2 bundle,
    String token,
  ) => journal.admit(
    submissionToken: token,
    turnId: 'turn-one',
    sessionId: 'self',
    descriptor: AppInvocationDescriptor.fromValidatedBundle(
      bundle: bundle,
      scopeKey: 'test|owner',
    ),
    adapterId: 'native-test',
    adapterVersion: '1',
    inputDigest: 'a' * 64,
    canContinue: () => true,
  );

  test(
    'actual bundle data_save never writes installed or preview data in an invocation',
    () async {
      final bundle = _withCurrentSdk(productionBundleFixture());
      final source = const ProjectBundleV2Codec().encode(bundle);
      final auth = await testBundlePermit(bundle);
      final installed = await testInstallBundle(
        installations,
        bundle,
        expectedScopeKey: installations.scopeKey,
        expectedCurrentCandidateDigest: null,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      for (final role in ProjectBundleDataRole.values) {
        await installations.saveApplicationData(
          bundle.candidateDigest,
          {'done': false},
          expectedScopeKey: installations.scopeKey,
          role: role,
          expectedDataVersion: 0,
        );
      }
      final a = await admit(bundle, 'submission-A');
      final b = await admit(bundle, 'submission-B');
      final dataA = journal.applicationDataPort(
        a.invocationId,
        canContinue: () => true,
      );
      final dataB = journal.applicationDataPort(
        b.invocationId,
        canContinue: () => true,
      );
      final host = await SurfaceBundlePresentation.prepare(
        installed: installed,
        permit: auth.permit,
        services: SurfaceBundleHostServices(
          installations: installations,
          verifier: auth.verifier,
          invocationData: dataA,
        ),
        sessionId: 'invocation-host',
        isCurrent: () => true,
      );
      presentations.add(host);
      final response = await host.handle(
        jsonEncode({
          'nonce': host.nonce,
          'sessionId': host.sessionId,
          'projectId': bundle.manifest.projectId,
          'revisionId': bundle.manifest.revisionId,
          'candidateDigest': bundle.candidateDigest,
          'id': '1',
          'operation': 'data_save',
          'payload': {
            'values': {'done': true},
            'expectedDataVersion': 0,
          },
        }),
      );
      expect(response!.error, isNull);
      expect(response.result, {'dataVersion': 1});
      expect((await dataA.read()).values, {'done': true});
      expect((await dataB.read()).values, isEmpty);
      for (final role in ProjectBundleDataRole.values) {
        final original = await installations.readApplicationData(
          bundle.candidateDigest,
          expectedScopeKey: installations.scopeKey,
          role: role,
        );
        expect(original.version, 1);
        expect(original.values, {'done': false});
      }
      final unchanged = await installations.openCurrent(
        bundle.manifest.projectId,
        expectedScopeKey: installations.scopeKey,
      );
      expect(unchanged!.candidateDigest, installed.candidateDigest);
      expect(unchanged.headVersion, installed.headVersion);
      expect(const ProjectBundleV2Codec().encode(bundle), source);
    },
  );

  test(
    'native game invocation has its own latest pointer, match, seat and checkpoint',
    () async {
      final template = productionBundleFixture();
      final bundle = _withCurrentSdk(
        SurfacePlayExampleFactory.build(
          projectId: template.manifest.projectId,
          revisionId: template.manifest.revisionId,
          contentManifestId: template.manifest.contentManifestId,
          requirementDigest: template.manifest.requirementDigest,
          rulesId: 'cooperative-switches.v1',
        ),
      );
      final source = const ProjectBundleV2Codec().encode(bundle);
      final auth = await testBundlePermit(bundle);
      final installed = await testInstallBundle(
        installations,
        bundle,
        expectedScopeKey: installations.scopeKey,
        expectedCurrentCandidateDigest: null,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      final manualStore = SurfacePlayStore(
        database: database,
        scopeKey: 'manual-game',
        projectBuildScopeKey: 'test|owner',
        isCurrent: () => true,
      );
      final manual = SurfacePlayService(
        scopeKey: 'manual-game',
        projectBuildScopeKey: 'test|owner',
        persistence: manualStore,
        isCurrent: () => true,
      );
      games.add(manual);
      final original = await manual.openSession(
        protocol: bundle.protocol,
        sessionId: 'manual-session',
        newMatch: true,
        agentId: 'self',
        contentManifestId: bundle.manifest.contentManifestId,
        protocolJson: utf8.decode(bundle.files['agent.protocol.json']!),
        agentDocument: bundle.agentMarkdown,
        isPresentationCurrent: () => true,
      );
      final before = await manualStore.load(original.matchId);
      final latest = await manualStore.latestMatchId(
        projectId: bundle.manifest.projectId,
        revisionId: bundle.manifest.revisionId,
      );
      final run = await admit(bundle, 'game-submission');
      final isolatedStore = SurfacePlayStore(
        database: database,
        scopeKey: 'invocation:${run.invocationId}',
        projectBuildScopeKey: 'test|owner',
        isCurrent: () => true,
      );
      final isolated = SurfacePlayService(
        scopeKey: isolatedStore.scopeKey,
        projectBuildScopeKey: 'test|owner',
        persistence: isolatedStore,
        isCurrent: () => true,
        authorizeAgentControl: (_, _) async => true,
      );
      games.add(isolated);
      final host = await SurfaceBundlePresentation.prepare(
        installed: installed,
        permit: auth.permit,
        services: SurfaceBundleHostServices(
          installations: installations,
          verifier: auth.verifier,
          playService: manual,
          agentId: 'self',
          invocationPlayService: isolated,
          invocationData: journal.applicationDataPort(
            run.invocationId,
            canContinue: () => true,
          ),
        ),
        sessionId: 'isolated-host',
        isCurrent: () => true,
      );
      presentations.add(host);
      expect(manual.activeSession, same(original));
      final active = isolated.activeSession!;
      expect(active.matchId, isNot(original.matchId));
      final grant = await active.grantAgentControl();
      final observation = active.observe(grant);
      expect(observation.legalActions, isNotEmpty);
      final outcome = await active.submit(
        grant,
        observation.commandFor(
          observation.legalActions.first,
          requestId: 'isolated-move',
        ),
      );
      expect(outcome.status, SurfacePlayReceiptStatus.applied);
      expect(await manualStore.load(original.matchId), before);
      expect(
        await manualStore.latestMatchId(
          projectId: bundle.manifest.projectId,
          revisionId: bundle.manifest.revisionId,
        ),
        latest,
      );
      expect(
        await isolatedStore.latestMatchId(
          projectId: bundle.manifest.projectId,
          revisionId: bundle.manifest.revisionId,
        ),
        active.matchId,
      );
      expect(const ProjectBundleV2Codec().encode(bundle), source);
      expect(
        (await installations.openCurrent(
          bundle.manifest.projectId,
          expectedScopeKey: installations.scopeKey,
        ))!.candidateDigest,
        installed.candidateDigest,
      );
    },
  );
}
