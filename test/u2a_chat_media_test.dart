import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/chat/presentation/media/chat_attachment_preview.dart';
import 'package:maaso/src/features/chat/presentation/media/u2a_chat_composer.dart';
import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationEntryHarness harness;
  late ChatMediaService media;
  var current = true;
  late Future<http.Response> Function(http.Request) respond;
  var calls = 0;
  http.Response success(http.Request request) {
    final data = jsonDecode(request.body) as Map;
    return http.Response(
      jsonEncode({
        'code': 'OK',
        'data': {
          'description': 'A blue cup on the table',
          'sourceMediaIds': (data['media'] as List)
              .map((e) => e['id'])
              .toList(),
        },
      }),
      200,
    );
  }

  Uint8List pixels() =>
      Uint8List.fromList(image.encodePng(image.Image(width: 32, height: 32)));
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    current = true;
    calls = 0;
    respond = (request) async => success(request);
    harness = await ConversationEntryHarness.create();
    media = appServices.put(
      ChatMediaService(
        database: harness.database.raw,
        isCurrent: () => current,
        baseUri: Uri.parse('https://example.invalid/'),
        accessToken: () async => 'test-token',
        client: MockClient((request) {
          calls++;
          return respond(request);
        }),
      ),
    );
  });
  tearDown(() async {
    await harness.close();
  });

  test(
    'media-only send persists the attachment and gives observations separate from user text',
    () async {
      var observed = <Message>[];
      harness.runtime.runChat = (context, history) async {
        observed = history;
        expect(context.text, isNot(contains('blue cup')));
        await context.deliver([
          ConversationUtteranceDraft(text: 'It is a cup.'),
        ]);
        return ExecutionResult.success('');
      };
      await harness.chat.addMedia(pixels(), video: false);
      final attachment = harness.chat.pendingMedia.single.attachment;
      await harness.chat.sendMessage();
      final rows = await harness.database.getMessages('self');
      final user = rows.singleWhere((row) => row.isUserMessage);
      expect(user.attachments.single.id, attachment.id);
      expect(user.visualContext, 'A blue cup on the table');
      expect(user.content, isNot(contains('blue cup')));
      expect(
        observed.any(
          (m) =>
              m.content.contains('quoted_uploaded_media_observations') &&
              m.content.contains('untrusted'),
        ),
        isTrue,
      );
      expect((await media.read(attachment))!.bytes, isNotEmpty);
      expect(harness.chat.pendingMedia, isEmpty);
      expect(harness.chat.inputController.text, isEmpty);
      expect(calls, 1);
      expect(harness.runtime.submissions, 1);
    },
  );

  test(
    'analysis failure preserves text and attachment for retry without creating a chat turn',
    () async {
      respond = (_) async => http.Response('{}', 503);
      await harness.chat.addMedia(pixels(), video: false);
      harness.chat.inputController.text = 'What do you see?';
      await harness.chat.sendMessage();
      expect(harness.chat.inputController.text, 'What do you see?');
      expect(harness.chat.pendingMedia, hasLength(1));
      expect(harness.chat.sendError.value, isNotNull);
      expect(harness.runtime.submissions, 0);
      expect(await harness.database.getMessages('self'), isEmpty);
      expect(harness.chat.busy, isFalse);
    },
  );

  for (final retire in [false, true]) {
    test(
      '${retire ? 'account retirement' : 'interrupt'} discards late analysis before persistence or a new turn',
      () async {
        final entered = Completer<http.Request>();
        final result = Completer<http.Response>();
        respond = (request) {
          entered.complete(request);
          return result.future;
        };
        await harness.chat.addMedia(pixels(), video: false);
        final attachment = harness.chat.pendingMedia.single.attachment;
        harness.chat.inputController.text = 'First draft';
        final sending = harness.chat.sendMessage();
        final request = await entered.future;
        await harness.chat
            .sendMessage(); // Duplicate send is ignored during analysis.
        expect(calls, 1);
        harness.chat.inputController.text = 'Newer draft';
        if (retire) {
          current = false;
        } else {
          harness.chat.interruptCurrent();
        }
        result.complete(success(request));
        await sending;
        expect(harness.runtime.submissions, 0);
        expect(await harness.database.getMessages('self'), isEmpty);
        expect(harness.chat.inputController.text, 'Newer draft');
        expect(harness.chat.pendingMedia, hasLength(1));
        if (!retire) expect(await media.read(attachment), isNull);
        expect(harness.chat.busy, isFalse);
      },
    );
  }

  testWidgets(
    'fullscreen composer exposes media choices and removable previews using shared frost composer',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: U2aChatComposer(controller: harness.chat),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChatInputBar>(find.byType(ChatInputBar))
            .allowRealtimeVoice,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('u2a-attach-media')));
      await tester.pumpAndSettle();
      expect(find.text('Choose image'), findsOneWidget);
      expect(find.text('Choose video'), findsOneWidget);
      Navigator.pop(tester.element(find.text('Choose image')));
      await tester.pumpAndSettle();
      harness.chat.pendingMedia.add(normalizeChatImage(pixels()));
      await tester.pumpAndSettle();
      expect(find.byType(ChatAttachmentThumbnail), findsOneWidget);
      await tester.tap(find.byTooltip('Remove attachment'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatAttachmentThumbnail), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
