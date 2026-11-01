import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'project_build_v2_delivery_test.dart' as delivery;

Map<String, Object?> obj(Object? v) => projectBuildV2Object(v);
final fixture = obj(
  jsonDecode(
    File('tool/fixtures/project_head_v2_wire.json').readAsStringSync(),
  ),
);
String get projectId =>
    obj((obj(fixture['head4'])['projects']! as List).single)['projectId']!
        as String;
void setRemote(delivery.Harness h, int version) {
  h.head = 4;
  h.inventory['projects'] = fixture['head$version'];
  final all = obj(fixture['revisionsAfterFork']);
  final head = obj((obj(fixture['head$version'])['projects']! as List).single);
  final revisions = (all['revisions']! as List)
      .where(
        (v) =>
            version == 4 ||
            obj(v)['revisionId'] !=
                obj(fixture['thirdRevisionDocument'])['revisionId'],
      )
      .toList();
  h.inventory['revisions'] = {
    ...all,
    'currentHeadVersion': version,
    'currentRevisionId': head['currentRevisionId'],
    'revisions': revisions,
  };
  for (final key in [
    'firstRevisionDocument',
    'secondRevisionDocument',
    'thirdRevisionDocument',
  ]) {
    final doc = obj(fixture[key]);
    h.documents[doc['revisionId']! as String] = doc;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'rollback ACK loss replays original nonce after restart and installs authoritative old revision with new head version',
    () async {
      final h = delivery.Harness();
      await h.init(enabled: false);
      addTearDown(h.close);
      setRemote(h, 2);
      await h.tasks.restoreSavedProjects();
      expect(h.tasks.inventoryIssue.value, isEmpty);
      final sent = <Map<String, Object?>>[];
      bool lose = true;
      h.specialRequest = (request) async {
        if (!request.url.path.endsWith('/rollback')) return null;
        final body = obj(jsonDecode(request.body));
        sent.add(body);
        setRemote(h, 3);
        if (lose) {
          lose = false;
          throw http.ClientException('lost ACK');
        }
        return delivery.ok({
          ...obj(fixture['rollbackReceipt']),
          'requestId': body['requestId'],
        });
      };
      final target =
          obj(fixture['rollbackRequest'])['targetRevision']! as String;
      expect(
        await h.tasks.rollbackSavedProject(
          projectId,
          targetRevision: target,
          expectedHeadVersion: 2,
        ),
        isFalse,
      );
      final pending = (await h.repo.pendingProjectRollbacks(
        expectedScopeKey: delivery.scope,
      )).single;
      expect(pending.request.toJson(), sent.single);
      await h.tasks.deactivateAndDrain();
      await h.mount(enabled: false);
      await h.tasks.restoreSavedProjects();
      expect(sent, hasLength(2));
      expect(sent[1], sent[0]);
      expect(
        await h.repo.pendingProjectRollbacks(expectedScopeKey: delivery.scope),
        isEmpty,
      );
      final installed = await h.installations.openCurrent(
        projectId,
        expectedScopeKey: h.installations.scopeKey,
      );
      expect(installed!.bundle.manifest.revisionId, target);
      expect(installed.headVersion, 3);
      expect(h.tasks.inventoryIssue.value, isEmpty);
    },
  );
  test(
    'delete ACK loss plus local cleanup interruption recovers receipt without a new nonce or repeating HTTP after receipt',
    () async {
      final h = delivery.Harness();
      await h.init(enabled: false);
      addTearDown(h.close);
      setRemote(h, 4);
      await h.tasks.restoreSavedProjects();
      final installed = await h.installations.openCurrent(
        projectId,
        expectedScopeKey: h.installations.scopeKey,
      );
      expect(installed, isNotNull);
      final sent = <Map<String, Object?>>[];
      bool lose = true;
      h.specialRequest = (request) async {
        if (!request.url.path.endsWith('/delete')) return null;
        final body = obj(jsonDecode(request.body));
        sent.add(body);
        h.deleted = true;
        if (lose) {
          lose = false;
          throw http.ClientException('lost delete ACK');
        }
        return delivery.ok({
          ...obj(fixture['deleteReceipt']),
          'requestId': body['requestId'],
        });
      };
      expect(
        await h.tasks.deleteSavedProject(
          projectId,
          expectedRevision: installed!.bundle.manifest.revisionId,
          expectedHeadVersion: 4,
        ),
        isFalse,
      );
      h.failCleanup = true;
      await h.tasks.deactivateAndDrain();
      await h.mount(enabled: false);
      await h.tasks.restoreSavedProjects();
      expect(sent, hasLength(2));
      expect(sent[1], sent[0]);
      expect(installed.isCurrent, isFalse);
      expect(h.cleanupCount, 1, reason: h.tasks.inventoryIssue.value);
      expect(
        (await h.repo.pendingProjectDeletions(
          expectedScopeKey: delivery.scope,
        )).single.proof,
        isNotNull,
      );
      h.failCleanup = false;
      await h.tasks.deactivateAndDrain();
      await h.mount(enabled: false);
      await h.tasks.restoreSavedProjects();
      expect(sent, hasLength(2));
      expect(h.cleanupCount, 2);
      expect(
        await h.repo.pendingProjectDeletions(expectedScopeKey: delivery.scope),
        isEmpty,
      );
      expect(
        await h.installations.openCandidate(
          installed.candidateDigest,
          expectedScopeKey: h.installations.scopeKey,
        ),
        isNull,
      );
      expect(
        (await h.repo.readOwnedProjects(
          expectedScopeKey: delivery.scope,
        ))!.projects,
        isEmpty,
      );
    },
  );
  test(
    'retired account cannot consume a deletion reply or purge offline work',
    () async {
      final h = delivery.Harness();
      await h.init(enabled: false);
      addTearDown(h.close);
      setRemote(h, 4);
      await h.tasks.restoreSavedProjects();
      final installed = await h.installations.openCurrent(
        projectId,
        expectedScopeKey: h.installations.scopeKey,
      );
      h.specialRequest = (request) async {
        if (!request.url.path.endsWith('/delete')) return null;
        final body = obj(jsonDecode(request.body));
        h.current = false;
        return delivery.ok({
          ...obj(fixture['deleteReceipt']),
          'requestId': body['requestId'],
        });
      };
      expect(
        await h.tasks.deleteSavedProject(
          projectId,
          expectedRevision: installed!.bundle.manifest.revisionId,
          expectedHeadVersion: 4,
        ),
        isFalse,
      );
      h.current = true;
      expect(
        (await h.repo.pendingProjectDeletions(
          expectedScopeKey: delivery.scope,
        )).single.proof,
        isNull,
      );
      expect(
        await h.installations.openCurrent(
          projectId,
          expectedScopeKey: h.installations.scopeKey,
        ),
        isNotNull,
      );
      expect(h.cleanupCount, 0);
    },
  );
  test(
    'definitive head conflict does not disable the account tracker',
    () async {
      final h = delivery.Harness();
      await h.init(enabled: false);
      addTearDown(h.close);
      setRemote(h, 2);
      await h.tasks.restoreSavedProjects();
      h.specialRequest = (request) async {
        if (!request.url.path.endsWith('/rollback')) return null;
        setRemote(h, 3);
        return http.Response(
          jsonEncode({
            'code': 'PROJECT_BUILD_HEAD_CONFLICT',
            'message': '',
            'traceId': 'unit',
          }),
          409,
        );
      };
      final target =
          obj(fixture['rollbackRequest'])['targetRevision']! as String;
      expect(
        await h.tasks.rollbackSavedProject(
          projectId,
          targetRevision: target,
          expectedHeadVersion: 2,
        ),
        isFalse,
      );
      expect(h.tasks.canManageSavedProjects, isTrue);
      expect(
        await h.repo.pendingProjectRollbacks(expectedScopeKey: delivery.scope),
        isEmpty,
      );
      await h.tasks.restoreSavedProjects();
      expect(
        (await h.installations.openCurrent(
          projectId,
          expectedScopeKey: h.installations.scopeKey,
        ))!.headVersion,
        3,
      );
    },
  );
  test(
    'lost create acknowledged after remote deletion stops at authenticated task not-found without recreating work',
    () async {
      final h = delivery.Harness();
      await h.init();
      addTearDown(h.close);
      h.loseCreate = true;
      final job = await h.enqueue();
      final nonce = h.posts.first['requestId'];
      h.specialRequest = (request) async {
        if (request.method == 'GET' &&
            request.url.path == '/v1/project-builds/v2/${h.taskId}') {
          return http.Response(
            jsonEncode({'code': 'NOT_FOUND', 'message': '', 'traceId': 'unit'}),
            404,
          );
        }
        return null;
      };
      await h.tasks.deactivateAndDrain();
      await h.mount();
      await h.tasks.restore();
      expect(h.posts.last['requestId'], nonce);
      final retired = h.latest(job.taskId);
      expect(retired.projectBuildV2!.syncIssue, 'rejected:task_unavailable');
      expect(h.tasks.canControl(retired, retry: false), isFalse);
      expect(await h.repo.list(expectedScopeKey: delivery.scope), isEmpty);
      final count = h.posts.length;
      await h.tasks.restore();
      expect(h.posts.length, count);
    },
  );
}
