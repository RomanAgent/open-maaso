import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:sembast/sembast_memory.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';

void main() {
  Uint8List fixture() =>
      Uint8List.fromList(image.encodePng(image.Image(width: 400, height: 300)));
  ChatMessage message({List<ChatAttachment> attachments = const []}) =>
      ChatMessage(
        sessionId: 'self',
        senderId: 'user',
        receiverId: 'self',
        content: 'What is this?',
        timestamp: DateTime.utc(2026, 9, 15),
        isUserMessage: true,
        attachments: attachments,
      );

  test(
    'old messages decode with no attachments; new metadata round trips without media bytes',
    () {
      final old = message();
      expect(ChatMessage.fromJson(old.toJson()).attachments, isEmpty);
      final prepared = normalizeChatImage(fixture());
      final wire = message(attachments: [prepared.attachment]).toJson();
      final restored = ChatMessage.fromJson(wire);
      expect(restored.attachments.single.id, prepared.attachment.id);
      expect(wire.toString(), isNot(contains(base64Encode(prepared.bytes))));
      expect(wire.toString(), isNot(contains('localPath')));
    },
  );

  test(
    'images are bounded JPEGs with bounded previews and malformed data is rejected',
    () {
      final value = normalizeChatImage(fixture());
      expect(value.mime, 'image/jpeg');
      expect(image.decodeJpg(value.bytes), isNotNull);
      expect(value.attachment.thumbnailJpeg.length, lessThan(96 * 1024));
      expect(
        () => normalizeChatImage(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      expect(
        () => ChatAttachment.decode(List.filled(5, {})),
        throwsFormatException,
      );
      expect(
        () => ChatAttachment(id: '../account', kind: 'image', byteLength: 1),
        throwsFormatException,
      );
    },
  );

  test(
    'blob storage is account owned and cannot be read after retirement',
    () async {
      final dbA = await databaseFactoryMemory.openDatabase('media-a');
      final dbB = await databaseFactoryMemory.openDatabase('media-b');
      final a = ChatMediaService(
        database: dbA,
        isCurrent: () => true,
        baseUri: Uri.parse('https://example.com/'),
        accessToken: () async => 'a',
      );
      final b = ChatMediaService(
        database: dbB,
        isCurrent: () => true,
        baseUri: Uri.parse('https://example.com/'),
        accessToken: () async => 'b',
      );
      final value = normalizeChatImage(fixture());
      await a.persist(value);
      expect((await a.read(value.attachment))!.bytes, value.bytes);
      expect(await b.read(value.attachment), isNull);
      await a.shutdown();
      await expectLater(a.read(value.attachment), throwsStateError);
      await b.shutdown();
      await dbA.close();
      await dbB.close();
    },
  );

  test(
    'upload uses transient inline media with auth; only matching source ids are accepted',
    () async {
      final db = await databaseFactoryMemory.openDatabase('media-http');
      var allowed = false;
      final value = normalizeChatImage(fixture());
      final client = MockClient((request) async {
        expect(allowed, isTrue);
        expect(request.headers['Authorization'], 'Bearer account-a');
        expect(request.url.path, '/v1/proxy/media/analyze');
        final body = jsonDecode(request.body) as Map;
        expect(body['media'][0]['data'], base64Encode(value.bytes));
        expect(body.containsKey('model'), isFalse);
        return http.Response(
          jsonEncode({
            'code': 'OK',
            'data': {
              'description': 'A dark rectangle.',
              'modelId': 'doubao-seed-evolving',
              'sourceMediaIds': [value.attachment.id],
            },
          }),
          200,
        );
      });
      final service = ChatMediaService(
        database: db,
        isCurrent: () => true,
        baseUri: Uri.parse('https://example.com/'),
        accessToken: () async => 'account-a',
        authorize: () async {
          allowed = true;
        },
        client: client,
      );
      expect(
        await service.analyze(
          [value],
          question: 'What is visible?',
          locale: 'en',
          requestId: 'test',
        ),
        'A dark rectangle.',
      );
      // An analysis request does not itself save an attachment or conversation.
      expect(await service.read(value.attachment), isNull);
      await service.shutdown();
      await db.close();
    },
  );

  test('late analysis cannot publish after account replacement', () async {
    final db = await databaseFactoryMemory.openDatabase('media-late');
    final response = Completer<http.Response>();
    final dispatched = Completer<void>();
    var current = true;
    final value = normalizeChatImage(fixture());
    final service = ChatMediaService(
      database: db,
      isCurrent: () => current,
      baseUri: Uri.parse('https://example.com/'),
      accessToken: () async => 'a',
      client: MockClient((_) {
        dispatched.complete();
        return response.future;
      }),
    );
    final pending = service.analyze(
      [value],
      question: 'What?',
      locale: 'en',
      requestId: 'test',
    );
    await dispatched.future;
    current = false;
    final check = expectLater(pending, throwsStateError);
    response.complete(
      http.Response(
        jsonEncode({
          'code': 'OK',
          'data': {
            'description': 'No leak',
            'sourceMediaIds': [value.attachment.id],
          },
        }),
        200,
      ),
    );
    await check;
    await service.shutdown();
    await db.close();
  });

  test('denied consent never dispatches media', () async {
    final db = await databaseFactoryMemory.openDatabase('media-consent');
    var dispatched = false;
    final service = ChatMediaService(
      database: db,
      isCurrent: () => true,
      baseUri: Uri.parse('https://example.com/'),
      accessToken: () async => 'a',
      authorize: () async {
        throw StateError('consent');
      },
      client: MockClient((_) async {
        dispatched = true;
        return http.Response('', 500);
      }),
    );
    await expectLater(
      service.analyze(
        [normalizeChatImage(fixture())],
        question: 'What?',
        locale: 'en',
        requestId: 'test',
      ),
      throwsStateError,
    );
    expect(dispatched, isFalse);
    await service.shutdown();
    await db.close();
  });
}
