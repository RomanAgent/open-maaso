import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/domain/project_build_edit_target.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'project_build_v2_delivery_test.dart' as delivery;
import 'project_build_v2_management_test.dart' as management;
import 'project_build_reference_chain_test.dart' as references;

class EditReferenceHarness extends references.ReferenceHarness {
  @override
  Future<http.Response> referenceHTTP(http.Request request) {
    if (request.method == 'GET' && request.url.path.contains('/projects')) {
      return handle(request);
    }
    return super.referenceHTTP(request);
  }
}

Future<ProjectBuildEditTarget> target(delivery.Harness h) async {
  final history = await h.tasks.savedRevisionHistory(management.projectId);
  return h.tasks.prepareEditTarget(
    management.projectId,
    expectedRevisionId: history.currentRevisionId,
    expectedHeadVersion: history.currentHeadVersion,
    expectedCandidateDigest: history.current.candidateDigest,
  );
}

void refuseCreate(delivery.Harness h, List<Map<String, Object?>> sent) {
  h.specialRequest = (request) async {
    if (request.method == 'POST' &&
        request.url.path == '/v1/project-builds/v2') {
      sent.add(projectBuildV2Object(jsonDecode(request.body)));
      return http.Response('{}', 503);
    }
    return null;
  };
}

ProjectBuildV2CreateRequest request(ProjectBuildEditTarget t, String id) =>
    ProjectBuildV2CreateRequest(
      requestId: id,
      agentId: 'self',
      projectKind: t.projectKind,
      requirements: 'Keep the existing list and add search.',
      projectId: t.projectId,
      baseRevision: t.baseRevision,
      baseHeadVersion: t.baseHeadVersion,
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late delivery.Harness h;
  setUp(() async {
    h = delivery.Harness();
    await h.init();
    management.setRemote(h, 2);
  });
  tearDown(() async => h.close());
  test(
    'native target sends the selected exact CAS; binding audit survives restart and lost acknowledgement',
    () async {
      final selected = await target(h), sent = <Map<String, Object?>>[];
      refuseCreate(h, sent);
      final job = await h.tasks.enqueue(
        projectKind: selected.projectKind,
        requirements: 'Keep the existing list and add search.',
        editTarget: selected,
      );
      await h.tasks.synchronize(job.taskId);
      expect(sent, isNotEmpty);
      final original = sent.first;
      expect(original['projectId'], selected.projectId);
      expect(original['baseRevision'], selected.baseRevision);
      expect(original['baseHeadVersion'], 2);
      expect(job.projectBuildV2!.editIdentity, selected.identity);
      expect(
        job.projectBuildV2!.editIdentity!.digest,
        selected.identity.digest,
      );
      expect(
        ProjectBuildV2TaskBinding.fromJson(
          job.projectBuildV2!.toJson(),
        ).editIdentity,
        selected.identity,
      );
      await h.tasks.deactivateAndDrain();
      expect(selected.isCurrent, isFalse);
      management.setRemote(h, 3);
      await h.mount();
      await h.tasks.restore();
      expect(sent.length, greaterThanOrEqualTo(2));
      expect(
        sent.every((body) => jsonEncode(body) == jsonEncode(original)),
        isTrue,
        reason:
            'Ambiguous existing intent keeps its nonce and original head; it does not select a newer base',
      );
      expect(
        h.jobs.jobs.single.projectBuildV2!.editIdentity,
        selected.identity,
      );
    },
  );
  test(
    'reference-image editing keeps original CAS and upload receipts across lost create ACK',
    () async {
      final reference = EditReferenceHarness();
      await reference.init();
      addTearDown(reference.close);
      management.setRemote(reference, 2);
      final selected = await target(reference);
      // The synthetic queued snapshot must describe the actual edited project.
      final oldPage = projectBuildV2Object(reference.f['eventsPage']);
      final oldEvents = oldPage['events']! as List;
      final created = projectBuildV2Object(oldEvents.first);
      reference.f['eventsPage'] = {
        ...oldPage,
        'events': [
          {
            ...created,
            'snapshot': {
              ...projectBuildV2Object(created['snapshot']),
              'projectId': selected.projectId,
            },
          },
          ...oldEvents.skip(1),
        ],
      };
      final images = await reference.tasks.captureReferences([
        references.picture(100),
      ]);
      reference.loseCreation = true;
      final job = await reference.tasks.enqueue(
        projectKind: selected.projectKind,
        requirements: 'Keep the list and use this image as a style reference.',
        editTarget: selected,
        referenceSelection: images,
      );
      await reference.tasks.synchronize(job.taskId);
      expect(reference.uploads, hasLength(1));
      final original = reference.creates.single;
      expect(original['projectId'], selected.projectId);
      expect(original['baseRevision'], selected.baseRevision);
      expect(original['baseHeadVersion'], selected.baseHeadVersion);
      expect(original['referenceInputs'], hasLength(1));
      await reference.tasks.deactivateAndDrain();
      management.setRemote(reference, 3);
      await reference.mount();
      await reference.tasks.restore();
      expect(reference.creates, hasLength(2));
      expect(reference.creates.last, original);
      expect(reference.uploads, hasLength(1));
      expect(
        reference.jobs.jobs.single.projectBuildV2!.editIdentity,
        selected.identity,
      );
      expect(reference.analyses, 0);
    },
  );
  test(
    'preparation rejects a changed head or digest instead of silently editing the new head',
    () async {
      final first = await h.tasks.savedRevisionHistory(management.projectId);
      management.setRemote(h, 3);
      await expectLater(
        h.tasks.prepareEditTarget(
          management.projectId,
          expectedRevisionId: first.currentRevisionId,
          expectedHeadVersion: first.currentHeadVersion,
          expectedCandidateDigest: first.current.candidateDigest,
        ),
        throwsStateError,
      );
      final current = await h.tasks.savedRevisionHistory(management.projectId);
      await expectLater(
        h.tasks.prepareEditTarget(
          management.projectId,
          expectedRevisionId: current.currentRevisionId,
          expectedHeadVersion: current.currentHeadVersion,
          expectedCandidateDigest: 'f' * 64,
        ),
        throwsStateError,
      );
      expect(h.jobs.jobs, isEmpty);
      expect(h.posts, isEmpty);
    },
  );
  test(
    'authorization wait rechecks the selected head before persisting a new intent',
    () async {
      final selected = await target(h),
          entered = Completer<void>(),
          release = Completer<void>();
      h.authorizing = () {
        entered.complete();
        return release.future;
      };
      final work = h.tasks.enqueue(
        projectKind: selected.projectKind,
        requirements: 'Add search.',
        editTarget: selected,
      );
      final failure = expectLater(work, throwsStateError);
      await entered.future;
      management.setRemote(h, 3);
      release.complete();
      await failure;
      expect(h.jobs.jobs, isEmpty);
      expect(h.posts, isEmpty);
      expect(
        await h.repo.pendingRequests(expectedScopeKey: delivery.scope),
        isEmpty,
      );
    },
  );
  test(
    'explicit conflicting CAS or kind is rejected; retirement and foreign issuer cannot reuse a target',
    () async {
      final selected = await target(h);
      expect(
        () => h.tasks.enqueue(
          projectKind: selected.projectKind,
          requirements: 'Change it.',
          editTarget: selected,
          baseHeadVersion: 1,
        ),
        throwsStateError,
      );
      expect(
        () => h.tasks.enqueue(
          projectKind: ProjectBuildKind.game,
          requirements: 'Change it.',
          editTarget: selected,
        ),
        throwsStateError,
      );
      final foreign = ProjectBuildV2Repository(
        database: h.db,
        scopeKey: delivery.scope,
        isCurrent: () => true,
      );
      expect(
        () => foreign.validateEditTarget(
          selected,
          expectedScopeKey: delivery.scope,
          expectedAppletScopeKey: h.appletScope,
        ),
        throwsStateError,
      );
      h.current = false;
      expect(selected.isCurrent, isFalse);
      await expectLater(
        h.tasks.enqueue(
          projectKind: selected.projectKind,
          requirements: 'Change it.',
          editTarget: selected,
        ),
        throwsStateError,
      );
      expect(h.jobs.jobs, isEmpty);
      expect(h.posts, isEmpty);
    },
  );
  test(
    'original creator attribution does not impersonate or restrict the current editing Agent',
    () async {
      final projects = management.obj(h.inventory['projects']);
      final p = management.obj((projects['projects'] as List).single);
      h.inventory['projects'] = {
        ...projects,
        'projects': [
          {...p, 'agentId': 'original-agent'},
        ],
      };
      final selected = await target(h), sent = <Map<String, Object?>>[];
      refuseCreate(h, sent);
      expect(selected.agentId, 'original-agent');
      final job = await h.tasks.enqueue(
        agentId: 'current-agent',
        projectKind: selected.projectKind,
        requirements: 'Add search.',
        editTarget: selected,
      );
      await h.tasks.synchronize(job.taskId);
      expect(sent.first['agentId'], 'current-agent');
      expect(job.agentId, 'current-agent');
    },
  );
  test(
    'ABA returning to the same revision still rejects the earlier head version',
    () async {
      management.setRemote(h, 1);
      final original = await target(h);
      management.setRemote(h, 2);
      await h.tasks.savedRevisionHistory(management.projectId);
      management.setRemote(h, 3);
      final current = await h.tasks.savedRevisionHistory(management.projectId);
      expect(current.currentRevisionId, original.baseRevision);
      expect(current.current.candidateDigest, original.candidateDigest);
      expect(current.currentHeadVersion, isNot(original.baseHeadVersion));
      await expectLater(
        h.tasks.enqueue(
          projectKind: original.projectKind,
          requirements: 'Add search.',
          editTarget: original,
        ),
        throwsStateError,
      );
      expect(h.posts, isEmpty);
      expect(h.jobs.jobs, isEmpty);
    },
  );
  test(
    'a private durable create proof from another account scope cannot hydrate audit identity',
    () async {
      final selected = await target(h),
          input = request(await target(h), 'foreign_edit_nonce');
      final foreign = ProjectBuildV2Repository(
        database: h.db,
        scopeKey: 'test|another',
        isCurrent: () => true,
      );
      await foreign.prepareCreate(input, expectedScopeKey: 'test|another');
      final proof = (await foreign.durableCreate(
        input.requestId,
        expectedScopeKey: 'test|another',
      ))!;
      final job = h.jobs.startProjectBuildV2(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: h.appletScope,
        projectKind: selected.projectKind,
        binding: ProjectBuildV2TaskBinding(
          scopeKey: delivery.scope,
          createRequestId: input.requestId,
          pendingCommand: ProjectBuildV2TaskPendingCommand(
            operation: ProjectBuildV2TaskOperation.create,
            requestId: input.requestId,
          ),
        ),
      );
      expect(
        () => h.jobs.restoreProjectBuildV2EditIdentity(
          job.id,
          proof,
          expectedScopeKey: h.appletScope,
          expectedRepositoryScopeKey: delivery.scope,
        ),
        throwsStateError,
      );
      expect(h.jobs.byId(job.id)!.projectBuildV2!.editIdentity, isNull);
    },
  );
  test(
    'old missing audit metadata is hydrated only from the original private durable create proof',
    () async {
      final selected = await target(h),
          input = request(selected, 'edit_original_nonce');
      await h.repo.prepareCreate(input, expectedScopeKey: delivery.scope);
      final old = h.jobs.startProjectBuildV2(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: h.appletScope,
        projectKind: input.projectKind,
        binding: ProjectBuildV2TaskBinding(
          scopeKey: delivery.scope,
          createRequestId: input.requestId,
          pendingCommand: ProjectBuildV2TaskPendingCommand(
            operation: ProjectBuildV2TaskOperation.create,
            requestId: input.requestId,
          ),
        ),
      );
      expect(old.projectBuildV2!.editIdentity, isNull);
      expect(
        () => h.jobs.updateProjectBuildV2Binding(
          old.id,
          old.projectBuildV2!.copyWith(editIdentity: selected.identity),
          expectedScopeKey: h.appletScope,
        ),
        throwsStateError,
      );
      final proof = (await h.repo.durableCreate(
        input.requestId,
        expectedScopeKey: delivery.scope,
      ))!;
      final updated = h.jobs.restoreProjectBuildV2EditIdentity(
        old.id,
        proof,
        expectedScopeKey: h.appletScope,
        expectedRepositoryScopeKey: delivery.scope,
      );
      expect(updated.projectBuildV2!.editIdentity, selected.identity);
      final changed = ProjectBuildEditIdentity(
        projectId: selected.projectId,
        baseRevision: selected.baseRevision,
        baseHeadVersion: 1,
      );
      expect(
        () => h.jobs.updateProjectBuildV2Binding(
          old.id,
          updated.projectBuildV2!.copyWith(editIdentity: changed),
          expectedScopeKey: h.appletScope,
        ),
        throwsStateError,
      );
      expect(
        () => h.jobs.startProjectBuildV2(
          agentId: input.agentId,
          userText: input.requirements,
          appletScopeKey: h.appletScope,
          projectKind: input.projectKind,
          binding: updated.projectBuildV2!.copyWith(editIdentity: changed),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'restart restores a missing old edit identity from durable body without a target or head rewrite',
    () async {
      final selected = await target(h),
          input = request(selected, 'edit_restart_nonce'),
          sent = <Map<String, Object?>>[];
      refuseCreate(h, sent);
      await h.repo.prepareCreate(input, expectedScopeKey: delivery.scope);
      h.jobs.startProjectBuildV2(
        agentId: input.agentId,
        userText: input.requirements,
        appletScopeKey: h.appletScope,
        projectKind: input.projectKind,
        binding: ProjectBuildV2TaskBinding(
          scopeKey: delivery.scope,
          createRequestId: input.requestId,
          pendingCommand: ProjectBuildV2TaskPendingCommand(
            operation: ProjectBuildV2TaskOperation.create,
            requestId: input.requestId,
          ),
        ),
      );
      await h.jobs.flush();
      await h.tasks.deactivateAndDrain();
      management.setRemote(h, 3);
      await h.mount();
      await h.tasks.restore();
      expect(
        h.jobs.jobs.single.projectBuildV2!.editIdentity,
        selected.identity,
      );
      expect(sent, isNotEmpty);
      expect(sent.first, input.toJson());
    },
  );
}
