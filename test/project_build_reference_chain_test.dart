import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as pixels;
import 'package:sembast/sembast.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_gateway.dart';
import 'package:maaso/src/features/project_build/domain/project_reference_selection.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_reference.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_delete.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_inventory.dart';
import 'project_build_v2_delivery_test.dart' as delivery;

PreparedChatMedia picture(int seed) {
  final image = pixels.Image(width: 8, height: 6);
  image.setPixelRgba(1, 1, seed, 30, 60, 255);
  return normalizeChatImage(Uint8List.fromList(pixels.encodePng(image)));
}

/// Real local persistence/media bytes with synthetic HTTP protocol responses;
/// this fixture does not attest a real model, vision approval or paid usage.
class ReferenceHarness extends delivery.Harness {
  final uploads = <Map<String, Object?>>[];
  final creates = <Map<String, Object?>>[];
  final receipts = <String, Map<String, Object?>>{};
  final mediaOwners = <ChatMediaService>[];
  late ChatMediaService media;
  bool loseUpload = false, loseCreation = false, imageAllowed = true;
  int analyses = 0;
  Future<void> Function()? beforeUpload;

  @override
  Future<void> mount({bool enabled = true}) async {
    await super.mount(enabled: enabled);
    await tasks.deactivateAndDrain();
    media = ChatMediaService(
      database: db.raw,
      isCurrent: () => current,
      baseUri: Uri.parse('https://example.invalid/'),
      accessToken: () async => 'synthetic',
      client: MockClient((_) async {
        analyses++;
        throw StateError('summary_must_not_be_called');
      }),
    );
    mediaOwners.add(media);
    tasks = ProjectBuildV2Tasks(
      jobs: jobs,
      repository: repo,
      gateway: HttpProjectBuildV2Gateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => delivery.scope,
        accessToken: () async => 'synthetic',
        isCurrent: () => current,
        client: MockClient(referenceHTTP),
      ),
      scopeKey: delivery.scope,
      appletScopeKey: appletScope,
      isCurrent: () => current,
      isForeground: () => foreground,
      isCreationReady: () => creationReady,
      authorize: () async {},
      authorizeCloudImage: () async {
        if (!imageAllowed) throw StateError('image_consent_denied');
      },
      referenceMedia: () => media,
      canRecoverDispatch: () async => enabled,
      enableCreation: enabled,
      requestId: () => 'reference_nonce_${nonce++}',
      pollInterval: const Duration(hours: 1),
      installation: installations,
      verification: verifier,
      presentCandidate: (_, _, _) async => false,
      persistInstalled: (_, _) async {},
    );
  }

  Future<http.Response> referenceHTTP(http.Request request) async {
    if (request.url.path.endsWith('/references')) {
      final body = projectBuildV2Object(jsonDecode(request.body));
      uploads.add(body);
      await beforeUpload?.call();
      final id = body['requestId']! as String;
      final receipt = receipts.putIfAbsent(id, () {
        final bytes = base64Decode(body['contentBase64']! as String);
        return {
          'schemaVersion': 2,
          'referenceId':
              'ref_10000000-0000-4000-8000-${(receipts.length + 1).toString().padLeft(12, '0')}',
          'originalSha256': hashes.sha256.convert(bytes).toString(),
          'sha256': hashes.sha256.convert([...bytes, 0]).toString(),
          'byteLength': bytes.length,
          'mediaType': body['mediaType'],
          'width': 8,
          'height': 6,
          'purpose': body['purpose'],
          'expiresAt': '2026-10-02T00:00:00Z',
        };
      });
      if (loseUpload) {
        loseUpload = false;
        throw http.ClientException('lost upload ACK');
      }
      return delivery.ok(receipt);
    }
    if (request.method == 'POST' &&
        request.url.path == '/v1/project-builds/v2') {
      final body = projectBuildV2Object(jsonDecode(request.body));
      creates.add(body);
      head = 1;
      if (loseCreation) {
        loseCreation = false;
        throw http.ClientException('lost create ACK');
      }
      return delivery.ok({
        ...projectBuildV2Object(f['createReceipt']),
        'requestId': body['requestId'],
      });
    }
    if (request.url.path.endsWith('/events')) {
      final after = int.parse(
        request.url.queryParameters['afterTaskSequence']!,
      );
      return delivery.ok({
        'events': delivery.events(f).sublist(after, 1),
        'nextTaskSequence': 1,
        'hasMore': false,
      });
    }
    if (request.url.path.endsWith('/$taskId')) {
      return delivery.ok(delivery.events(f).first['snapshot']);
    }
    throw StateError('unexpected reference fixture route');
  }

  @override
  Future<void> close() async {
    for (final owner in mediaOwners) {
      await owner.shutdown();
    }
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'missing local reference bytes on recovery remain a visible input problem without any plain-text create',
    () async {
      final h = ReferenceHarness();
      await h.init();
      addTearDown(h.close);
      final image = picture(118);
      final selection = await h.tasks.captureReferences([image]);
      h.imageAllowed = false;
      final job = await h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'Use exactly the selected reference.',
        referenceSelection: selection,
      );
      await h.tasks.synchronize(job.taskId);
      await h.tasks.deactivateAndDrain();
      await stringMapStoreFactory
          .store('chat_media.v1')
          .record(image.attachment.id)
          .delete(h.db.raw);
      h.imageAllowed = true;
      await h.mount();
      await h.tasks.restore();
      final restored = h.latest(job.taskId);
      expect(restored.projectBuildV2!.syncIssue, 'reference_input_missing');
      expect(restored.projectBuildV2!.snapshot, isNull);
      expect(
        restored.projectBuildV2!.nodes,
        isEmpty,
        reason: 'transport failure does not fabricate a server process node',
      );
      expect(restored.projectBuildV2!.taskId, isNull);
      expect(
        restored.projectBuildV2!.createRequestId,
        job.projectBuildV2!.createRequestId,
      );
      expect(
        restored.projectBuildV2!.referenceSelectionDigest,
        selection.sourceIdentityDigest,
      );
      expect(h.uploads, isEmpty);
      expect(h.creates, isEmpty);
      expect(h.analyses, 0);
    },
  );
  test(
    'native capture needs no summary and uploads exact purpose before binding create',
    () async {
      final h = ReferenceHarness();
      await h.init();
      addTearDown(h.close);
      final image = picture(120);
      final selection = await h.tasks.captureReferences(
        [image],
        purposes: [ProjectReferencePurpose.style],
      );
      expect(h.analyses, 0);
      expect(h.uploads, isEmpty);
      final old = ProjectReferenceInputSnapshot(
        scopeKey: h.appletScope,
        visualSummary: 'A prior real analysis',
        references: selection.references,
      );
      expect(selection.sourceIdentityDigest, old.sourceIdentityDigest);
      final job = await h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'Use the selected layout.',
        referenceSelection: selection,
      );
      await h.tasks.synchronize(job.taskId);
      expect(h.uploads, hasLength(1));
      expect(h.creates, hasLength(1));
      final upload = h.uploads.single;
      expect(base64Decode(upload['contentBase64']! as String), image.bytes);
      expect(upload['purpose'], 'style');
      final ref = projectBuildV2Object(
        (h.creates.single['referenceInputs']! as List).single,
      );
      expect(ref['sha256'], h.receipts.values.single['sha256']);
      expect(ref['sha256'], isNot(image.attachment.id));
      expect(ref['purpose'], 'style');
      expect(
        h.latest(job.taskId).projectBuildV2!.referenceSelectionDigest,
        selection.sourceIdentityDigest,
      );
      expect(
        h.latest(job.taskId).projectBuildV2!.snapshot!.status,
        ProjectBuildV2Status.queued,
      );
    },
  );

  test(
    'lost upload acknowledgement restarts with the exact nonce bytes and purpose',
    () async {
      final h = ReferenceHarness();
      await h.init();
      addTearDown(h.close);
      h.loseUpload = true;
      final selection = await h.tasks.captureReferences(
        [picture(90)],
        purposes: [ProjectReferencePurpose.layout],
      );
      final job = await h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'A reference task.',
        referenceSelection: selection,
      );
      await h.tasks.synchronize(job.taskId);
      expect(h.uploads, hasLength(1));
      expect(h.creates, isEmpty);
      await h.tasks.deactivateAndDrain();
      await h.mount();
      await h.tasks.restore();
      expect(h.uploads, hasLength(2));
      expect(h.uploads[1], h.uploads[0]);
      expect(h.creates, hasLength(1));
      expect(
        h.latest(job.taskId).projectBuildV2!.referenceSelectionDigest,
        selection.sourceIdentityDigest,
      );
    },
  );

  test(
    'frozen create acknowledgement loss never reuploads or changes reference IDs',
    () async {
      final h = ReferenceHarness();
      await h.init();
      addTearDown(h.close);
      h.loseCreation = true;
      final selection = await h.tasks.captureReferences(
        [picture(180)],
        purposes: [ProjectReferencePurpose.asset],
      );
      final job = await h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'Keep the selected asset.',
        referenceSelection: selection,
      );
      await h.tasks.synchronize(job.taskId);
      expect(h.uploads, hasLength(1));
      expect(h.creates, hasLength(1));
      await h.tasks.deactivateAndDrain();
      await h.mount();
      await h.tasks.restore();
      expect(h.uploads, hasLength(1));
      expect(h.creates, hasLength(2));
      expect(h.creates[1], h.creates[0]);
    },
  );

  test(
    'scope retirement after upload starts cannot consume receipt or create a task',
    () async {
      final h = ReferenceHarness();
      await h.init();
      addTearDown(h.close);
      final gate = Completer<void>();
      h.beforeUpload = () => gate.future;
      final selection = await h.tasks.captureReferences([picture(30)]);
      final job = await h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'Scoped input.',
        referenceSelection: selection,
      );
      await h.waitUntil(() => h.uploads.isNotEmpty);
      h.current = false;
      final stopped = h.tasks.deactivateAndDrain();
      gate.complete();
      await stopped;
      expect(h.creates, isEmpty);
      h.current = true;
      expect(
        (await h.repo.referenceAdmissions.read(
          job.projectBuildV2!.createRequestId,
        ))!.receipts.single,
        isNull,
      );
    },
  );

  test(
    'purpose changes selection identity and another account selection is rejected',
    () async {
      final h = ReferenceHarness();
      await h.init();
      addTearDown(h.close);
      final image = picture(210);
      final layout = await h.tasks.captureReferences(
        [image],
        purposes: [ProjectReferencePurpose.layout],
      );
      final asset = await h.tasks.captureReferences(
        [image],
        purposes: [ProjectReferencePurpose.asset],
      );
      expect(layout.sourceIdentityDigest, isNot(asset.sourceIdentityDigest));
      expect(
        () => h.tasks.enqueue(
          projectKind: ProjectBuildKind.applet,
          requirements: 'Wrong owner.',
          referenceSelection: ProjectReferenceSelection(
            scopeKey: 'other|owner',
            references: layout.references,
          ),
        ),
        throwsStateError,
      );
      expect(h.uploads, isEmpty);
    },
  );

  test(
    'image authorization is rechecked after a delayed token before upload POST',
    () async {
      final token = Completer<String>();
      var allowed = true, calls = 0;
      final gateway = HttpProjectBuildV2Gateway(
        baseUri: () => Uri.parse('https://example.invalid/'),
        contextKey: () => delivery.scope,
        accessToken: () => token.future,
        isCurrent: () => true,
        client: MockClient((_) async {
          calls++;
          throw StateError('must not send');
        }),
      );
      final image = picture(77);
      final pending = gateway.uploadReference(
        request: ProjectBuildReferenceUploadRequest(
          requestId: 'upload_guard_001',
          mediaType: image.mime,
          contentBase64: base64Encode(image.bytes),
          purpose: ProjectReferencePurpose.reference,
        ),
        expectedContextKey: delivery.scope,
        authorize: () async {
          if (!allowed) throw StateError('withdrawn');
        },
      );
      final rejected = expectLater(pending, throwsStateError);
      await pumpEventQueue();
      allowed = false;
      token.complete('synthetic');
      await rejected;
      expect(calls, 0);
      await gateway.deactivateAndDrain();
    },
  );
  for (final retry in [false, true]) {
    test(
      'image ${retry ? 'retry' : 'create'} cannot dispatch after token-wait revocation',
      () async {
        final token = Completer<String>();
        var allowed = true, calls = 0;
        final gateway = HttpProjectBuildV2Gateway(
          baseUri: () => Uri.parse('https://example.invalid/'),
          contextKey: () => delivery.scope,
          accessToken: () => token.future,
          isCurrent: () => true,
          client: MockClient((_) async {
            calls++;
            throw StateError('must not send');
          }),
        );
        Future<void> authorize() async {
          if (!allowed) throw StateError('withdrawn');
        }

        final pending = retry
            ? gateway.command(
                taskId: 'pb_task_00000000-0000-0000-0000-000000000005',
                command: ProjectBuildV2Command(
                  operation: ProjectBuildV2Operation.retry,
                  requestId: 'retry_guard_0001',
                  expectedRunId: 'pb_run_00000000-0000-0000-0000-000000000006',
                  expectedStatusVersion: 3,
                ),
                expectedContextKey: delivery.scope,
                authorize: authorize,
              )
            : gateway.create(
                request: ProjectBuildV2CreateRequest(
                  requestId: 'create_guard_0001',
                  agentId: 'self',
                  projectKind: ProjectBuildKind.applet,
                  requirements: 'Reference input.',
                  referenceInputs: [
                    ProjectBuildReferenceInput(
                      referenceId: 'ref_10000000-0000-4000-8000-000000000001',
                      sha256: 'a' * 64,
                      purpose: ProjectReferencePurpose.layout,
                    ),
                  ],
                ),
                expectedContextKey: delivery.scope,
                authorize: authorize,
              );
        final rejected = expectLater(pending, throwsStateError);
        await pumpEventQueue();
        allowed = false;
        token.complete('synthetic');
        await rejected;
        expect(calls, 0);
        await gateway.deactivateAndDrain();
      },
    );
  }

  test(
    'tracker restart cannot recreate a deleted reference edit or upload its image',
    () async {
      final h = ReferenceHarness();
      await h.init();
      addTearDown(h.close);
      final inventory = projectBuildV2Object(
        jsonDecode(
          File(
            'tool/fixtures/project_build_inventory_wire_v2.json',
          ).readAsStringSync(),
        ),
      );
      final owned = ProjectBuildV2OwnedProjects.fromJson(inventory['projects']);
      final project = owned.projects.single;
      await h.repo.recordOwnedProjects(owned, expectedScopeKey: delivery.scope);
      await h.repo.recordOwnedRevisions(
        ProjectBuildV2OwnedRevisions.fromJson(inventory['revisions']),
        expectedScopeKey: delivery.scope,
      );
      final selection = await h.tasks.captureReferences([picture(61)]);
      h.imageAllowed = false;
      final job = await h.tasks.enqueue(
        projectKind: ProjectBuildKind.applet,
        requirements: 'Edit from this reference.',
        projectId: project.projectId,
        baseRevision: project.currentRevisionId,
        baseHeadVersion: project.headVersion,
        referenceSelection: selection,
      );
      await h.tasks.synchronize(job.taskId);
      expect(h.uploads, isEmpty);
      final request = ProjectBuildV2DeleteRequest(
        requestId: 'delete_reference_task',
        expectedRevision: project.currentRevisionId,
        expectedHeadVersion: project.headVersion,
      );
      await h.repo.prepareProjectDeletion(
        project.projectId,
        request,
        expectedScopeKey: delivery.scope,
      );
      final proof = await h.repo.recordProjectDeletionReceipt(
        ProjectBuildV2DeleteReceipt.fromJson({
          'requestId': request.requestId,
          'projectId': project.projectId,
          'deletedRevisionId': project.currentRevisionId,
          'headVersion': project.headVersion + 1,
          'deletedAt': '2026-10-01T00:00:00Z',
        }),
        expectedScopeKey: delivery.scope,
      );
      expect(
        proof.createRequestIds,
        contains(job.projectBuildV2!.createRequestId),
      );
      await h.jobs.purgeProjectBuildV2(
        proof,
        expectedScopeKey: h.appletScope,
        expectedRepositoryScopeKey: delivery.scope,
      );
      await h.repo.referenceAdmissions.purge(proof);
      h.imageAllowed = true;
      await h.tasks.deactivateAndDrain();
      await h.mount();
      await h.tasks.restore();
      expect(h.jobs.jobs, isEmpty);
      expect(h.uploads, isEmpty);
      expect(h.creates, isEmpty);
    },
  );
}
