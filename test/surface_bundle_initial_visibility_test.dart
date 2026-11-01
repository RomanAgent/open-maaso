import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'support/surface_play_example_factory_fixture.dart';
import 'support/project_bundle_verified_fixture.dart';
import 'support/project_bundle_v2_fixture.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DBService db;
  late ProjectBundleInstallationStore installations;
  late SurfacePlayService play;
  late SurfaceBundlePresentation presentation;
  var visible = true;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'signed-initial-visibility-',
    );
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: '${directory.path}/memory',
    );
    installations = ProjectBundleInstallationStore(
      database: db.raw,
      accountScope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'synthetic-visibility-owner',
      ),
      applicationSupportRoot: directory,
      isCurrent: () => true,
    );
    play = SurfacePlayService(
      scopeKey: 'owner|preview',
      projectBuildScopeKey: 'owner',
      persistence: SurfacePlayStore(
        database: db,
        scopeKey: 'owner|preview',
        projectBuildScopeKey: 'owner',
        isCurrent: () => true,
      ),
      isCurrent: () => true,
      authorizeAgentControl: (_, _) async => true,
    );
    final template = productionBundleFixture();
    final example = SurfacePlayExampleFactory.build(
      projectId: template.manifest.projectId,
      revisionId: template.manifest.revisionId,
      contentManifestId: template.manifest.contentManifestId,
      requirementDigest: template.manifest.requirementDigest,
      rulesId: 'gomoku.v1',
    );
    // The compiled SDK fixture supplies the bootstrap slot; the example keeps
    // the saved game protocol and its native human rules contract.
    final files = [
      for (final file in example.manifest.files)
        ProjectBundleV2File(
          path: file.path,
          mimeType: file.mimeType,
          role: file.role,
          bytes: file.role == ProjectBundleV2FileRole.runtime
              ? template.files['dist/index.html']!
              : example.files[file.path]!,
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
      files: files.map((file) => file.metadata),
    );
    final bundle = const ProjectBundleV2Codec().verify(manifest, files);
    final authority = await testBundlePermit(bundle);
    final staged = await installations.stageCandidate(
      bundle,
      expectedScopeKey: installations.scopeKey,
    );
    visible = true;
    presentation = await SurfaceBundlePresentation.prepare(
      installed: staged,
      permit: authority.permit,
      services: SurfaceBundleHostServices(
        installations: installations,
        verifier: authority.verifier,
        previewPlayService: play,
        agentId: 'self',
      ),
      sessionId: 'initial-visible-session',
      preview: true,
      isCurrent: () => true,
    );
  });
  tearDown(() async {
    await presentation.close();
    await play.deactivateAndDrain();
    await installations.deactivateAndDrain();
    await db.close();
    await directory.delete(recursive: true);
  });
  void attach() => presentation.attach(
    (_) async {},
    evaluateResult: (_) async => null,
    isVisible: () => visible,
  );
  Future<void> settle() async =>
      Future<void>.delayed(const Duration(milliseconds: 15));

  test(
    'pre-attach visibility notification does not pause the first visible game',
    () async {
      final session = play.activeSession!;
      final epoch = session.readDiagnostics()['matchEpoch'];
      expect(session.isPaused, isFalse);
      expect(
        presentation.controlIsVisible,
        isFalse,
        reason: 'unbound hosts still have no grant authority',
      );
      // SurfaceWebView.didChangeDependencies can run while its asynchronous
      // controller configuration has not attached the visible callback yet.
      presentation.visibleContextChanged();
      await settle();
      expect(session.isPaused, isFalse);
      expect(session.readDiagnostics()['matchEpoch'], epoch);
      attach();
      presentation.visibleContextChanged();
      await settle();
      expect(presentation.controlIsVisible, isTrue);
      expect(session.isPaused, isFalse);
      expect(session.readDiagnostics()['matchEpoch'], epoch);
      final view = session.observeHuman();
      final receipt = await session.submitHuman(
        view.commandFor(
          view.legalActions.first,
          requestId: 'first-visible-action',
        ),
      );
      expect(receipt.status, SurfacePlayReceiptStatus.applied);
    },
  );

  test(
    'an attached false visibility still fences immediately before any first frame',
    () async {
      final session = play.activeSession!;
      final grant = await session.grantAgentControl(seatId: 'spectator');
      final epoch = session.readDiagnostics()['matchEpoch']! as int;
      visible = false;
      attach();
      presentation.visibleContextChanged();
      expect(session.isPaused, isTrue);
      expect(session.grantIsCurrent(grant), isFalse);
      expect(session.readDiagnostics()['matchEpoch'], epoch + 1);
      await settle();
      visible = true;
      presentation.visibleContextChanged();
      await settle();
      expect(session.isPaused, isTrue);
      await presentation.resume();
      expect(session.isPaused, isFalse);
      expect(session.grantIsCurrent(grant), isFalse);
    },
  );

  test(
    'visible-to-hidden-to-visible remains paused until an explicit resume',
    () async {
      final session = play.activeSession!;
      attach();
      presentation.visibleContextChanged();
      final grant = await session.grantAgentControl(seatId: 'spectator');
      visible = false;
      presentation.visibleContextChanged();
      expect(session.isPaused, isTrue);
      expect(session.grantIsCurrent(grant), isFalse);
      await settle();
      visible = true;
      presentation.visibleContextChanged();
      await settle();
      expect(session.isPaused, isTrue);
      await presentation.resume();
      expect(session.isPaused, isFalse);
      expect(session.grantIsCurrent(grant), isFalse);
    },
  );

  test(
    'detach revokes before clearing transport and reattach cannot revive a grant',
    () async {
      final session = play.activeSession!;
      attach();
      final grant = await session.grantAgentControl(seatId: 'spectator');
      presentation.detach();
      expect(session.isPaused, isTrue);
      expect(session.grantIsCurrent(grant), isFalse);
      expect(presentation.controlIsVisible, isFalse);
      await settle();
      attach();
      presentation.visibleContextChanged();
      await settle();
      expect(session.isPaused, isTrue);
      await presentation.resume();
      expect(session.isPaused, isFalse);
      expect(session.grantIsCurrent(grant), isFalse);
    },
  );
}
