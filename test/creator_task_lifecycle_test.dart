import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/features/creator/data/creator_draft_repository.dart';
import 'package:maaso/src/features/creator/domain/creator_draft.dart';
import 'support/creator_task_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CreatorTaskHarness h;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    h = CreatorTaskHarness();
    await h.init();
  });
  tearDown(() => h.close());

  test(
    'already admitted lost-ack intent can reconcile after new client consent stops',
    () async {
      h.server.loseCreateAck = true;
      await h.start();
      expect(h.latest.serverImage!.snapshot, isNull);
      expect(h.authorizationCalls, 1);
      h.allowAuthorization = false;
      await h.tasks.synchronize(h.latest.taskId);
      expect(h.latest.serverImage!.serverSequence, 1);
      expect(h.authorizationCalls, 1);
      expect(h.server.receipts, hasLength(1));
    },
  );

  test(
    'new intent without consent creates no job, nonce or HTTP request',
    () async {
      h.allowAuthorization = false;
      await expectLater(h.tasks.enqueue(h.draft), throwsStateError);
      expect(h.jobs.jobs, isEmpty);
      expect(h.server.requests, isEmpty);
      expect(h.nonce, 0);
    },
  );

  test(
    'retirement waits in-flight HTTP and never persists a late response or cancels server',
    () async {
      h.server.pause = Completer<void>();
      await h.tasks.enqueue(h.draft);
      await h.server.entered.future;
      var done = false;
      final drain = h.tasks.deactivateAndDrain().then((_) => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      expect(h.tasks.isAvailable, isFalse);
      final pause = h.server.pause!;
      h.server.pause = null;
      pause.complete();
      await drain;
      expect(done, isTrue);
      expect(h.latest.serverImage!.snapshot, isNull);
      expect(h.latest.serverImage!.receipt, isNull);
      expect(h.server.commands, 0);
      await h.jobs.flush(); // DB remains open until the tracker drain finishes.
    },
  );

  test(
    'draft edit while file validation waits is protected by the DB compare-and-set',
    () async {
      await h.start();
      await h.finish();
      final preview = await h.tasks.preview(h.latest.id, expectedAttempt: 1);
      preview.markPresented();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.assets.beforeValidation = () async {
        entered.complete();
        await release.future;
      };
      final apply = h.tasks.applyPreview(preview);
      final rejection = expectLater(apply, throwsStateError);
      await entered.future;
      await h.repository.save(
        CreatorDraft.fromJson({
          ...h.draft.toJson(),
          'title': 'Changed during validation',
        }),
      );
      release.complete();
      await rejection;
      final fresh = (await h.repository.get(h.draft.id))!;
      expect(fresh.title, 'Changed during validation');
      expect(fresh.asset, isNull);
      expect(h.latest.serverImage!.applied, isFalse);
    },
  );

  test(
    'asset-only update during preview apply is also protected by its full revision',
    () async {
      await h.start();
      await h.finish();
      final preview = await h.tasks.preview(h.latest.id, expectedAttempt: 1);
      preview.markPresented();
      final entered = Completer<void>();
      final release = Completer<void>();
      h.assets.beforeValidation = () async {
        entered.complete();
        await release.future;
      };
      final rejection = expectLater(
        h.tasks.applyPreview(preview),
        throwsStateError,
      );
      await entered.future;
      final replacement = CreatorAssetRef(
        id: 'newer_explicit_image',
        localPath: '/test/newer.png',
        contentType: 'image/png',
        sha256: List.filled(64, 'b').join(),
        bytes: 12,
        width: 2,
        height: 2,
      );
      await h.repository.save(
        h.draft.copyWith(asset: replacement, status: CreatorDraftStatus.ready),
      );
      release.complete();
      await rejection;
      expect((await h.repository.get(h.draft.id))!.asset!.id, replacement.id);
      expect(h.latest.serverImage!.applied, isFalse);
    },
  );

  test(
    'different image parameters cannot silently reuse an active earlier request',
    () async {
      await h.start();
      await expectLater(
        h.tasks.enqueue(h.draft, aspectRatio: '16:9', style: 'cinematic'),
        throwsStateError,
      );
      expect(h.latest.serverImage!.input.aspectRatio, '1:1');
      expect(h.latest.serverImage!.input.style, 'natural');
      expect(h.server.creates, 1);
    },
  );

  test(
    'repository pinned to A cannot write B data into retired A database',
    () async {
      h.auth.session.value = MaasoAuthSession(
        accountUuid: 'owner-b',
        accessToken: 'B',
        refreshToken: 'B',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      final foreign = CreatorDraft.fromJson({
        ...h.draft.toJson(),
        'scopeKey': '${h.environment.environment.value.key}|owner-b',
      });
      await expectLater(
        h.repository.save(foreign),
        throwsA(isA<CreatorScopeChangedException>()),
      );
      await expectLater(
        h.repository.list(),
        throwsA(isA<CreatorScopeChangedException>()),
      );
      expect(h.server.requests, isEmpty);
    },
  );
}
