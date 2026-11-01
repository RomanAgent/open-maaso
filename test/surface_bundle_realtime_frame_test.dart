import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_bundle_presentation.dart';
import 'package:maaso/src/features/project_build/data/project_bundle_installation_store.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_agent_document.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'support/surface_play_example_factory_fixture.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/project_bundle_install_authority.dart';
import 'support/project_bundle_v2_fixture.dart';
import 'support/project_bundle_verified_fixture.dart';

// Boundary fixture: native rules and signed test permit are exercised. The
// renderer is a captured JS transport, not a visual acceptance claim.
ValidatedProjectBundleV2 frameBundle() {
  final template = productionBundleFixture();
  final base = SurfacePlayExampleFactory.build(
    projectId: template.manifest.projectId,
    revisionId: template.manifest.revisionId,
    contentManifestId: template.manifest.contentManifestId,
    requirementDigest: template.manifest.requirementDigest,
    rulesId: 'private-cards.v1',
  );
  final protocol = SurfacePlayProtocol.fromJson(
    Map<String, Object?>.from(
      jsonDecode(
            File(
              'tool/fixtures/surface_play_realtime_protocol_v2.json',
            ).readAsStringSync(),
          )
          as Map,
    ),
  );
  final protocolJson = jsonEncode(protocol.toJson());
  final doc = buildSurfacePlayAgentDocument(
    protocol: protocol,
    contentManifestId: base.manifest.contentManifestId,
    protocolSha256: surfaceProtocolDigest(protocolJson),
  );
  final files = [
    for (final entry in base.manifest.files)
      ProjectBundleV2File(
        path: entry.path,
        mimeType: entry.mimeType,
        role: entry.role,
        bytes: switch (entry.path) {
          'agent.protocol.json' => utf8.encode(protocolJson),
          'agent.md' => utf8.encode(doc),
          'dist/index.html' => template.files['dist/index.html']!,
          _ => base.files[entry.path]!,
        },
      ),
  ];
  return const ProjectBundleV2Codec().verify(
    ProjectBundleV2Manifest.create(
      projectId: base.manifest.projectId,
      revisionId: base.manifest.revisionId,
      contentManifestId: base.manifest.contentManifestId,
      requirementRevision: 1,
      requirementDigest: base.manifest.requirementDigest,
      baseRevision: null,
      projectKind: 'game',
      files: files.map((f) => f.metadata),
    ),
    files,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'only human frames cross the bridge; coalescing never blocks reliable state and hidden view pauses native rules',
    () async {
      final directory = await Directory.systemTemp.createTemp('frame-host-');
      final db = await databaseFactoryIo.openDatabase(
        '${directory.path}/bundle.db',
      );
      final playDb = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'frame-host-play',
      );
      final store = ProjectBundleInstallationStore(
        database: db,
        accountScope: AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'owner',
        ),
        projectBuildScopeKey: 'test|owner',
        applicationSupportRoot: directory,
        isCurrent: () => true,
      );
      final bundle = frameBundle(),
          auth = await testBundlePermit(frameBundle());
      final installed = await testInstallBundle(
        store,
        bundle,
        expectedScopeKey: store.scopeKey,
        expectedCurrentCandidateDigest: null,
        permit: auth.permit,
        verificationReport: auth.report,
      );
      final play = SurfacePlayService(
        scopeKey: 'test|owner',
        isCurrent: () => true,
        persistence: SurfacePlayStore(
          database: playDb,
          scopeKey: 'test|owner',
          isCurrent: () => true,
        ),
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
        sessionId: 'frame-native-session',
        isCurrent: () => true,
      );
      var visible = true;
      final frames = <Map<String, Object?>>[], reliable = <String>[];
      Completer<void>? gate = Completer<void>();
      var inFlight = 0, maximumInFlight = 0;
      presentation.attach((source) async {
        if (!source.contains('updatePlayFrame(')) {
          reliable.add(source);
          return;
        }
        inFlight++;
        if (inFlight > maximumInFlight) maximumInFlight = inFlight;
        final start = source.indexOf(',') + 1;
        frames.add(
          Map<String, Object?>.from(
            jsonDecode(source.substring(start, source.length - 1)) as Map,
          ),
        );
        await gate?.future;
        inFlight--;
      }, isVisible: () => visible);
      try {
        final session = play.activeSession!;
        final before = session.observeHuman();
        await Future<void>.delayed(const Duration(milliseconds: 45));
        expect(frames, hasLength(1));
        expect(frames.single['seatId'], 'player1');
        expect(frames.single.keys, isNot(contains('legalActions')));
        expect(
          session.observeHuman().toJson()['viewSequence'],
          before.toJson()['viewSequence'],
        );
        final start = session.observeHuman();
        await session.submitHuman(
          start.commandFor(start.legalActions.first, requestId: 'start-human'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 130));
        expect(
          reliable,
          isNotEmpty,
          reason: 'reliable observations do not wait for frame rendering',
        );
        expect(
          frames,
          hasLength(1),
          reason: 'one in flight, one latest, no render queue',
        );
        gate.complete();
        gate = null;
        await Future<void>.delayed(const Duration(milliseconds: 45));
        expect(frames.length, greaterThan(1));
        expect(maximumInFlight, 1);
        visible = false;
        presentation.visibleContextChanged();
        expect(
          session.isPaused,
          isTrue,
          reason: 'visibility loss fences inputs synchronously',
        );
        await Future<void>.delayed(const Duration(milliseconds: 90));
        expect(frames.last['phase'], 'paused');
        final tick = frames.last['simTick'], count = frames.length;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(frames.length, count);
        expect(session.currentFrameHuman()!.simTick, tick);
        visible = true;
        presentation.visibleContextChanged();
        expect(
          session.isPaused,
          isTrue,
          reason: 'visibility alone does not resume or regrant',
        );
      } finally {
        if (gate != null && !gate.isCompleted) gate.complete();
        await presentation.close();
        await play.deactivateAndDrain();
        await store.deactivateAndDrain();
        await playDb.close();
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
