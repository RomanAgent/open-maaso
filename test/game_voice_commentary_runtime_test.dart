import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_prompt.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_commentary_runtime.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousSound = MaasoTtsPlugin.soundEnabled.value;
  tearDown(() => MaasoTtsPlugin.soundEnabled.value = previousSound);

  test('commentary accepts only bounded reply with no actions', () {
    expect(
      GameVoiceCommentaryRuntime.parseReply('{"reply":"Nice!","actions":[]}'),
      'Nice!',
    );
    for (final value in [
      '{"reply":"move","actions":[{"type":"surface.interact"}]}',
      '{"reply":"hi","actions":[],"actionToken":"move"}',
      '{"reply":"hi","actions":null}',
      '```json\n{"reply":"hi","actions":[]}\n```',
      '{"reply":"line\\nbreak","actions":[]}',
    ]) {
      expect(
        () => GameVoiceCommentaryRuntime.parseReply(value),
        throwsFormatException,
      );
    }
  });

  test('model action cannot reach playback or a game executor', () async {
    MaasoTtsPlugin.soundEnabled.value = true;
    final provider = _Provider(
      '{"reply":"move","actions":[{"type":"skill.call"}]}',
    );
    final runtime = _Runtime(provider);
    final commentary = GameVoiceCommentaryRuntime(
      runtime: () => runtime,
      isCurrent: (_) => true,
    );
    expect(
      await commentary.comment(
        _observation(),
        isCurrent: () => true,
        onRevoked: Completer<void>().future,
      ),
      isFalse,
    );
    expect(provider.calls, 1);
    expect(runtime.spoken, isEmpty);
  });

  test('privacy wait observes page revocation before provider entry', () async {
    MaasoTtsPlugin.soundEnabled.value = true;
    final entered = Completer<void>(), permission = Completer<void>();
    final provider = _Provider('{"reply":"Nice!","actions":[]}');
    final runtime = _Runtime(
      privacyGuardedLLMClient(provider, () {
        entered.complete();
        return permission.future;
      }),
    );
    var current = true;
    final commentary = GameVoiceCommentaryRuntime(
      runtime: () => runtime,
      isCurrent: (_) => current,
    );
    final result = commentary.comment(
      _observation(),
      isCurrent: () => current,
      onRevoked: Completer<void>().future,
    );
    await entered.future;
    current = false;
    permission.complete();
    expect(await result, isFalse);
    expect(provider.calls, 0);
    expect(runtime.spoken, isEmpty);
  });

  test('muted or busy runtime does not invoke the provider', () async {
    final provider = _Provider('{"reply":"Nice!","actions":[]}');
    final runtime = _Runtime(provider);
    final commentary = GameVoiceCommentaryRuntime(
      runtime: () => runtime,
      isCurrent: (_) => true,
    );
    MaasoTtsPlugin.soundEnabled.value = false;
    expect(
      await commentary.comment(
        _observation(),
        isCurrent: () => true,
        onRevoked: Completer<void>().future,
      ),
      isFalse,
    );
    MaasoTtsPlugin.soundEnabled.value = true;
    runtime.available = false;
    expect(
      await commentary.comment(
        _observation(),
        isCurrent: () => true,
        onRevoked: Completer<void>().future,
      ),
      isFalse,
    );
    expect(provider.calls, 0);
  });

  for (final disableBeforeDelivery in [false, true]) {
    test(
      'active game voice overrides chat mute until revoked: $disableBeforeDelivery',
      () async {
        await appServices.reset();
        addTearDown(appServices.reset);
        MaasoTtsPlugin.soundEnabled.value = false;
        final provider = _Provider('{"reply":"Nice!","actions":[]}');
        final runtime = _Runtime(provider);
        final service = appServices.put(
          GameVoiceCompanionService(
            browsingContext: CompanionBrowsingContextService(),
            commentary: (_, {required isCurrent, required onRevoked}) async =>
                false,
          ),
        );
        service.openSession(
          scopeKey: 'test|owner',
          playerId: 'current-game',
          title: '',
          summary: '',
          isCurrent: () => true,
        );
        if (disableBeforeDelivery) {
          provider.beforeResponse = () =>
              service.setSpokenRepliesEnabled(false);
        }
        final commentary = GameVoiceCommentaryRuntime(
          runtime: () => runtime,
          isCurrent: (_) => true,
        );
        expect(
          await commentary.comment(
            _observation(),
            isCurrent: () => true,
            onRevoked: Completer<void>().future,
          ),
          !disableBeforeDelivery,
        );
        expect(provider.calls, 1);
        expect(runtime.spoken, disableBeforeDelivery ? isEmpty : ['Nice!']);
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      },
    );
  }

  test(
    'successful public comment uses the existing runtime speech lane once',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final provider = _Provider('{"reply":"Nice!","actions":[]}');
      final runtime = _Runtime(provider);
      final commentary = GameVoiceCommentaryRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
      );
      expect(
        await commentary.comment(
          _observation(),
          isCurrent: () => true,
          onRevoked: Completer<void>().future,
        ),
        isTrue,
      );
      expect(runtime.spoken, ['Nice!']);
      expect(provider.messages!.first.role, 'system');
      expect(provider.messages!.last.content, contains('score'));
    },
  );

  test(
    'same partner, style boundaries and actual conversation enter the read-only prompt',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final provider = _Provider('{"reply":"A new joke.","actions":[]}');
      final runtime = _Runtime(provider)..noTeasing = true;
      runtime.profile.nickname = 'Luna';
      runtime.profile.personalityTraits = ['dry humor'];
      runtime.profile.agentToken = 'secret-token';
      runtime.profile.longTermMemory = 'unrelated private memory';
      final dialogue = GameCompanionDialogueBuffer()
        ..recordUser(
          id: 'u1',
          text: 'That was a close one!',
          at: DateTime.utc(2026),
        )
        ..recordSpeech(
          id: 'a1',
          text: 'A previous joke.',
          at: DateTime.utc(2026),
          stage: GameCompanionDeliveryStage.started,
        )
        ..recordSpeech(
          id: 'a1',
          text: 'A previous joke.',
          at: DateTime.utc(2026),
          stage: GameCompanionDeliveryStage.completed,
        );
      final commentary = GameVoiceCommentaryRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
      );
      expect(
        await commentary.comment(
          _observation(context: _context(dialogue)),
          isCurrent: () => true,
          onRevoked: Completer<void>().future,
        ),
        isTrue,
      );
      final payload = jsonDecode(provider.messages!.last.content) as Map;
      expect(payload['partner']['name'], 'Luna');
      expect(payload['partner']['traits'], ['dry humor']);
      expect(payload['companionContext']['recentConversation'].length, 2);
      expect(
        provider.messages!.first.content,
        contains(
          ConversationStylePrompt.render(
            runtime.lastStyle!,
            locale: AgentPromptCatalog.currentLocale,
            compact: true,
          ),
        ),
      );
      expect(jsonEncode(payload), isNot(contains('secret-token')));
      expect(jsonEncode(payload), isNot(contains('unrelated private memory')));
      expect(runtime.presentedStyle, same(runtime.lastStyle));
    },
  );

  test(
    'style guard does not recursively capture itself and invalidates late text',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final provider = _Provider('{"reply":"Nice!","actions":[]}');
      final runtime = _Runtime(provider);
      provider.beforeResponse = () => runtime.styleValid = false;
      final commentary = GameVoiceCommentaryRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
      );
      expect(
        await commentary.comment(
          _observation(),
          isCurrent: () => true,
          onRevoked: Completer<void>().future,
        ),
        isFalse,
      );
      expect(provider.calls, 1);
      expect(runtime.spoken, isEmpty);
      expect(runtime.lastStyle!.isCurrent, isFalse);
    },
  );

  for (final mutation in ['replacement', 'in-place', 'voice']) {
    test(
      'profile $mutation during generation prevents old persona speech',
      () async {
        MaasoTtsPlugin.soundEnabled.value = true;
        final provider = _Provider('{"reply":"Nice!","actions":[]}');
        final runtime = _Runtime(provider);
        provider.beforeResponse = () {
          switch (mutation) {
            case 'replacement':
              runtime.profile = runtime.profile.copyWith(nickname: 'New');
            case 'in-place':
              runtime.profile.nickname = 'New';
            case 'voice':
              runtime.profile.voiceId = 'new-voice';
          }
        };
        final commentary = GameVoiceCommentaryRuntime(
          runtime: () => runtime,
          isCurrent: (_) => true,
        );
        expect(
          await commentary.comment(
            _observation(),
            isCurrent: () => true,
            onRevoked: Completer<void>().future,
          ),
          isFalse,
        );
        expect(runtime.spoken, isEmpty);
      },
    );
  }

  test(
    'presentation repeats profile check after generation has finished',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final runtime = _Runtime(_Provider('{"reply":"Nice!","actions":[]}'));
      runtime.beforePresent = () =>
          runtime.profile.nickname = 'Changed before playback';
      final commentary = GameVoiceCommentaryRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
      );
      expect(
        await commentary.comment(
          _observation(),
          isCurrent: () => true,
          onRevoked: Completer<void>().future,
        ),
        isFalse,
      );
      expect(runtime.spoken, isEmpty);
    },
  );

  test(
    'silence, forbidden addresses and previously spoken jokes produce no speech receipts',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final dialogue = GameCompanionDialogueBuffer()
        ..recordSpeech(
          id: 'old',
          text: 'Nice!',
          at: DateTime.utc(2026),
          stage: GameCompanionDeliveryStage.started,
        );
      for (final reply in ['', 'Hey Pal!', ' nice! ']) {
        final runtime = _Runtime(
          _Provider(jsonEncode({'reply': reply, 'actions': []})),
        )..forbiddenAddresses = ['Pal'];
        final receipts = <GameCompanionDeliveryStage>[];
        final commentary = GameVoiceCommentaryRuntime(
          runtime: () => runtime,
          isCurrent: (_) => true,
          onDelivery: (_, _, _, stage) => receipts.add(stage),
        );
        expect(
          await commentary.comment(
            _observation(context: _context(dialogue)),
            isCurrent: () => true,
            onRevoked: Completer<void>().future,
          ),
          isFalse,
        );
        expect(runtime.spoken, isEmpty);
        expect(receipts, isEmpty);
      }
    },
  );

  for (final mode in [
    'completed',
    'interrupted',
    'failed-after-start',
    'never-started',
  ]) {
    test('speech receipts reflect $mode rather than generated text', () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      final runtime = _Runtime(_Provider('{"reply":"Nice!","actions":[]}'))
        ..startsSpeech = mode != 'never-started'
        ..completesSpeech = mode == 'completed'
        ..throwsAfterStart = mode == 'failed-after-start';
      final stages = <GameCompanionDeliveryStage>[];
      final ids = <String>[];
      final commentary = GameVoiceCommentaryRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
        onDelivery: (_, id, text, stage) {
          expect(text, 'Nice!');
          ids.add(id);
          stages.add(stage);
        },
      );
      expect(
        await commentary.comment(
          _observation(),
          isCurrent: () => true,
          onRevoked: Completer<void>().future,
        ),
        mode == 'completed',
      );
      expect(
        stages,
        mode == 'never-started'
            ? <GameCompanionDeliveryStage>[]
            : [
                GameCompanionDeliveryStage.started,
                mode == 'completed'
                    ? GameCompanionDeliveryStage.completed
                    : GameCompanionDeliveryStage.interrupted,
              ],
      );
      if (ids.isNotEmpty) expect(ids.toSet(), hasLength(1));
    });
  }
}

GameVoiceObservation _observation({GameCompanionContext? context}) =>
    GameVoiceObservation(
      scopeKey: 'test|owner',
      playerId: 'current-game',
      generation: 1,
      title: 'Generated puzzle',
      summary: 'A local game',
      publicState: const {
        'state': {'score': 3},
      },
      eventKind: 'score.changed',
      revision: 1,
      observedAt: DateTime.utc(2026, 10, 7),
      context: context,
    );

GameCompanionContext _context(GameCompanionDialogueBuffer dialogue) =>
    GameCompanionContext(
      sessionKey: GameCompanionSessionKey(
        scopeKey: 'test|owner',
        playerId: 'current-game',
        documentGeneration: 1,
        sessionGeneration: 1,
      ),
      roundGeneration: 1,
      preferences: const GameCompanionPreferences(enabled: true),
      recentConversation: dialogue.snapshot,
    );

class _Provider extends LLMClient {
  _Provider(this.response);
  final String response;
  int calls = 0;
  List<Message>? messages;
  void Function()? beforeResponse;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    this.messages = messages;
    beforeResponse?.call();
    return response;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unused');
}

class _Runtime extends AgentRuntime {
  _Runtime(LLMClient client)
    : super(
        agentId: 'self',
        llmClient: client,
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const [],
          catchphrase: '',
        ),
      );
  bool available = true;
  bool styleValid = true, noTeasing = false;
  bool startsSpeech = true, completesSpeech = true, throwsAfterStart = false;
  List<String> forbiddenAddresses = [];
  bool Function()? _decisionGuard;
  ConversationStyleSnapshot? lastStyle, presentedStyle;
  void Function()? beforePresent;
  final List<String> spoken = [];
  @override
  bool get canAcceptSurfacePlayDecision => available;
  @override
  bool get isCurrentSurfacePlayDecision => available;
  @override
  Future<String?> runGameCommentaryDecision(
    Future<String> Function() generate, {
    required bool Function() isCurrent,
  }) async {
    _decisionGuard = isCurrent;
    return isCurrent() ? generate() : null;
  }

  @override
  Future<ConversationStyleSnapshot> snapshotGameVoiceStyle() async {
    final guard = _decisionGuard!;
    return lastStyle = ConversationStyleSnapshot(
      isPrivate: true,
      noTeasing: noTeasing,
      forbiddenAddresses: forbiddenAddresses,
      deliveryGuard: () => guard() && styleValid,
    );
  }

  @override
  Future<bool> presentGameVoiceComment(
    String text, {
    required bool Function() isCurrent,
    bool Function()? spokenRepliesAllowed,
    Future<void>? onRevoked,
    void Function()? onPresented,
    ConversationStyleSnapshot? conversationStyle,
  }) async {
    beforePresent?.call();
    if (!isCurrent() ||
        spokenRepliesAllowed?.call() == false ||
        !startsSpeech) {
      return false;
    }
    presentedStyle = conversationStyle;
    spoken.add(text);
    onPresented?.call();
    if (throwsAfterStart) throw StateError('speech failed');
    return completesSpeech && isCurrent();
  }
}
