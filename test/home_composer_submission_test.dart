import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';

import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationEntryHarness harness;
  PreparedChatMedia picture() => normalizeChatImage(
    Uint8List.fromList(image.encodePng(image.Image(width: 12, height: 12))),
  );
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    harness = await ConversationEntryHarness.create();
  });
  tearDown(() async {
    appletEditReference.value = null;
    await harness.close();
  });

  test(
    'voice captures only recognized text and preserves the exact typed draft',
    () async {
      const draft = TextEditingValue(
        text: '  未发送的图片说明😀  ',
        selection: TextSelection(baseOffset: 2, extentOffset: 5),
        composing: TextRange(start: 2, end: 5),
      );
      final media = picture();
      harness.home.inputController.value = draft;
      harness.home.pendingMedia.add(media);
      harness.home.planRequested.value = true;
      final edit = AppletEditReference(
        item: AgentWidget(
          agentId: 'self',
          title: 'existing',
          createdAt: DateTime(2026),
          kind: 'surface',
          spec: {'surfaceId': 'existing'},
        ),
        scopeKey: AppletLocalOwnership.currentScopeKey(),
      );
      appletEditReference.value = edit;
      harness.runtime.runChat = (context, _) async {
        expect(context.text, '语音内容');
        expect(context.userMessage!.attachments, isEmpty);
        return ExecutionResult.success('收到');
      };
      await harness.home.sendVoiceText('  语音内容  ');
      expect(harness.home.inputController.value, draft);
      expect(harness.home.pendingMedia.single, same(media));
      expect(harness.home.planRequested.value, isTrue);
      expect(appletEditReference.value, same(edit));
      expect(
        (await harness.database.getMessages('self')).first.content,
        '语音内容',
      );
    },
  );

  test(
    'voice admission failure does not consume typed draft or attachments',
    () async {
      harness.home.inputController.text = 'typed';
      final media = picture();
      harness.home.pendingMedia.add(media);
      harness.runtime.rejectSubmission = true;
      await expectLater(harness.home.sendVoiceText('spoken'), throwsStateError);
      expect(harness.home.inputController.text, 'typed');
      expect(harness.home.pendingMedia.single, same(media));
      expect(harness.home.busy, isFalse);
    },
  );

  test('typed admission failure preserves whitespace and selection', () async {
    const draft = TextEditingValue(
      text: '  hello  ',
      selection: TextSelection(baseOffset: 2, extentOffset: 7),
    );
    harness.home.inputController.value = draft;
    harness.runtime.rejectSubmission = true;
    await expectLater(harness.home.send(), throwsStateError);
    expect(harness.home.inputController.value, draft);
  });

  test('new typed draft survives a voice turn completion', () async {
    final started = Completer<void>(), finish = Completer<void>();
    harness.home.inputController.text = 'before';
    harness.runtime.runChat = (context, _) async {
      started.complete();
      await finish.future;
      return ExecutionResult.success('done');
    };
    final send = harness.home.sendVoiceText('spoken');
    await started.future;
    harness.home.inputController.text = 'new typed draft';
    finish.complete();
    await send;
    expect(harness.home.inputController.text, 'new typed draft');
  });

  Future<void> withMedia({
    required Future<http.Response> Function(http.Request) respond,
  }) async {
    appServices.put(
      ChatMediaService(
        database: harness.database.raw,
        isCurrent: () => true,
        baseUri: Uri.parse('https://example.invalid/'),
        accessToken: () async => 'fixture',
        client: MockClient(respond),
      ),
    );
  }

  http.Response observation(http.Request request) => http.Response(
    jsonEncode({
      'code': 'OK',
      'data': {
        'description': 'fixture image',
        'sourceMediaIds': (jsonDecode(request.body)['media'] as List)
            .map((m) => m['id'])
            .toList(),
      },
    }),
    200,
  );

  test(
    'media analysis cannot clear an ABA text draft even with identical final text',
    () async {
      final entered = Completer<http.Request>(),
          finish = Completer<http.Response>();
      await withMedia(
        respond: (request) {
          entered.complete(request);
          return finish.future;
        },
      );
      harness.home.inputController.text = 'same text';
      harness.home.pendingMedia.add(picture());
      final send = harness.home.send();
      final request = await entered.future;
      harness.home.inputController.text = 'changed by user';
      harness.home.inputController.text = 'same text';
      finish.complete(observation(request));
      await send;
      expect(harness.home.inputController.text, 'same text');
      expect(harness.home.pendingMedia, isEmpty);
    },
  );

  test(
    'failed media turn restores only its own untouched consumed draft',
    () async {
      await withMedia(respond: (request) async => observation(request));
      const draft = TextEditingValue(
        text: '  restore me  ',
        selection: TextSelection(baseOffset: 2, extentOffset: 6),
      );
      harness.home.inputController.value = draft;
      final media = picture();
      harness.home.pendingMedia.add(media);
      harness.runtime.runChat = (_, _) async =>
          ExecutionResult.error('fixture_failure');
      await harness.home.send();
      expect(harness.home.inputController.value, draft);
      expect(harness.home.pendingMedia.single, same(media));
    },
  );

  test(
    'failed old media turn cannot restore over a new deliberately empty draft',
    () async {
      await withMedia(respond: (request) async => observation(request));
      final entered = Completer<void>(), finish = Completer<void>();
      harness.home.inputController.text = 'old';
      harness.home.pendingMedia.add(picture());
      harness.runtime.runChat = (_, _) async {
        entered.complete();
        await finish.future;
        return ExecutionResult.error('fixture_failure');
      };
      final send = harness.home.send();
      await entered.future;
      harness.home.inputController.text = 'new';
      harness.home.inputController.clear();
      finish.complete();
      await send;
      expect(harness.home.inputController.text, isEmpty);
      expect(harness.home.pendingMedia, hasLength(1));
    },
  );
}
