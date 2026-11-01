import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_store.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late Database database;
  late AppInvocationStore store;
  late AppInvocationDescriptor descriptor;
  var current = true;
  var serial = 0;
  AppInvocationStore makeStore({
    String process = 'process-1',
    AppInvocationCommittedImageReader? reader,
  }) => AppInvocationStore(
    database: database,
    scopeKey: 'account-A',
    mountId: 'mount-A',
    processId: process,
    isCurrent: () => current,
    committedImageReader: reader,
  );
  Future<AppInvocationRunRecord> admit({
    String token = 'submission-1',
    String input = '',
  }) => store.admit(
    submissionToken: token,
    turnId: 'turn-1',
    sessionId: 'self',
    descriptor: descriptor,
    adapterId: 'worker',
    adapterVersion: '1',
    inputDigest: input.isEmpty ? 'b' * 64 : input,
    canContinue: () => current,
  );
  Future<bool> reserve(
    AppInvocationRunRecord run, {
    String request = 'request-1',
    int amount = 2,
  }) => store.reserveAction(
    invocationId: run.invocationId,
    requestId: request,
    actionId: 'unrelated.calculate',
    arguments: {'amount': amount},
    observationId: 'observation-1',
    expectedStateVersion: 1,
    canContinue: () => current,
  );
  AppInvocationActionReceipt receipt(
    AppInvocationRunRecord run, {
    AppInvocationActionStatus status = AppInvocationActionStatus.completed,
    String request = 'request-1',
    Object? result = 'real result',
    List<AppInvocationProducedImage> outputs = const [],
  }) => AppInvocationActionReceipt(
    invocationId: run.invocationId,
    requestId: request,
    actionId: 'unrelated.calculate',
    identity: descriptor.identity,
    contractDigest: descriptor.contractDigest,
    status: status,
    stateVersion: 2,
    result: result,
    outputs: outputs,
  );

  setUp(() async {
    current = true;
    database = await databaseFactoryMemory.openDatabase(
      'invocation-journal-${serial++}.db',
    );
    store = makeStore();
    descriptor = AppInvocationDescriptor.fromSurface(
      project: SurfaceProject.fromJson({
        'id': 'work',
        'rendering': 'webApp',
        'html': '<main>untouched</main>',
        'manifest': {
          'actions': [
            {
              'name': 'unrelated.calculate',
              'schema': {'amount': 'number'},
            },
          ],
        },
      }),
      identity: AppInvocationIdentity(
        scopeKey: 'account-A',
        sourceId: 'work',
        revisionId: 'v1',
        sourceDigest: 'a' * 64,
      ),
    );
  });
  tearDown(() async {
    store.retire();
    await database.close();
  });

  test(
    'submission and action identities are durable before dispatch and never replay',
    () async {
      final run = await admit();
      expect((await admit()).invocationId, run.invocationId);
      await expectLater(admit(input: 'c' * 64), throwsStateError);
      expect(await reserve(run), isTrue);
      expect(await reserve(run), isFalse);
      await expectLater(reserve(run, amount: 3), throwsStateError);
      expect(
        (await store.readAction(
          run.invocationId,
          requestId: 'request-1',
        ))!['status'],
        'pending',
      );
    },
  );

  test(
    'process restart keeps request identity and resolves unknown only through original receipt',
    () async {
      final run = await admit();
      await reserve(run);
      store.retire();
      store = makeStore(process: 'process-2');
      final pending = await store.readAction(
        run.invocationId,
        requestId: 'request-1',
      );
      expect(pending!['status'], 'outcomeUnknown');
      expect(await reserve(run), isFalse);
      await store.settle(
        receipt(run, status: AppInvocationActionStatus.outcomeUnknown),
        canContinue: () => true,
      );
      final finalReceipt = receipt(run);
      await store.settle(finalReceipt, canContinue: () => true);
      expect(
        (await store.readReceipt(
          run.invocationId,
          requestId: 'request-1',
        ))!.digest,
        finalReceipt.digest,
      );
      await expectLater(
        store.settle(
          receipt(run, result: 'conflicting result'),
          canContinue: () => true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'completed PNG bytes survive store replacement without rerunning an action',
    () async {
      final run = await admit();
      await reserve(run);
      final pixels = image.Image(width: 2, height: 2, numChannels: 4);
      pixels.setPixelRgba(0, 0, 50, 100, 150, 0);
      pixels.setPixelRgba(1, 1, 10, 20, 30, 255);
      final encoded = Uint8List.fromList(image.encodePng(pixels));
      final output = AppInvocationProducedImage(
        producerOutputKey: 'image-1',
        mime: 'image/png',
        bytes: encoded,
      );
      final completed = receipt(run, outputs: [output]);
      encoded.fillRange(0, encoded.length, 0);
      await store.settle(completed, canContinue: () => true);
      await store.settle(completed, canContinue: () => true);
      store.retire();
      store = makeStore(process: 'process-2');
      final recovered = (await store.readReceipt(
        run.invocationId,
        requestId: 'request-1',
      ))!;
      expect(recovered.digest, completed.digest);
      expect(recovered.outputs.single.bytes, output.bytes);
      final decoded = image.decodePng(recovered.outputs.single.bytes)!;
      expect(decoded.width, 2);
      expect(decoded.getPixel(0, 0).a, 0);
      expect(await reserve(run), isFalse);
    },
  );

  test(
    'application data is invocation-specific CAS and leaves all original stores untouched',
    () async {
      final existing = stringMapStoreFactory.store('original-works');
      final original = {
        'source': '<main>untouched</main>',
        'installed': {'score': 9},
        'preview': {'score': 4},
        'manualGame': {'matchId': 'manual', 'seat': 'human', 'checkpoint': 7},
        'publishedHead': 'v1',
      };
      await existing.record('work').put(database, original);
      final first = await admit();
      final second = await admit(token: 'submission-2');
      final a = store.applicationDataPort(
        first.invocationId,
        canContinue: () => current,
      );
      final b = store.applicationDataPort(
        second.invocationId,
        canContinue: () => current,
      );
      expect((await a.read()).version, 0);
      await a.save({'score': 12}, expectedVersion: 0, canContinue: () => true);
      expect((await a.read()).values, {'score': 12});
      expect((await b.read()).values, isEmpty);
      await expectLater(
        a.save({'score': 13}, expectedVersion: 0, canContinue: () => true),
        throwsStateError,
      );
      expect(await existing.record('work').get(database), original);
      await store.cancel(first.invocationId);
      await expectLater(
        a.save({'score': 14}, expectedVersion: 1, canContinue: () => true),
        throwsStateError,
      );
    },
  );

  test(
    'retirement fences an action already queued behind a transaction',
    () async {
      final run = await admit();
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final rejected = expectLater(reserve(run), throwsStateError);
      current = false;
      release.complete();
      await blocker;
      await rejected;
      current = true;
      expect(
        await store.readAction(run.invocationId, requestId: 'request-1'),
        isNull,
      );
    },
  );

  test(
    'result linkage shares caller transaction and cannot claim completion without receipt',
    () async {
      final run = await admit();
      await expectLater(
        database.transaction(
          (tx) => store.markResultCommitted(
            tx,
            invocationId: run.invocationId,
            resultId: 'result-1',
            messageId: 1,
            canContinue: () => true,
          ),
        ),
        throwsStateError,
      );
      await reserve(run);
      await store.settle(receipt(run), canContinue: () => true);
      await expectLater(
        database.transaction((tx) async {
          await store.markResultCommitted(
            tx,
            invocationId: run.invocationId,
            resultId: 'result-1',
            messageId: 1,
            canContinue: () => true,
          );
          throw StateError('message transaction failed');
        }),
        throwsStateError,
      );
      expect((await store.readRun(run.invocationId)).status, 'completed');
      Future<void> commit(String resultId) => database.transaction(
        (tx) => store.markResultCommitted(
          tx,
          invocationId: run.invocationId,
          resultId: resultId,
          messageId: 1,
          canContinue: () => true,
        ),
      );
      await commit('result-1');
      await commit('result-1');
      await expectLater(commit('result-2'), throwsStateError);
      expect((await store.readRun(run.invocationId)).status, 'resultCommitted');
      await expectLater(reserve(run, request: 'request-2'), throwsStateError);
    },
  );

  test(
    'published receipt compacts atomically and reopens original pixels without changing intermediate receipts',
    () async {
      final media = stringMapStoreFactory.store('test-owned-media');
      Future<Uint8List?> readMedia(
        DatabaseClient tx, {
        required String id,
        required String mime,
        required int byteLength,
      }) async {
        final row = await media.record(id).get(tx);
        if (row == null) return null;
        expect(row['mime'], mime);
        final bytes = base64Decode(row['data']! as String);
        expect(bytes.length, byteLength);
        return bytes;
      }

      store.retire();
      store = makeStore(reader: readMedia);
      final run = await admit();
      final pixels = image.Image(width: 2, height: 2, numChannels: 4)
        ..setPixelRgba(1, 1, 12, 34, 56, 255);
      final output = AppInvocationProducedImage(
        producerOutputKey: 'original-pixels',
        mime: 'image/png',
        bytes: Uint8List.fromList(image.encodePng(pixels)),
      );
      for (final request in ['intermediate', 'final']) {
        await reserve(run, request: request);
        await store.settle(
          receipt(run, request: request, outputs: [output]),
          canContinue: () => true,
        );
      }
      final outputRows = stringMapStoreFactory.store(
        'app_invocation_output_bytes.v1',
      );
      Future<List<RecordSnapshot<String, Map<String, Object?>>>> rows() =>
          outputRows.find(database);
      Future<void> publish(Transaction tx) async {
        await media.record(output.sha256Digest).put(tx, {
          'mime': output.mime,
          'data': base64Encode(output.bytes),
        });
        await store.markResultCommitted(
          tx,
          invocationId: run.invocationId,
          requestId: 'final',
          resultId: 'final-result',
          messageId: 18,
          canContinue: () => true,
        );
      }

      await expectLater(
        database.transaction((tx) async {
          await publish(tx);
          throw StateError('message write failed');
        }),
        throwsStateError,
      );
      expect(await media.record(output.sha256Digest).get(database), isNull);
      expect(
        (await rows()).every((row) => row.value['data'] is String),
        isTrue,
      );
      expect((await store.readRun(run.invocationId)).status, 'completed');
      await database.transaction(publish);
      final compacted = (await rows()).singleWhere(
        (row) => row.value['requestId'] == 'final',
      );
      expect(compacted.value.containsKey('data'), isFalse);
      expect(compacted.value['mediaId'], output.sha256Digest);
      expect(
        (await rows())
            .singleWhere((row) => row.value['requestId'] == 'intermediate')
            .value['data'],
        isA<String>(),
      );
      store.retire();
      store = makeStore(process: 'process-2', reader: readMedia);
      final recovered = (await store.readReceipt(
        run.invocationId,
        requestId: 'final',
      ))!;
      expect(
        recovered.digest,
        receipt(run, request: 'final', outputs: [output]).digest,
      );
      expect(recovered.outputs.single.bytes, output.bytes);
      final decoded = image.decodePng(recovered.outputs.single.bytes)!;
      expect(decoded.getPixel(0, 0).a, 0);
      expect(decoded.getPixel(1, 1).r, 12);
      expect(
        (await store.readReceipt(
          run.invocationId,
          requestId: 'intermediate',
        ))!.outputs.single.bytes,
        output.bytes,
      );
    },
  );

  test(
    'missing or different committed media never deletes recoverable temporary bytes',
    () async {
      Uint8List? linked;
      store.retire();
      store = makeStore(
        reader: (tx, {required id, required mime, required byteLength}) async =>
            linked,
      );
      final run = await admit();
      await reserve(run);
      final output = AppInvocationProducedImage(
        producerOutputKey: 'image',
        mime: 'image/png',
        bytes: Uint8List.fromList(
          image.encodePng(image.Image(width: 1, height: 1)),
        ),
      );
      final completed = receipt(run, outputs: [output]);
      await store.settle(completed, canContinue: () => true);
      Future<void> publish() => database.transaction(
        (tx) => store.markResultCommitted(
          tx,
          invocationId: run.invocationId,
          requestId: 'request-1',
          resultId: 'result-1',
          messageId: 1,
          canContinue: () => true,
        ),
      );
      await expectLater(publish(), throwsStateError);
      linked = Uint8List.fromList(output.bytes)..[0] ^= 1;
      await expectLater(publish(), throwsStateError);
      expect((await store.readRun(run.invocationId)).status, 'completed');
      expect(
        (await store.readReceipt(
          run.invocationId,
          requestId: 'request-1',
        ))!.digest,
        completed.digest,
      );
      linked = output.bytes;
      await publish();
      linked = Uint8List.fromList(output.bytes)..[0] ^= 1;
      await expectLater(
        store.readReceipt(run.invocationId, requestId: 'request-1'),
        throwsStateError,
      );
    },
  );

  test(
    'store drain waits for native application data writes already queued',
    () async {
      final run = await admit();
      final port = store.applicationDataPort(
        run.invocationId,
        canContinue: () => true,
      );
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final writing = expectLater(
        port.save(
          {'draft': 'pending'},
          expectedVersion: 0,
          canContinue: () => true,
        ),
        throwsStateError,
      );
      var drained = false;
      final draining = store.deactivateAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      release.complete();
      await blocker;
      await writing;
      await draining;
      expect(drained, isTrue);
      expect(port.isCurrent, isFalse);
    },
  );
}
