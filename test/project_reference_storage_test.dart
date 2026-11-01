import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

PreparedChatMedia _image(int color) {
  final source = image.Image(width: 16, height: 16);
  image.fill(source, color: image.ColorRgb8(color, 0, 0));
  return normalizeChatImage(Uint8List.fromList(image.encodePng(source)));
}

ChatMediaService _service(Database database, {bool Function()? current}) =>
    ChatMediaService(
      database: database,
      isCurrent: current ?? () => true,
      baseUri: Uri.parse('https://example.invalid/'),
      accessToken: () async =>
          throw StateError('No network operation is allowed'),
      client: MockClient(
        (_) async => throw StateError('No network operation is allowed'),
      ),
    );

void main() {
  test(
    'actual Sembast reopen retains ordered bytes and original observations',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'maaso-reference-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/account.db';
      final firstDb = await databaseFactoryIo.openDatabase(path);
      final first = _service(firstDb);
      final images = [_image(32), _image(160)];
      final snapshot = await first.persistProjectReferenceInput(
        images,
        scopeKey: 'scope-a',
        visualSummary: 'Original visual summary.',
        inputRevision: 2,
        purposes: [
          ProjectReferencePurpose.layout,
          ProjectReferencePurpose.style,
        ],
      );
      final persisted = snapshot.toJson();
      await first.shutdown();
      await firstDb.close();
      final secondDb = await databaseFactoryIo.openDatabase(path);
      final second = _service(secondDb);
      addTearDown(() async {
        await second.shutdown();
        await secondDb.close();
      });
      final restored = ProjectReferenceInputSnapshot.fromJson(persisted);
      final media = await second.loadProjectReferenceInput(restored);
      expect(
        media.map((item) => item.attachment.id),
        images.map((item) => item.attachment.id),
      );
      expect(media.first.bytes, images.first.bytes);
      expect(restored.visualSummary, 'Original visual summary.');
      expect(restored.inputRevision, 2);
      expect(restored.references.last.purpose, ProjectReferencePurpose.style);
    },
  );

  test(
    'freezes caller bytes and rejects corruption or missing assets',
    () async {
      final db = await databaseFactoryMemory.openDatabase('references-corrupt');
      final service = _service(db);
      addTearDown(() async {
        await service.shutdown();
        await db.close();
      });
      final item = _image(32);
      final expected = Uint8List.fromList(item.bytes);
      final writing = service.persistProjectReferenceInput(
        [item],
        scopeKey: 'scope-a',
        visualSummary: 'summary',
      );
      item.bytes[0] = 0;
      final snapshot = await writing;
      expect(
        (await service.loadProjectReferenceInput(snapshot)).single.bytes,
        expected,
      );
      final store = stringMapStoreFactory.store('chat_media.v1');
      await store.record(snapshot.references.single.sha256).put(db, {
        'mime': 'image/jpeg',
        'data': base64Encode([1, 2, 3]),
      });
      await expectLater(
        service.loadProjectReferenceInput(snapshot),
        throwsFormatException,
      );
      await store.record(snapshot.references.single.sha256).delete(db);
      await expectLater(
        service.loadProjectReferenceInput(snapshot),
        throwsStateError,
      );
    },
  );

  test(
    'scope retirement aborts all snapshot/blob writes and accounts stay separate',
    () async {
      final aDb = await databaseFactoryMemory.openDatabase('references-a');
      final bDb = await databaseFactoryMemory.openDatabase('references-b');
      var current = true;
      final a = _service(aDb, current: () => current);
      final b = _service(bDb);
      addTearDown(() async {
        await a.shutdown();
        await b.shutdown();
        await aDb.close();
        await bDb.close();
      });
      final item = _image(64);
      final snapshot = await a.persistProjectReferenceInput(
        [item],
        scopeKey: 'scope-a',
        visualSummary: 'summary',
      );
      await expectLater(
        b.loadProjectReferenceInput(snapshot),
        throwsStateError,
      );
      await expectLater(
        b.captureProjectReferenceInput(
          [item.attachment],
          scopeKey: 'scope-b',
          visualSummary: 'summary',
        ),
        throwsStateError,
      );
      final second = _image(128);
      final writing = a.persistProjectReferenceInput(
        [second],
        scopeKey: 'scope-a',
        visualSummary: 'not committed',
      );
      current = false;
      await expectLater(writing, throwsStateError);
      final store = stringMapStoreFactory.store('chat_media.v1');
      expect(await store.record(second.attachment.id).get(aDb), isNull);
      expect(
        await stringMapStoreFactory
            .store('project_reference_inputs.v1')
            .count(aDb),
        1,
      );
      await expectLater(
        a.loadProjectReferenceInput(snapshot),
        throwsStateError,
      );
    },
  );
}
