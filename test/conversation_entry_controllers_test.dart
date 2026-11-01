import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_recovery_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_turn_input.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:sembast/sembast_memory.dart';

const _deadline = Duration(seconds: 3);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationEntryHarness harness;
  setUp(() async {
    await appServices.reset();
    harness = await ConversationEntryHarness.create();
  });
  tearDown(() async => harness.close());

  for (final entry in ['home', 'chat', 'companion']) {
    test(
      '$entry merges rapid sends while retaining each visible user row',
      () async {
        var generated = 0;
        harness.runtime.runChat = (context, history) async {
          generated++;
          expect(context.inputTexts, ['hello', '还有一句']);
          expect(context.text, 'hello\n还有一句');
          return ExecutionResult.success('听完了，一起回应');
        };
        harness.input(entry).text = 'hello';
        final first = harness.send(entry);
        // Let the entry clear its composer and finish synchronous submission.
        await Future<void>.delayed(Duration.zero);
        harness.input(entry).text = '还有一句';
        final second = harness.send(entry);
        await Future.wait([first, second]).timeout(_deadline);
        expect(generated, 1);
        expect(harness.runtime.submissions, 2);
        final rows = await harness.database.getMessages('self');
        expect(rows.map((row) => row.content), ['hello', '还有一句', '听完了，一起回应']);
        expect(rows.map((row) => row.turnId).toSet(), hasLength(1));
        expect(harness.busy(entry), isFalse);
        if (entry == 'home') {
          expect(harness.home.latestBubble.value, '听完了，一起回应');
        } else if (entry == 'chat') {
          expect(
            harness.chat.messages.map((row) => row.content),
            rows.map((row) => row.content),
          );
        } else {
          expect(harness.companion.latestReply, '听完了，一起回应');
        }
      },
    );

    test(
      '$entry publishes three durable rows without final aggregate',
      () async {
        harness.input(entry).text = 'hello';
        await harness.send(entry).timeout(_deadline);
        final rows = await harness.database.getMessages('self');
        final assistants = rows.where((row) => !row.isUserMessage).toList();

        expect(rows, hasLength(4));
        expect(rows.where((row) => row.isUserMessage), hasLength(1));
        expect(assistants.map((row) => row.content), ['A', 'B', 'C']);
        expect(assistants.map((row) => row.sequence), [0, 1, 2]);
        expect(rows.map((row) => row.turnId).toSet(), hasLength(1));
        expect(rows.map((row) => row.id).toSet(), hasLength(4));
        expect(harness.busy(entry), isFalse);
        expect(harness.runtime.submissions, 1);
        if (entry == 'chat') {
          expect(
            harness.chat.messages.map((row) => row.id),
            rows.map((row) => row.id),
          );
        } else if (entry == 'home') {
          expect(harness.home.latestBubble.value, 'C');
          expect(harness.home.conversationRevision.value, 4);
        } else {
          expect(harness.companion.latestReply, 'C');
        }
      },
    );

    test('$entry replacement preserves new busy after old finally', () async {
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final firstTail = Completer<void>();
      final secondTail = Completer<void>();
      harness.runtime.runChat = (context, history) async {
        if (context.text == 'first') {
          firstStarted.complete();
          await firstTail.future;
        } else {
          secondStarted.complete();
          await secondTail.future;
        }
        await context.deliver([
          ConversationUtteranceDraft(text: '${context.text} reply'),
        ]);
        return ExecutionResult.success('must not duplicate');
      };
      addTearDown(() {
        if (!firstTail.isCompleted) firstTail.complete();
        if (!secondTail.isCompleted) secondTail.complete();
      });

      harness.input(entry).text = 'first';
      final first = harness.send(entry);
      await firstStarted.future.timeout(_deadline);
      harness.input(entry).text = 'second';
      final second = harness.send(entry);
      await secondStarted.future.timeout(_deadline);
      await first.timeout(_deadline);
      expect(harness.busy(entry), isTrue);

      firstTail.complete();
      await Future<void>.delayed(Duration.zero);
      expect(harness.busy(entry), isTrue);
      secondTail.complete();
      await second.timeout(_deadline);
      expect(harness.busy(entry), isFalse);
      final rows = await harness.database.getMessages('self');
      expect(rows.where((row) => row.isUserMessage), hasLength(2));
      expect(
        rows.where((row) => !row.isUserMessage).map((row) => row.content),
        ['second reply'],
      );
    });

    test(
      '$entry actual draft pauses optional gap and clearing resumes',
      () async {
        final firstPublished = Completer<void>();
        final subscription = harness.runtime.onConversationMessage.listen((
          message,
        ) {
          if (!message.isUserMessage && !firstPublished.isCompleted) {
            harness.input(entry).text = 'my answer';
            firstPublished.complete();
          }
        });
        addTearDown(subscription.cancel);
        harness.runtime.runChat = (context, history) async {
          await context.deliver([
            ConversationUtteranceDraft(
              text: 'A',
              after: ConversationAfter.optional,
            ),
            ConversationUtteranceDraft(text: 'B'),
          ]);
          return ExecutionResult.success('must not duplicate');
        };
        harness.input(entry).text = 'start';
        final turn = harness.send(entry);
        await firstPublished.future.timeout(_deadline);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          (await harness.database.getMessages(
            'self',
          )).where((row) => !row.isUserMessage),
          hasLength(1),
        );
        expect(harness.busy(entry), isTrue);

        harness.input(entry).clear();
        await turn.timeout(_deadline);
        expect(
          (await harness.database.getMessages(
            'self',
          )).where((row) => !row.isUserMessage).map((row) => row.content),
          ['A', 'B'],
        );
      },
    );

    test('$entry selection changes do not edit shared conversation draft', () {
      harness.runtime.draftChanges.clear();
      harness.input(entry).text = 'draft';
      expect(harness.runtime.draftChanges, ['draft']);
      harness.input(entry).selection = const TextSelection.collapsed(offset: 2);
      expect(harness.runtime.draftChanges, ['draft']);
      harness.input(entry).clear();
      expect(harness.runtime.draftChanges, ['draft', '']);
    });

    test('$entry empty Stop does not submit or write a user row', () async {
      harness.input(entry).text = '  ';
      await harness.send(entry);
      harness.stop(entry);
      await Future<void>.delayed(Duration.zero);
      expect(harness.runtime.submissions, 0);
      expect(await harness.database.getMessages('self'), isEmpty);
    });

    test(
      '$entry synchronous admission failure clears its busy state',
      () async {
        harness.runtime.rejectSubmission = true;
        harness.input(entry).text = 'hello';
        await expectLater(harness.send(entry), throwsStateError);
        expect(harness.busy(entry), isFalse);
        expect(await harness.database.getMessages('self'), isEmpty);
      },
    );

    testWidgets(
      '$entry generation failure shows a local notice without an assistant row',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Stack(children: [AppTopNoticeHost()])),
          ),
        );
        final expectedNotice = AgentPromptCatalog.text(
          'app.home.direct_chat_error',
          locale: AgentPromptCatalog.currentLocale,
        );
        harness.runtime.runChat = (context, history) async =>
            ExecutionResult.error('synthetic_failure_detail');
        await tester.runAsync(() async {
          harness.input(entry).text = 'hello';
          await harness.send(entry).timeout(_deadline);
          final rows = await harness.database.getMessages('self');
          expect(rows, hasLength(1));
          expect(rows.single.isUserMessage, isTrue);
          expect(rows.single.content, 'hello');
          expect(harness.busy(entry), isFalse);
        });
        await tester.pump();
        expect(find.text(expectedNotice), findsOneWidget);
        expect(find.text('synthetic_failure_detail'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  test('closing old Home entry cannot cancel a newer chat owner', () async {
    final started = <String, Completer<void>>{
      'home': Completer<void>(),
      'chat': Completer<void>(),
    };
    final tails = <String, Completer<void>>{
      'home': Completer<void>(),
      'chat': Completer<void>(),
    };
    harness.runtime.runChat = (context, history) async {
      started[context.text]!.complete();
      await tails[context.text]!.future;
      await context.deliver([
        ConversationUtteranceDraft(text: '${context.text} reply'),
      ]);
      return ExecutionResult.success('must not duplicate');
    };
    addTearDown(() {
      for (final tail in tails.values) {
        if (!tail.isCompleted) tail.complete();
      }
    });
    harness.home.inputController.text = 'home';
    final first = harness.home.send();
    await started['home']!.future.timeout(_deadline);
    harness.chat.inputController.text = 'chat';
    final second = harness.chat.sendMessage();
    await started['chat']!.future.timeout(_deadline);
    await first.timeout(_deadline);
    await appServices.delete<HomeController>(force: true);
    expect(harness.runtime.manager.hasActiveTurn, isTrue);
    tails['home']!.complete();
    tails['chat']!.complete();
    await second.timeout(_deadline);
    expect(
      (await harness.database.getMessages(
        'self',
      )).where((row) => !row.isUserMessage).map((row) => row.content),
      ['chat reply'],
    );
  });

  for (final boundary in ['voice off', 'companion off', 'page exit']) {
    test(
      'typed game question passes session voice permission through $boundary',
      () async {
        final oldSound = MaasoTtsPlugin.soundEnabled.value;
        MaasoTtsPlugin.soundEnabled.value = false;
        addTearDown(() => MaasoTtsPlugin.soundEnabled.value = oldSound);
        final games = appServices.put(
          GameVoiceCompanionService(
            browsingContext: CompanionBrowsingContextService(),
            commentary: (_, {required isCurrent, required onRevoked}) async =>
                false,
          ),
        );
        final session = games.openSession(
          scopeKey: 'owner-a',
          playerId: 'game-a',
          title: 'Puzzle',
          summary: '',
          isCurrent: () => true,
        );
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        harness.runtime.runChat = (context, history) async {
          entered.complete();
          await release.future;
          return ExecutionResult.success('Text remains available.');
        };
        harness.input('companion').text = 'Tell me a joke';
        final sending = harness.send('companion');
        await entered.future.timeout(_deadline);
        final permission = harness.runtime.speechPermissions.single;
        expect(permission.allowed, isNotNull);
        expect(permission.allowed!(), isTrue);
        expect(permission.revoked, isNotNull);
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
        if (boundary == 'voice off') {
          games.setSpokenRepliesEnabled(false);
        } else if (boundary == 'companion off') {
          games.setPreferences(games.preferences.copyWith(enabled: false));
        } else {
          session.close();
        }
        await permission.revoked!.timeout(_deadline);
        expect(permission.allowed!(), isFalse);
        if (boundary == 'page exit') {
          games.openSession(
            scopeKey: 'owner-a',
            playerId: 'game-b',
            title: 'New game',
            summary: '',
            isCurrent: () => true,
          );
          expect(games.currentSession!.spokenRepliesEnabled, isTrue);
          expect(permission.allowed!(), isFalse);
        }
        release.complete();
        await sending.timeout(_deadline);
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      },
    );
  }

  for (final initiallyEnabled in [true, false]) {
    test(
      'typed question cannot acquire a new voice epoch after DOM wait: $initiallyEnabled',
      () async {
        final oldSound = MaasoTtsPlugin.soundEnabled.value;
        MaasoTtsPlugin.soundEnabled.value = false;
        addTearDown(() => MaasoTtsPlugin.soundEnabled.value = oldSound);
        final games = appServices.put(
          GameVoiceCompanionService(
            browsingContext: CompanionBrowsingContextService(),
            commentary: (_, {required isCurrent, required onRevoked}) async =>
                false,
          ),
        );
        final reading = Completer<void>(), visible = Completer<String?>();
        addTearDown(() {
          if (!visible.isCompleted) visible.complete(null);
        });
        final session = games.openSession(
          scopeKey: 'owner-a',
          playerId: 'game-a',
          title: 'Puzzle',
          summary: '',
          isCurrent: () => true,
          readVisibleText: () {
            if (!reading.isCompleted) reading.complete();
            return visible.future;
          },
        );
        games.setSpokenRepliesEnabled(initiallyEnabled);
        final originalEpoch = session.onSpeechRevoked;
        expect(harness.runtime.usesConversationTurns, isTrue);
        harness.input('companion').text = 'Tell me a joke';
        final sending = harness.send('companion');
        await reading.future.timeout(_deadline);
        expect(harness.runtime.speechPermissions, isEmpty);
        if (initiallyEnabled) games.setSpokenRepliesEnabled(false);
        games.setSpokenRepliesEnabled(true);
        await originalEpoch.timeout(_deadline);
        expect(session.onSpeechRevoked, isNot(same(originalEpoch)));
        visible.complete('A puzzle is visible.');
        await sending.timeout(_deadline);
        final old = harness.runtime.speechPermissions.single;
        expect(old.revoked, same(originalEpoch));
        expect(old.allowed!(), isFalse);
        await old.revoked!.timeout(_deadline);
        harness.input('companion').text = 'Tell me another joke';
        await harness.send('companion').timeout(_deadline);
        expect(harness.runtime.speechPermissions, hasLength(2));
        expect(harness.runtime.speechPermissions.last.allowed!(), isTrue);
        expect(
          harness.runtime.speechPermissions.last.revoked,
          same(session.onSpeechRevoked),
        );
        expect(old.allowed!(), isFalse);
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      },
    );
  }

  test('ordinary companion question has no game voice override', () async {
    final oldSound = MaasoTtsPlugin.soundEnabled.value;
    MaasoTtsPlugin.soundEnabled.value = false;
    addTearDown(() => MaasoTtsPlugin.soundEnabled.value = oldSound);
    harness.input('companion').text = 'hello';
    await harness.send('companion').timeout(_deadline);
    final permission = harness.runtime.speechPermissions.single;
    expect(permission.allowed, isNull);
    expect(permission.revoked, isNull);
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
  });

  test(
    'closing Home inside the input window preserves the newer chat owner',
    () async {
      harness.runtime.runChat = (context, history) async {
        // Home supplies an explicit applet scope; chat retains its own admission
        // scope. Their pending input must remain separately sourced turns.
        expect(context.inputTexts, ['chat']);
        return ExecutionResult.success('chat reply');
      };
      harness.home.inputController.text = 'home';
      final first = harness.home.send();
      await Future<void>.delayed(Duration.zero);
      harness.chat.inputController.text = 'chat';
      final second = harness.chat.sendMessage();
      await Future<void>.delayed(Duration.zero);
      await appServices.delete<HomeController>(force: true);
      await Future.wait([first, second]).timeout(_deadline);
      expect(harness.chat.messages.map((row) => row.content), [
        'chat',
        'chat reply',
      ]);
      expect(
        (await harness.database.getMessages('self')).map((row) => row.content),
        ['home', 'chat', 'chat reply'],
      );
    },
  );
}

class ConversationEntryHarness {
  // Test fixture; the local runtime fake is never an application API.
  ConversationEntryHarness(
    this.database,
    // ignore: library_private_types_in_public_api
    this.runtime,
    this.home,
    this.chat,
    this.companion,
  );
  final DBService database;
  // ignore: library_private_types_in_public_api
  final _EntryRuntime runtime;
  final HomeController home;
  final U2aChatController chat;
  final CompanionVoiceSessionController companion;

  static Future<ConversationEntryHarness> create() async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'conversation-entry-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final profile = AgentProfile(
      nickname: 'Maaso',
      avatar: '',
      bio: '',
      personalityTraits: const [],
      catchphrase: '',
    );
    await database.saveAgentProfile(profile);
    final runtime = _EntryRuntime(profile);
    final registry = _EntryRegistry(runtime);
    appServices.put<DBService>(database);
    appServices.put<AgentRuntimeRegistry>(registry);
    appServices.put(AgentTaskJobStore());
    appServices.put<AgentCoreController>(_EntryCore(profile));
    final home = appServices.put(HomeController());
    final chat = appServices.put(U2aChatController());
    final companion = CompanionVoiceSessionController(
      database: database,
      runtimeRegistry: registry,
    )..activate();
    // Finish the controllers' initial DB reads before exercising publication.
    await Future<void>.delayed(Duration.zero);
    return ConversationEntryHarness(database, runtime, home, chat, companion);
  }

  TextEditingController input(String entry) => switch (entry) {
    'home' => home.inputController,
    'chat' => chat.inputController,
    _ => companion.inputController,
  };
  Future<void> send(String entry) => switch (entry) {
    'home' => home.send(),
    'chat' => chat.sendMessage(),
    _ => companion.sendVoiceMessage(),
  };
  bool busy(String entry) => switch (entry) {
    'home' => home.isThinking.value,
    'chat' => chat.isReplyActive.value || chat.isTyping.value,
    _ => companion.isThinking,
  };
  void stop(String entry) {
    switch (entry) {
      case 'home':
        home.cancelCurrent();
      case 'chat':
        chat.interruptCurrent();
      default:
        companion.interruptCurrent();
    }
  }

  Future<void> close() async {
    companion.dispose();
    await appServices.delete<HomeController>(force: true);
    await appServices.delete<U2aChatController>(force: true);
    await runtime.manager.retireAndDrain().timeout(_deadline);
    runtime.dispose();
    await appServices.reset();
    await database.close();
  }
}

class _EntryCore extends AgentCoreController {
  _EntryCore(this.testProfile);
  final AgentProfile testProfile;
  @override
  // The fixture owns its profile and does not run the startup ceremony.
  // ignore: must_call_super
  void onInit() {
    profile.value = testProfile;
  }
}

class _EntryRegistry extends AgentRuntimeRegistry {
  _EntryRegistry(this.runtime);
  final AgentRuntime runtime;
  @override
  AgentRuntime? get(String agentId) => runtime;
  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async => runtime;
}

class _EntryRuntime extends AgentRuntime {
  _EntryRuntime(AgentProfile profile)
    : super(agentId: 'self', profile: profile, llmClient: _UnusedLlmClient()) {
    manager = ConversationTurnController(
      agentId: 'self',
      runChat: (context, history) => runChat(context, history),
      stopOutput: () async {},
      isAvailable: () => true,
      briefPause: Duration.zero,
      invitationPause: Duration.zero,
    );
  }
  late final ConversationTurnController manager;
  RunConversationChat runChat = (context, history) async {
    await context.deliver([
      ConversationUtteranceDraft(
        text: 'A',
        after: ConversationAfter.continueReply,
      ),
      ConversationUtteranceDraft(text: 'B', after: ConversationAfter.optional),
      ConversationUtteranceDraft(text: 'C'),
    ]);
    return ExecutionResult.success('must not duplicate');
  };
  int submissions = 0;
  final speechPermissions =
      <({bool Function()? allowed, Future<void>? revoked})>[];
  bool rejectSubmission = false;
  final draftChanges = <String>[];
  @override
  bool get usesConversationTurns => true;
  @override
  Stream<ChatMessage> get onConversationMessage => manager.messages;
  @override
  ConversationTurnHandle submitConversation(
    String text, {
    required DBService database,
    String? sessionId,
    TurnOrigin origin = TurnOrigin.user,
    String? submissionToken,
    String? expectedAppletScopeKey,
    List<Message> extraContext = const [],
    List<ChatAttachment> attachments = const [],
    String? visualContext,
    void Function(ChatMessage)? onMessage,
    bool respondImmediately = false,
    bool allowInputMerge = true,
    AppInvocationTurnInput? invocation,
    AppInvocationRecoveryInput? recovery,
    bool Function()? spokenRepliesAllowed,
    Future<void>? onSpeechRevoked,
  }) {
    if (rejectSubmission) throw StateError('test_admission_rejected');
    speechPermissions.add((
      allowed: spokenRepliesAllowed,
      revoked: onSpeechRevoked,
    ));
    submissions++;
    return manager.submit(
      text,
      database: database,
      sessionId: sessionId,
      origin: origin,
      submissionToken: submissionToken,
      expectedAppletScopeKey: expectedAppletScopeKey,
      extraContext: extraContext,
      attachments: attachments,
      visualContext: visualContext,
      onMessage: onMessage,
      respondImmediately: respondImmediately,
      allowInputMerge: allowInputMerge,
    );
  }

  @override
  void updateConversationDraft(String text) {
    draftChanges.add(text);
    manager.updateDraft(text);
  }

  @override
  Future<void> interruptConversation() => manager.cancelCurrent();
}

class _UnusedLlmClient implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
