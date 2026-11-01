import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_adapter.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_rule_runtime.dart';

const _rules =
    '{"version":1,"rules":["Match three visible symbols."],"controls":["Tap a symbol to select it."]}';
GameCompanionRuleInferenceInput _input() => GameCompanionRuleInferenceInput(
  scopeKey: 'private-user|environment',
  title: 'A small puzzle',
  summary: 'A matching game',
  identity: GameContentIdentity(
    kind: GameContentIdentityKind.ownedSource,
    sha256: 'a' * 64,
  ),
  visibleText: 'Match three visible symbols. Tap a symbol to select it.',
  controls: [
    {'label': 'Play', 'role': 'button'},
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rule interpretation uses existing single-turn admission and only bounded public evidence',
    () async {
      final provider = _Provider(() => _rules);
      final runtime = _Runtime(provider);
      final rules = GameCompanionRuleRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
      );
      final result = await rules.infer(_input(), isCurrent: () => true);
      expect(result!.toPromptJson()['rules'], ['Match three visible symbols.']);
      expect(runtime.admissions, 1);
      expect(runtime.active, isFalse);
      expect(provider.calls, 1);
      final input = jsonDecode(provider.messages!.last.content) as Map;
      expect(input.keys, ['untrustedGameData']);
      expect(input['untrustedGameData']['controls'], [
        {'label': 'Play', 'role': 'button'},
      ]);
      expect(provider.messages!.last.content, isNot(contains('private-user')));
      expect(provider.messages!.last.content, isNot(contains('a' * 64)));
      expect(provider.timeout, const Duration(seconds: 6));
    },
  );

  test(
    'malformed, action-bearing and current-state schemas cannot become cached rules',
    () {
      for (final source in [
        '```json\n$_rules\n```',
        '{"reply":"hi","actions":[]}',
        '{"version":1,"rules":["x"],"actions":[{"type":"skill.call"}]}',
        '{"version":1,"rules":["x"],"score":42}',
        '{"version":1,"rules":["x"],"publicState":{"turn":2}}',
        '{"version":1,"summary":"Current score is 42"}',
        '{"version":1}',
        '{"version":1.0,"rules":["x"]}',
        '{"version":1,"rules":[]}',
        jsonEncode({
          'version': 1,
          'rules': ['😀' * 257],
        }),
      ]) {
        expect(
          GameCompanionRuleRuntime.parseDescriptor(source),
          isNull,
          reason: source,
        );
      }
      expect(GameCompanionRuleRuntime.parseDescriptor(_rules), isNotNull);
    },
  );

  test('busy or stale callers do not dispatch or retry', () async {
    final provider = _Provider(() => _rules);
    final runtime = _Runtime(provider)..available = false;
    final rules = GameCompanionRuleRuntime(
      runtime: () => runtime,
      isCurrent: (_) => true,
    );
    expect(await rules.infer(_input(), isCurrent: () => true), isNull);
    runtime.available = true;
    expect(await rules.infer(_input(), isCurrent: () => false), isNull);
    expect(provider.calls, 0);
    expect(runtime.admissions, 0);
  });

  test('account scope is rechecked after privacy admission waits', () async {
    final entered = Completer<void>(), permission = Completer<void>();
    final provider = _Provider(() => _rules);
    final runtime = _Runtime(
      privacyGuardedLLMClient(provider, () {
        entered.complete();
        return permission.future;
      }),
    );
    var mounted = true;
    final rules = GameCompanionRuleRuntime(
      runtime: () => runtime,
      isCurrent: (_) => mounted,
    );
    final result = rules.infer(_input(), isCurrent: () => true);
    await entered.future;
    mounted = false;
    permission.complete();
    expect(await result, isNull);
    expect(provider.calls, 0);
  });

  test('switching runtime discards a late interpretation', () async {
    final started = Completer<void>(), response = Completer<String>();
    final provider = _Provider(() {
      started.complete();
      return response.future;
    });
    var runtime = _Runtime(provider);
    final rules = GameCompanionRuleRuntime(
      runtime: () => runtime,
      isCurrent: (_) => true,
    );
    final result = rules.infer(_input(), isCurrent: () => true);
    await started.future;
    runtime = _Runtime(_Provider(() => _rules));
    response.complete(_rules);
    expect(await result, isNull);
    expect(provider.calls, 1);
  });

  test(
    'deadline releases the owner and late privacy permission cannot dispatch',
    () async {
      final entered = Completer<void>(), permission = Completer<void>();
      final provider = _Provider(() => _rules);
      final runtime = _Runtime(
        privacyGuardedLLMClient(provider, () {
          entered.complete();
          return permission.future;
        }),
      );
      final rules = GameCompanionRuleRuntime(
        runtime: () => runtime,
        isCurrent: (_) => true,
        timeout: const Duration(milliseconds: 20),
      );
      final result = rules.infer(_input(), isCurrent: () => true);
      await entered.future;
      expect(await result, isNull);
      expect(runtime.active, isFalse);
      permission.complete();
      await Future<void>.delayed(Duration.zero);
      expect(provider.calls, 0);
    },
  );

  test('provider failure returns unknown without retry', () async {
    final provider = _Provider(() => throw StateError('unavailable'));
    final runtime = _Runtime(provider);
    final rules = GameCompanionRuleRuntime(
      runtime: () => runtime,
      isCurrent: (_) => true,
    );
    expect(await rules.infer(_input(), isCurrent: () => true), isNull);
    expect(provider.calls, 1);
    expect(runtime.active, isFalse);
  });
}

final class _Provider extends LLMClient {
  _Provider(this.respond);
  final FutureOr<String> Function() respond;
  int calls = 0;
  List<Message>? messages;
  Duration? timeout;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls++;
    this.messages = messages;
    this.timeout = timeout;
    return respond();
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unused');
}

final class _Runtime extends AgentRuntime {
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
  bool available = true, active = false;
  int admissions = 0;
  @override
  bool get canAcceptSurfacePlayDecision => available && !active;
  @override
  bool get isCurrentSurfacePlayDecision => active;
  @override
  Future<String?> runGameCommentaryDecision(
    Future<String> Function() generate, {
    required bool Function() isCurrent,
  }) async {
    if (!canAcceptSurfacePlayDecision || !isCurrent()) return null;
    active = true;
    admissions++;
    try {
      return await generate();
    } finally {
      active = false;
    }
  }
}
