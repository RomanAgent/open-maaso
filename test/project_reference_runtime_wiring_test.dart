import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'project_build_reference_chain_test.dart' show ReferenceHarness;
import 'package:maaso/src/features/project_build/domain/project_reference_selection.dart';

import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;

class _RuntimeReferences extends ReferenceHarness {
  @override
  String get appletScope => AppletLocalOwnership.currentScopeKey();
  @override
  Future<http.Response> referenceHTTP(http.Request request) {
    // This suite verifies runtime-to-durable-admission wiring. Server task
    // identity/replay is tested independently by ReferenceHarness's tests.
    if (request.url.path == '/v1/project-builds/v2' &&
        request.method == 'POST') {
      throw http.ClientException('test server offline after upload');
    }
    return super.referenceHTTP(request);
  }
}

class _NoModel implements LLMClient {
  int calls = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    throw StateError('Unexpected generation model call');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PreparedChatMedia _image(int red) {
  final value = image.Image(width: 16, height: 16);
  image.fill(value, color: image.ColorRgb8(red, 32, 64));
  return normalizeChatImage(Uint8List.fromList(image.encodePng(value)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'getLanguages') return <String>['en-US'];
          if (call.method == 'getVoices') return <Object>[];
          return 1;
        });
  });
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() async {
    await appServices.reset();
  });

  for (final conversation in [false, true]) {
    test(
      'V2 raw selection survives ${conversation ? 'conversation' : 'legacy entry'} and duplicate followup',
      () async {
        final h = _RuntimeReferences();
        await h.init();
        final db = h.db;
        appServices.put(db);
        appServices.put(h.jobs);
        appServices.put(h.media);
        final builds = appServices.put(h.tasks);
        final model = _NoModel();
        final runtime = AgentRuntime(
          agentId: 'self',
          profile: AgentProfile(
            nickname: 'Maaso',
            avatar: '',
            bio: '',
            personalityTraits: const [],
            catchphrase: '',
          ),
          llmClient: model,
          conversationDeliveryMode: conversation
              ? ConversationDeliveryMode.text
              : ConversationDeliveryMode.legacy,
        );
        addTearDown(runtime.dispose);
        final first = await builds.captureReferences([_image(20)]);
        Future<ExecutionResult> send(
          String text,
          ProjectReferenceSelection? selection,
        ) => runtime.withProjectReferenceInput(
          null,
          () async {
            if (!conversation) return runtime.chat(text, const []);
            final result = await runtime
                .submitConversation(
                  text,
                  database: db,
                  expectedAppletScopeKey: first.scopeKey,
                  respondImmediately: true,
                  attachments: selection == null
                      ? const []
                      : [_image(20).attachment],
                )
                .done;
            return result.execution;
          },
          referenceSelection: selection,
          hasReferenceMedia: selection != null,
        );
        const request = '创建一个有待办和统计二级页面的小程序';
        expect((await send(request, first)).isSuccess, isTrue);
        expect(
          h.jobs.jobs.single.projectBuildV2!.referenceSelectionDigest,
          first.sourceIdentityDigest,
        );
        await send(request, first);
        expect(h.jobs.jobs, hasLength(1));
        final duplicateResult = await send('新建一个版本', null);
        expect(
          duplicateResult.isSuccess,
          isTrue,
          reason: duplicateResult.stderr,
        );
        expect(h.jobs.jobs, hasLength(2));
        expect(
          h.jobs.jobs.last.projectBuildV2!.referenceSelectionDigest,
          first.sourceIdentityDigest,
        );
        final second = await builds.captureReferences([_image(180)]);
        await send(request, second);
        expect(h.jobs.jobs, hasLength(3));
        expect(
          h.jobs.jobs.last.projectBuildV2!.referenceSelectionDigest,
          second.sourceIdentityDigest,
        );
        expect(model.calls, 0);
        await runtime.retireAndDrain();
        await h.close();
      },
    );
  }

  for (final cancel in [false, true]) {
    test(
      'Home explicit V2 image creation ${cancel ? 'retains stopped input' : 'bypasses unavailable analysis'}',
      () async {
        final harness = await ConversationEntryHarness.create();
        final h = _RuntimeReferences();
        await h.init();
        final media = appServices.put(h.media);
        appServices.put(h.tasks);
        final item = _image(60);
        harness.home.pendingMedia.add(item);
        const text = '创建一个参考图片风格的小程序';
        harness.input('home').text = text;
        final send = harness.send('home');
        if (cancel) harness.stop('home');
        await send;
        expect(h.analyses, 0);
        if (!cancel) {
          expect((await media.read(item.attachment))!.bytes, item.bytes);
        }
        expect(harness.runtime.submissions, cancel ? 0 : 1);
        expect(harness.home.pendingMedia, cancel ? hasLength(1) : isEmpty);
        if (cancel) expect(harness.input('home').text, text);
        await harness.close();
        await h.close();
      },
    );
  }
}
