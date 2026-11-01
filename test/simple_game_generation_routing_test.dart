import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'project_build_v2_delivery_test.dart' as delivery;

const _layoutResponse = r'''
{"title":"Space game","summary":"Collect coins and restart.",
"skillInstructions":"Collect coins; Restart starts a new round.",
"interfaces":"Canvas #game and button #restart; local CPU gameplay.",
"files":[
  {"id":"layout","kind":"html","purpose":"Playable screen and restart control","dependsOn":[]},
  {"id":"style","kind":"css","purpose":"Responsive game and controls","dependsOn":["layout"]},
  {"id":"gameplay","kind":"js","purpose":"Coin collection, local CPU opponent and restart","dependsOn":["layout","style"]}
],"planComplete":true}
''';

const _gameRequest = '创建一个全屏离线小游戏，让我驾驶飞船收集金币，JavaScript 实现合法的本地 CPU 对手和重新开始';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'getLanguages') return <String>['en-US'];
          if (call.method == 'getVoices') return <Object>[];
          return 1;
        });
  });

  tearDown(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  for (final request in const [
    _gameRequest,
    '生成一个底下有个杠，球会掉下来然后弹上去的小游戏',
    '生成一个可触摸的弹球小游戏，需要设置球的速度，确认后开始，删除障碍后回到这个菜单',
  ]) {
    for (final creationReady in [false, true]) {
      test(
        'readiness=$creationReady starts source generation for "$request"',
        () async {
          final backend = delivery.Harness(
            appletScope: AppletLocalOwnership.currentScopeKey(),
          );
          await backend.init(enabled: true);
          backend.creationReady = creationReady;
          appServices.put(backend.db);
          appServices.put(backend.jobs);
          final builds = appServices.put(backend.tasks);
          final model = _BlockedGenerationModel();
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
          );
          addTearDown(() async {
            if (!model.reply.isCompleted) {
              model.reply.complete(_layoutResponse);
            }
            await runtime.retireAndDrain();
            runtime.dispose();
            await backend.close();
          });

          expect(builds.enableCreation, isTrue);
          expect(builds.canSubmit, creationReady);
          final response = await runtime.chat(request, const []);
          expect(response.isSuccess, isTrue, reason: response.stderr);
          await model.started.future.timeout(const Duration(seconds: 5));

          final job = backend.jobs.jobs.single;
          expect(job.userText, request);
          expect(job.taskKind.name, 'gameGeneration');
          expect(job.isServerBacked, isFalse);
          expect(job.projectBuildV2, isNull);
          expect(backend.posts, isEmpty);
          expect(model.calls, hasLength(1));
          expect(model.calls.single.last.role, 'user');
          expect(model.calls.single.last.content, request);
          final prompt = model.calls.single
              .map((message) => message.content)
              .join('\n')
              .replaceAll(RegExp(r'\s+'), ' ');
          expect(prompt, contains('finite dependency plan and source files'));
          expect(prompt, contains('title:string'));
          expect(prompt, contains('files:[{id:string,kind:"html"|"css"|"js"'));
          expect(prompt, contains('dependsOn:[fileId]'));
          expect(prompt, contains('planComplete:boolean'));
          expect(
            prompt,
            contains('Do not return reply/actions or source code'),
          );
          expect(prompt, isNot(contains('surface.show')));
          expect(prompt, isNot(contains('[policy:')));
          expect(prompt, isNot(contains('FreeformSurface')));
          expect(prompt, isNot(contains('workerCanvas')));
          expect(prompt, contains('game.state'));
          expect(prompt, contains('game.event'));
          expect(prompt, contains('legal local CPU code'));
          expect(prompt, contains('voice companion, never a live game player'));

          final cancelled = runtime.cancelBackgroundTaskJob(job.id);
          model.reply.complete(_layoutResponse);
          await cancelled;
          await runtime.retireAndDrain();
          expect(backend.posts, isEmpty);
        },
      );
    }
  }
}

class _BlockedGenerationModel implements LLMClient {
  final calls = <List<Message>>[];
  final started = Completer<void>();
  final reply = Completer<String>();

  @override
  Duration get defaultTimeout => const Duration(seconds: 10);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    calls.add(List<Message>.unmodifiable(messages));
    if (!started.isCompleted) started.complete();
    return reply.future;
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw StateError('Unexpected native tool request');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Unexpected JSON generation request');

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode({'delta': await chat(messages, timeout: timeout)}),
    );
  }
}
