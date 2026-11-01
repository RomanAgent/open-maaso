import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_delete.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_agent_document.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'positive delete receipt revokes live play and erases only matching owner/project including preview; late commit and restart stay fenced',
    () async {
      const scope = 'play-delete|owner';
      final raw = projectBuildV2Object(
        jsonDecode(
          File('tool/fixtures/project_head_v2_wire.json').readAsStringSync(),
        ),
      );
      final project = projectBuildV2Object(
        (projectBuildV2Object(raw['head4'])['projects']! as List).single,
      );
      final id = project['projectId']! as String;
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'delete-play-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(db.close);
      final repo = ProjectBuildV2Repository(
        database: db,
        scopeKey: scope,
        isCurrent: () => true,
      );
      await repo.recordOwnedProjects(
        ProjectBuildV2OwnedProjects.fromJson(raw['head4']),
        expectedScopeKey: scope,
      );
      await repo.prepareProjectDeletion(
        id,
        ProjectBuildV2DeleteRequest.fromJson(raw['deleteRequest']),
        expectedScopeKey: scope,
      );
      final services = <SurfacePlayService>[];
      final stores = <SurfacePlayStore>[];
      final sessions = <SurfacePlaySession>[];
      for (final key in [scope, '$scope|preview', 'other-owner']) {
        final store = SurfacePlayStore(
          database: db,
          scopeKey: key,
          projectBuildScopeKey: key == 'other-owner' ? key : scope,
          isCurrent: () => true,
        );
        final service = SurfacePlayService(
          scopeKey: key,
          projectBuildScopeKey: key == 'other-owner' ? key : scope,
          persistence: store,
          isCurrent: () => true,
          authorizeAgentControl: (_, _) async => true,
        );
        final protocol = SurfacePlayProtocol.trustedGame(
          projectId: id,
          revisionId: project['currentRevisionId']! as String,
          rulesId: 'private-cards.v1',
          config: {'cardsPerRole': 3},
        );
        final json = jsonEncode(protocol.toJson());
        final session = await service.openSession(
          protocol: protocol,
          sessionId: 'session-${services.length}',
          matchId: 'match-test',
          agentId: 'self',
          contentManifestId: 'content-test',
          protocolJson: json,
          agentDocument: buildSurfacePlayAgentDocument(
            protocol: protocol,
            contentManifestId: 'content-test',
            protocolSha256: surfaceProtocolDigest(json),
          ),
          isPresentationCurrent: () => true,
        );
        stores.add(store);
        services.add(service);
        sessions.add(session);
      }
      addTearDown(() async {
        for (final service in services) {
          await service.deactivateAndDrain();
        }
      });
      final observation = sessions.first.observeHuman();
      final command = observation.commandFor(
        observation.legalActions.first,
        requestId: 'late-request',
      );
      final cached = (await stores.first.load('match-test'))!;
      final proof = await repo.recordProjectDeletionReceipt(
        ProjectBuildV2DeleteReceipt.fromJson(raw['deleteReceipt']),
        expectedScopeKey: scope,
      );
      await services.first.purgeDeletedProject(
        proof,
        expectedProjectBuildScopeKey: scope,
      );
      await services[1].purgeDeletedProject(
        proof,
        expectedProjectBuildScopeKey: scope,
      );
      expect(sessions.first.isCurrent, isFalse);
      expect(services.first.activeSession, isNull);
      expect(await stores.first.load('match-test'), isNull);
      expect(await stores[1].load('match-test'), isNull);
      expect(await stores[2].load('match-test'), isNotNull);
      await expectLater(
        services[2].purgeDeletedProject(
          proof,
          expectedProjectBuildScopeKey: scope,
        ),
        throwsStateError,
      );
      await expectLater(sessions.first.submitHuman(command), throwsStateError);
      await expectLater(
        stores.first.commit(
          matchId: 'match-test',
          expectedCommitRevision: null,
          next: {...cached, 'commitRevision': 0},
          isAuthorized: () => true,
        ),
        throwsStateError,
      );
      final restarted = SurfacePlayStore(
        database: db,
        scopeKey: scope,
        projectBuildScopeKey: scope,
        isCurrent: () => true,
      );
      await expectLater(
        restarted.latestMatchId(
          projectId: id,
          revisionId: project['currentRevisionId']! as String,
        ),
        throwsStateError,
      );
      await services.first.purgeDeletedProject(
        proof,
        expectedProjectBuildScopeKey: scope,
      );
    },
  );
}
