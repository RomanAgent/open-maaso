import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'project_build_v2_delivery_test.dart' as delivery;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late delivery.Harness harness;
  late AgentRuntime runtime;
  late _NoForegroundGeneration model;
  setUp(() async {
    appServices.testMode = true;
    appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    appServices.put(SecureStorageService());
    appServices.put(MaasoAgentModeService()).pipelineMode.value =
        AgentPipelineMode.proxyDefault;
    harness = delivery.Harness(appletScope: 'device-legacy');
    await harness.init();
    appServices.put(harness.db);
    appServices.put(harness.jobs);
    appServices.put(harness.tasks);
    model = _NoForegroundGeneration();
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Test',
        avatar: '',
        bio: '',
        personalityTraits: [],
        catchphrase: '',
      ),
      llmClient: model,
      prepareTtsForNewTurn: (_) async {},
    );
    await runtime.init();
    MaasoTtsPlugin.soundEnabled.value = false;
  });
  tearDown(() async {
    await runtime.retireAndDrain();
    await harness.close();
    appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  test(
    'explicit project request creates one durable V2 card without local generation',
    () async {
      final result = await runtime.chat('帮我制作一个待办清单小程序', const []);
      expect(result.isSuccess, isTrue);
      expect(harness.jobs.jobs.length, 1);
      expect(harness.jobs.jobs.single.isProjectBuildV2, isTrue);
      expect(model.calls, 0);
      expect(harness.jobs.jobs.single.userText, contains('待办清单'));
    },
  );

  test(
    'unready V2 creation cannot silently start the old local generator',
    () async {
      harness.creationReady = false;
      final result = await runtime.chat('帮我制作一个待办清单小程序', const []);
      // The existing chat boundary presents unavailable errors as a normal
      // user-facing reply. It must not create or run a fallback project.
      expect(result.stdout, isNotEmpty);
      expect(harness.jobs.jobs, isEmpty);
      expect(harness.posts, isEmpty);
      expect(model.calls, 0);
    },
  );

  test('user stop during authorization prevents a late new task', () async {
    final entered = Completer<void>(), released = Completer<void>();
    harness.authorizing = () {
      entered.complete();
      return released.future;
    };
    final response = runtime.chat('帮我制作一个待办清单小程序', const []);
    await entered.future;
    await runtime.interruptConversation();
    released.complete();
    await response;
    expect(harness.jobs.jobs, isEmpty);
    expect(harness.posts, isEmpty);
    expect(model.calls, 0);
  });
}

class _NoForegroundGeneration implements LLMClient {
  int calls = 0;
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    return '{"reply":"ok","actions":[]}';
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    calls++;
    return '{}';
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    calls++;
    return ChatTurnResult(
      content: '{"reply":"ok","actions":[]}',
      toolCalls: const [],
    );
  }

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
    calls++;
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"ok"}');
  }
}
