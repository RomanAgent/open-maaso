import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:sembast/sembast_memory.dart';

const _priorUser = '我昨天说过我喜欢海边。';
const _priorReply = '记住了，你喜欢海边。';
const _newUser = '我们继续刚才的话题吧';
const _newReply = '好呀，我们继续聊你喜欢的海边。';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentRuntime runtime;
  late HomeController home;
  late AgentReplyPresentationService presentation;
  late _OfflineReplyLlm llm;
  late DesktopWindowModeController window;
  late _RecordingPetHost host;
  final audioEventChannels = <MethodChannel>[];

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in const [
      MethodChannel('xyz.luan/audioplayers.global'),
      MethodChannel('xyz.luan/audioplayers.global/events'),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final arguments = call.arguments as Map;
          final events = MethodChannel(
            'xyz.luan/audioplayers/events/${arguments['playerId']}',
          );
          audioEventChannels.add(events);
          messenger.setMockMethodCallHandler(events, (_) async => null);
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    for (final channel in [
      const MethodChannel('xyz.luan/audioplayers.global'),
      const MethodChannel('xyz.luan/audioplayers.global/events'),
      const MethodChannel('xyz.luan/audioplayers'),
      ...audioEventChannels,
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => switch (call.method) {
            'getLanguages' => <String>['zh-CN'],
            'getVoices' => <Object>[],
            'getCurrentPosition' => 0,
            _ => 1,
          },
        );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'desktop-home-bubble-${DateTime.now().microsecondsSinceEpoch}',
    );
    final profile = AgentProfile(
      nickname: 'Maaso',
      avatar: '',
      bio: 'test',
      personalityTraits: const ['warm'],
      catchphrase: 'ok',
    );
    await database.saveAgentProfile(profile);
    for (final entry in [(true, _priorUser), (false, _priorReply)]) {
      await database.saveChatMessage(
        ChatMessage(
          sessionId: 'self',
          senderId: entry.$1 ? 'user' : 'self',
          receiverId: entry.$1 ? 'self' : 'user',
          content: entry.$2,
          timestamp: DateUtils.dateOnly(
            DateTime.now(),
          ).add(Duration(minutes: entry.$1 ? 0 : 1)),
          isUserMessage: entry.$1,
          turnOrigin: ChatMessageTurnOrigins.user,
        ),
      );
    }
    appServices.put(database);
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
    appServices.put(AgentTaskJobStore());
    appServices.put(ShortTermMemory());
    presentation = appServices.put(AgentReplyPresentationService());
    llm = _OfflineReplyLlm();
    // Keep the production conversation controller and presentation hook intact.
    // Only the model response and external native-window boundary are fakes.
    runtime = AgentRuntime(
      agentId: 'self',
      profile: profile,
      llmClient: llm,
      conversationDeliveryMode: ConversationDeliveryMode.text,
      prepareTtsForNewTurn: (_) async {},
    );
    await runtime.init(enabledSkillIds: const {});
    appServices.put<AgentRuntimeRegistry>(_SingleRuntimeRegistry(runtime));
    appServices.put<AgentCoreController>(_ReadyCore(profile));
    home = appServices.put(HomeController());
    window = DesktopWindowModeController(gateway: _IndependentWindow());
    host = _RecordingPetHost();
    await window.enterPetMode();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await appServices.delete<HomeController>(force: true);
    await runtime.retireAndDrain().timeout(const Duration(seconds: 4));
    window.dispose();
    await appServices.reset();
    await database.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  testWidgets(
    'Mac Home sends one contextual turn to both history and the native pet bubble',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: appProviderContainer,
            child: MaterialApp(
              home: DesktopCompanionShell(
                windowController: window,
                autoEnterPetMode: false,
                keepAppWindowWithPet: true,
                currentRoute: () => '/home',
                hostGateway: host,
                replyPresentation: presentation,
                child: const HomePage(),
              ),
            ),
          ),
        );
        await _pumpUntil(tester, () => host.calls.contains('show'));
        await _pumpUntil(
          tester,
          () => find.text(_priorReply).evaluate().isNotEmpty,
        );
        expect(appServices.isRegistered<U2aChatController>(), isFalse);
        expect(
          find.byKey(const ValueKey('desktop-home-chat-history')),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField), _newUser);
        final composer = tester.widget<ChatInputBar>(find.byType(ChatInputBar));
        await tester.runAsync(() async {
          final published = runtime.onConversationMessage.firstWhere(
            (message) => !message.isUserMessage && message.content == _newReply,
          );
          composer.onSend();
          await published.timeout(const Duration(seconds: 5));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (home.isThinking.value) {
            if (DateTime.now().isAfter(deadline)) {
              throw TimeoutException('Home conversation did not finish');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        });
        await _pumpUntil(
          tester,
          () => host.calls.contains('bubble:$_newReply'),
        );
        await _pumpUntil(
          tester,
          () => find.text(_newReply).evaluate().isNotEmpty,
        );

        expect(llm.requests, hasLength(1));
        // Production quotes historical turns as data inside one context block.
        final prompt = llm.requests.single
            .map((message) => message.content)
            .join('\n');
        expect(
          prompt,
          allOf(
            contains(_priorUser),
            contains(_priorReply),
            contains(_newUser),
          ),
        );
        expect(presentation.snapshot.text, _newReply);
        expect(home.latestBubble.value, _newReply);
        expect(home.latestBubbleAt, isNotNull);
        expect(
          home.latestBubbleAt!.difference(DateTime.now()).abs(),
          lessThan(const Duration(seconds: 10)),
        );
        final rows = (await tester.runAsync(
          () => database.getMessages('self'),
        ))!;
        expect(rows.map((message) => message.content), [
          _priorUser,
          _priorReply,
          _newUser,
          _newReply,
        ]);
        expect(rows.last.turnId, rows[2].turnId);
        expect(rows.last.turnId, isNotNull);
        expect(find.byType(MessageBubble), findsNWidgets(4));
        expect(host.calls, isNot(contains('hide')));
        expect(appServices.isRegistered<U2aChatController>(), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  throw TimeoutException('Home/native pet did not publish the expected state');
}

class _ReadyCore extends AgentCoreController {
  _ReadyCore(this.readyProfile);
  final AgentProfile readyProfile;
  @override
  // This fixture supplies a loaded profile without the unrelated boot ceremony.
  // ignore: must_call_super
  void onInit() => profile.value = readyProfile;
}

class _SingleRuntimeRegistry extends AgentRuntimeRegistry {
  _SingleRuntimeRegistry(this.runtime);
  final AgentRuntime runtime;
  @override
  AgentRuntime? get(String agentId) => agentId == 'self' ? runtime : null;
  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async => runtime;
}

class _OfflineReplyLlm extends LLMClient {
  final requests = <List<Message>>[];
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('Unexpected aggregate model request');
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('Unexpected model routing request');
  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    requests.add(List<Message>.of(messages));
    final reply = jsonEncode({
      'actions': [
        {'type': 'reply.utterance', 'text': _newReply, 'after': 'finish'},
      ],
      'reply': _newReply,
    });
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode({'delta': reply}),
    );
    yield const LLMStreamEvent(event: 'done', data: '[DONE]');
  }
}

final class _IndependentWindow
    implements DesktopWindowGateway, IndependentDesktopPetWindowGateway {
  @override
  bool get isSupported => true;
  @override
  bool get supportsIndependentPetWindow => true;
  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 20, top: 20, width: 1000, height: 700);
  @override
  Future<void> enterPetMode() async {}
  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {}
  @override
  Future<void> startDragging() async {}
}

final class _RecordingPetHost implements DesktopCompanionHostGateway {
  final calls = <String>[];
  @override
  bool get isSupported => true;
  @override
  Future<void> initialize({
    required FutureOr<void> Function(String id) onMenuSelected,
    required FutureOr<void> Function(DesktopCompanionHostCommand command)
    onCommand,
    required FutureOr<void> Function(Offset? gaze) onGazeChanged,
    required FutureOr<void> Function(DesktopAvatarInteractionV1 interaction)
    onInteraction,
  }) async {}
  @override
  Future<void> configureMenu(List<DesktopCompanionHostMenuItem> items) async {}
  @override
  Future<void> configurePresentation(
    DesktopCompanionPresentationConfigV1 config,
  ) async {}
  @override
  Future<void> show({required int interactionGeneration}) async =>
      calls.add('show');
  @override
  Future<void> hide() async => calls.add('hide');
  @override
  Future<void> showBubble(String text) async => calls.add('bubble:$text');
  @override
  Future<void> clearBubble() async => calls.add('clearBubble');
  @override
  Future<void> dispose() async {}
}
