import 'support/project_bundle_install_authority.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'support/surface_play_example_factory_fixture.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_document.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:sembast/sembast_io.dart';
import 'support/project_bundle_v2_fixture.dart';
import 'support/project_bundle_verified_fixture.dart';
import 'project_bundle_deletion_test.dart' show deletionProof;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Database db;
  late ProjectBundleInstallationStore store;
  final scope = AccountStorageScope(environmentKey: 'test', accountUuid: 'one');
  var current = true;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bundle-host-');
    db = await databaseFactoryIo.openDatabase('${dir.path}/db');
    current = true;
    store = ProjectBundleInstallationStore(
      projectBuildScopeKey: 'test|owner',
      database: db,
      accountScope: scope,
      applicationSupportRoot: dir,
      isCurrent: () => current,
    );
  });
  tearDown(() async {
    await store.deactivateAndDrain();
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'complete inventory retires saved views, preserves preview, and deletion clears its document',
    () async {
      final bundle = productionBundleFixture();
      final auth = await testBundlePermit(bundle);
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      final runtime = SurfaceRuntime();
      final services = SurfaceBundleHostServices(
        installations: store,
        verifier: auth.verifier,
      );
      final oldProof = await testOwnedBundleProof(
        bundle,
        auth.permit.reportDigest,
        scopeKey: 'test|owner',
        headVersion: installed.headVersion!,
      );
      await runtime.showInstalledBundle(
        installed,
        permit: auth.permit,
        hostServices: services,
      );
      expect(runtime.document.value, isNotNull);
      store.reconcileOwnedPresentations({}, expectedScopeKey: store.scopeKey);
      expect(runtime.document.value, isNull);
      expect(runtime.isVisible.value, isFalse);
      await expectLater(
        runtime.showInstalledBundle(
          installed,
          permit: auth.permit,
          hostServices: services,
        ),
        throwsStateError,
      );
      await store.install(
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: bundle.candidateDigest,
        expectedHeadVersion: installed.headVersion,
        expectedProjectBuildScopeKey: 'test|owner',
        ownedRevision: oldProof,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      final adopted = await store.adoptCurrentHead(
        oldProof,
        expectedScopeKey: store.scopeKey,
        expectedProjectBuildScopeKey: 'test|owner',
        permit: auth.permit,
        verificationReport: auth.report,
      );
      await expectLater(
        runtime.showInstalledBundle(
          adopted,
          permit: auth.permit,
          hostServices: services,
        ),
        throwsStateError,
        reason: 'a cached proof is not a new complete owner inventory',
      );
      expect(
        (await store.openCandidate(
          bundle.candidateDigest,
          expectedScopeKey: store.scopeKey,
        ))!.candidateDigest,
        bundle.candidateDigest,
        reason: 'absence revokes presentation, not immutable offline cache',
      );
      store.reconcileOwnedPresentations({
        bundle.manifest.projectId,
      }, expectedScopeKey: store.scopeKey);
      await runtime.showInstalledBundle(
        installed,
        permit: auth.permit,
        hostServices: services,
      );
      expect(runtime.document.value, isNotNull);
      store.reconcileOwnedPresentations({}, expectedScopeKey: store.scopeKey);
      await runtime.showInstalledBundle(
        installed,
        permit: auth.permit,
        hostServices: services,
        preview: true,
      );
      store.reconcileOwnedPresentations({}, expectedScopeKey: store.scopeKey);
      expect(runtime.document.value, isNotNull);
      final proof = await deletionProof(bundle);
      final purge = store.purgeDeletedProject(
        proof,
        expectedScopeKey: store.scopeKey,
        expectedProjectBuildScopeKey: 'test|owner',
      );
      expect(runtime.document.value, isNull);
      expect(runtime.isVisible.value, isFalse);
      await purge;
      await runtime.close();
    },
  );

  test(
    'initial navigation never admits remote, data or blob URLs while loading',
    () {
      const expected = 'https://session.maaso-bundle.invalid/session/1/';
      for (final source in [
        'https://example.com',
        'data:text/html,x',
        'blob:https://example.com/x',
        '$expected?reload=1',
      ]) {
        expect(
          surfaceBundleAllowsInitialNavigation(
            source: source,
            expectedDocument: expected,
            loading: true,
            allowInitial: true,
          ),
          isFalse,
        );
      }
      expect(
        surfaceBundleAllowsInitialNavigation(
          source: expected,
          expectedDocument: expected,
          loading: false,
          allowInitial: true,
        ),
        isTrue,
      );
      expect(
        surfaceBundleAllowsInitialNavigation(
          source: expected,
          expectedDocument: expected,
          loading: true,
          allowInitial: false,
        ),
        isFalse,
      );
    },
  );

  test('CSP hashes exact assembled scripts, only declared assets, safe JSON', () {
    final bundle = productionBundleFixture();
    final source = SurfaceBundleDocument.build(
      bundle: bundle,
      nonce: 'N' * 32,
      sessionId: 'session-1',
      initialData: {'text': '</script>\u2028\u2029'},
      dataVersion: 0,
    );
    final doc = html.parse(source);
    final policy = doc
        .querySelector('meta[http-equiv]')!
        .attributes['content']!;
    expect(policy, contains("connect-src 'none'"));
    expect(policy, contains("worker-src 'none'"));
    expect(policy, isNot(contains("script-src 'unsafe-inline'")));
    expect(policy, isNot(contains('unsafe-eval')));
    for (final script in doc.querySelectorAll('script')) {
      expect(
        policy,
        contains(
          "'sha256-${base64Encode(sha256.convert(utf8.encode(script.text)).bytes)}'",
        ),
      );
    }
    expect(source, contains(r'\u003c/script>\u2028\u2029'));
    expect(source, contains('data:image/png;base64,'));
    expect(source, isNot(contains('__MAASO_CONFIG_JSON__')));
    expect(doc.querySelectorAll('iframe,object,embed,base,link'), isEmpty);
  });

  test('JSON cannot forge v2; old show rejects a copied project', () async {
    expect(
      () => SurfaceProject.fromJson({'rendering': 'projectBundle'}),
      throwsFormatException,
    );
    expect(
      () =>
          SurfaceProject.fromJson({'rendering': 'dom', 'bundleReference': {}}),
      throwsFormatException,
    );
    final bundle = productionBundleFixture();
    final auth = await testBundlePermit(bundle);
    final installed = await testInstallBundle(
      store,
      bundle,
      expectedScopeKey: store.scopeKey,
      expectedCurrentCandidateDigest: null,
      verificationReport: auth.report,
      permit: auth.permit,
    );
    final runtime = SurfaceRuntime();
    await runtime.showInstalledBundle(
      installed,
      permit: auth.permit,
      hostServices: SurfaceBundleHostServices(
        installations: store,
        verifier: auth.verifier,
      ),
    );
    final project = runtime.activeProject.value!;
    expect(project.html, isEmpty);
    expect(project.toJson()['html'], '');
    expect(project.toJson(), isNot(contains('nonce')));
    expect(project.toJson()['bundleReference'], isA<Map>());
    expect(runtime.manifestForPrompt(), isEmpty);
    final events = <SurfaceEvent>[];
    final subscription = runtime.onEvent.listen(events.add);
    runtime.onPageEvent('legacy.event', {'private': 'blocked'});
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    await subscription.cancel();
    expect(
      runtime.preflightCall('app.navigate', {'routeId': 'details'}),
      contains('typed operation'),
    );
    await expectLater(runtime.show(project), throwsA(isA<Exception>()));
    await runtime.close();
  });

  test(
    'bridge writes bounded CAS data and rejects wrong identity and stale sessions',
    () async {
      final bundle = productionBundleFixture();
      final auth = await testBundlePermit(bundle, isCurrent: () => current);
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      final presentation = await SurfaceBundlePresentation.prepare(
        installed: installed,
        permit: auth.permit,
        services: SurfaceBundleHostServices(
          installations: store,
          verifier: auth.verifier,
        ),
        sessionId: 'session-1',
        isCurrent: () => current,
      );
      Map<String, Object?> request(int version) => {
        'nonce': presentation.nonce,
        'sessionId': 'session-1',
        'projectId': bundle.manifest.projectId,
        'revisionId': bundle.manifest.revisionId,
        'candidateDigest': bundle.candidateDigest,
        'id': '1',
        'operation': 'data_save',
        'payload': {
          'values': {'done': true},
          'expectedDataVersion': version,
        },
      };
      final wrong = request(0)..['sessionId'] = 'session-other';
      expect(await presentation.handle(jsonEncode(wrong)), isNull);
      expect((await presentation.handle(jsonEncode(request(0))))!.result, {
        'dataVersion': 1,
      });
      expect(
        (await presentation.handle(jsonEncode(request(0))))!.error,
        'bundle_operation_failed',
      );
      expect(
        (await store.readApplicationData(
          bundle.candidateDigest,
          expectedScopeKey: store.scopeKey,
          role: ProjectBundleDataRole.installed,
        )).values,
        {'done': true},
      );
      current = false;
      expect(await presentation.handle(jsonEncode(request(1))), isNull);
      await presentation.close();
    },
  );

  test(
    'native document rotation prevents a queued old-page data commit and restores only durable data',
    () async {
      final bundle = productionBundleFixture();
      final auth = await testBundlePermit(bundle);
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      final presentation = await SurfaceBundlePresentation.prepare(
        installed: installed,
        permit: auth.permit,
        services: SurfaceBundleHostServices(
          installations: store,
          verifier: auth.verifier,
        ),
        sessionId: 'original-session',
        isCurrent: () => current,
      );
      final prior = {
        'nonce': presentation.nonce,
        'sessionId': presentation.sessionId,
        'projectId': bundle.manifest.projectId,
        'revisionId': bundle.manifest.revisionId,
        'candidateDigest': bundle.candidateDigest,
        'id': '1',
        'operation': 'data_save',
        'payload': {
          'values': {'late': true},
          'expectedDataVersion': 0,
        },
      };
      final gate = Completer<void>(), entered = Completer<void>();
      final locked = db.transaction((tx) async {
        entered.complete();
        await gate.future;
      });
      await entered.future;
      final saving = presentation.handle(jsonEncode(prior));
      presentation.fenceAppletDocument();
      final restoring = presentation.restoreAppletDocument();
      expect(presentation.isCurrent, isFalse);
      gate.complete();
      await locked;
      await saving;
      await restoring;
      expect(
        (await store.readApplicationData(
          bundle.candidateDigest,
          expectedScopeKey: store.scopeKey,
          role: ProjectBundleDataRole.installed,
        )).values,
        isEmpty,
      );
      expect(await presentation.handle(jsonEncode(prior)), isNull);
      expect(presentation.document, isNot(contains('"late":true')));
      await presentation.close();
    },
  );

  test(
    'installed account and exact candidate must match the injected host',
    () async {
      final bundle = productionBundleFixture();
      final auth = await testBundlePermit(bundle);
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      final other = ProjectBundleInstallationStore(
        database: db,
        accountScope: AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'other',
        ),
        applicationSupportRoot: dir,
        isCurrent: () => true,
      );
      await expectLater(
        SurfaceBundlePresentation.prepare(
          installed: installed,
          permit: auth.permit,
          services: SurfaceBundleHostServices(
            installations: other,
            verifier: auth.verifier,
          ),
          sessionId: 's',
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      final second = await testBundlePermit(
        productionBundleFixture(revision: 3),
      );
      await expectLater(
        SurfaceBundlePresentation.prepare(
          installed: installed,
          permit: second.permit,
          services: SurfaceBundleHostServices(
            installations: store,
            verifier: second.verifier,
          ),
          sessionId: 's',
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      await other.deactivateAndDrain();
    },
  );
  test(
    'play bridge fixes human seat, refreshes rejected receipts, hides opponent-only timing',
    () async {
      final template = productionBundleFixture();
      final example = SurfacePlayExampleFactory.build(
        projectId: template.manifest.projectId,
        revisionId: template.manifest.revisionId,
        contentManifestId: template.manifest.contentManifestId,
        requirementDigest: template.manifest.requirementDigest,
        rulesId: 'private-cards.v1',
      );
      final files = [
        for (final m in example.manifest.files)
          ProjectBundleV2File(
            path: m.path,
            mimeType: m.mimeType,
            role: m.role,
            bytes: m.role == ProjectBundleV2FileRole.runtime
                ? template.files['dist/index.html']!
                : example.files[m.path]!,
          ),
      ];
      final manifest = ProjectBundleV2Manifest.create(
        projectId: example.manifest.projectId,
        revisionId: example.manifest.revisionId,
        contentManifestId: example.manifest.contentManifestId,
        requirementRevision: 1,
        requirementDigest: example.manifest.requirementDigest,
        baseRevision: null,
        projectKind: 'game',
        files: files.map((f) => f.metadata),
      );
      final bundle = const ProjectBundleV2Codec().verify(manifest, files);
      final auth = await testBundlePermit(bundle);
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
      );
      final playDb = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'host-play',
      );
      final play = SurfacePlayService(
        scopeKey: 'test|one',
        persistence: SurfacePlayStore(
          database: playDb,
          scopeKey: 'test|one',
          isCurrent: () => current,
        ),
        isCurrent: () => current,
      );
      final presentation = await SurfaceBundlePresentation.prepare(
        installed: installed,
        permit: auth.permit,
        services: SurfaceBundleHostServices(
          installations: store,
          verifier: auth.verifier,
          playService: play,
          agentId: 'self',
        ),
        sessionId: 'session-game',
        isCurrent: () => current,
      );
      final pushed = <String>[];
      presentation.attach((js) async {
        pushed.add(js);
      });
      Map<String, Object?> envelope(String op, Map<String, Object?> payload) =>
          {
            'nonce': presentation.nonce,
            'sessionId': presentation.sessionId,
            'projectId': bundle.manifest.projectId,
            'revisionId': bundle.manifest.revisionId,
            'candidateDigest': bundle.candidateDigest,
            'id': '1',
            'operation': op,
            'payload': payload,
          };
      final session = play.activeSession!;
      final other = session.observeHuman(seatId: 'player2');
      await session.submitHuman(
        other.commandFor(other.legalActions.first, requestId: 'other-private'),
        seatId: 'player2',
      );
      expect(
        pushed,
        isEmpty,
        reason: 'opponent-only commits do not refresh human tokens',
      );
      final human = session.observeHuman();
      final command = human
          .commandFor(human.legalActions.first, requestId: 'human-1')
          .toJson();
      final forged = Map<String, Object?>.from(command)..['seatId'] = 'player2';
      expect(
        (await presentation.handle(
          jsonEncode(envelope('play_submit', forged)),
        ))!.error,
        isNotNull,
      );
      expect(
        pushed,
        isNotEmpty,
        reason: 'rejected commands refresh observation even without a commit',
      );
      pushed.clear();
      final absent = await presentation.handle(
        jsonEncode(envelope('play_receipt', {'requestId': 'never-submitted'})),
      );
      expect(absent!.result, isNull);
      expect(absent.error, isNull);
      expect(pushed, hasLength(1));
      await session.pause();
      expect(presentation.paused, isTrue);
      await presentation.resume();
      expect(presentation.paused, isFalse);
      expect(presentation.humanSeat, 'player1');
      await presentation.close();
      await play.deactivateAndDrain();
      await playDb.close();
    },
  );
}
