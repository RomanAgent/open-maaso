import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  group('structured action pre-execution gate', () {
    test(
      'receives the final repaired envelope exactly once before execute',
      () async {
        final order = <String>[];
        final executor = _RecordingExecutor(order);
        final llm = _QueueLlm(
          order: order,
          responses: <String>[
            'not valid JSON',
            '{"reply":"repaired reply","actions":['
                '{"type":"emotion.set","emotion":"calm"}]}',
          ],
        );
        var gateCalls = 0;

        final result = await debugStructuredActionProcess(
          llmClient: llm,
          profile: _profile(),
          instruction: 'respond',
          systemPrompt: 'Return the structured envelope.',
          executor: executor,
          locale: AppLocale.en,
          beforeExecute: (envelope) async {
            order.add('gate');
            gateCalls += 1;
            expect(envelope.reply, 'repaired reply');
            expect(envelope.actions.single.type, 'emotion.set');
            return true;
          },
        );

        expect(result.isSuccess, isTrue);
        expect(result.stdout, 'repaired reply');
        expect(gateCalls, 1);
        expect(executor.executeCalls, 1);
        expect(executor.executedEnvelope?.reply, 'repaired reply');
        expect(order, <String>[
          'model',
          'repair',
          'preflight',
          'gate',
          'execute',
        ]);
      },
    );

    test(
      'false gate returns a silent success without executing effects',
      () async {
        final order = <String>[];
        final executor = _RecordingExecutor(order);
        var gateCalls = 0;

        final result = await debugStructuredActionProcess(
          llmClient: _validLlm(order),
          profile: _profile(),
          instruction: 'respond',
          systemPrompt: 'Return the structured envelope.',
          executor: executor,
          locale: AppLocale.en,
          beforeExecute: (envelope) async {
            order.add('gate');
            gateCalls += 1;
            return false;
          },
        );

        expect(result.isSuccess, isTrue);
        expect(result.stdout, isEmpty);
        expect(gateCalls, 1);
        expect(executor.executeCalls, 0);
        expect(order, <String>['model', 'preflight', 'gate']);
      },
    );

    test('throwing gate fails closed without executing effects', () async {
      final order = <String>[];
      final executor = _RecordingExecutor(order);
      var gateCalls = 0;

      final result = await debugStructuredActionProcess(
        llmClient: _validLlm(order),
        profile: _profile(),
        instruction: 'respond',
        systemPrompt: 'Return the structured envelope.',
        executor: executor,
        locale: AppLocale.en,
        beforeExecute: (envelope) async {
          order.add('gate');
          gateCalls += 1;
          throw StateError('ledger unavailable');
        },
      );

      expect(result.isSuccess, isFalse);
      expect(result.stderr, isNotEmpty);
      expect(gateCalls, 1);
      expect(executor.executeCalls, 0);
      expect(order, <String>['model', 'preflight', 'gate']);
    });

    test('cancellation is checked immediately before the gate', () async {
      final order = <String>[];
      final executor = _RecordingExecutor(order);
      var gateCalls = 0;

      final result = await debugStructuredActionProcess(
        llmClient: _validLlm(order),
        profile: _profile(),
        instruction: 'respond',
        systemPrompt: 'Return the structured envelope.',
        executor: executor,
        locale: AppLocale.en,
        shouldCancel: () => order.contains('preflight'),
        beforeExecute: (envelope) async {
          gateCalls += 1;
          return true;
        },
      );

      expect(result.isSuccess, isTrue);
      expect(gateCalls, 0);
      expect(executor.executeCalls, 0);
      expect(order, <String>['model', 'preflight']);
    });

    test('cancellation is checked immediately after the gate', () async {
      final order = <String>[];
      final executor = _RecordingExecutor(order);
      var cancelled = false;

      final result = await debugStructuredActionProcess(
        llmClient: _validLlm(order),
        profile: _profile(),
        instruction: 'respond',
        systemPrompt: 'Return the structured envelope.',
        executor: executor,
        locale: AppLocale.en,
        shouldCancel: () => cancelled,
        beforeExecute: (envelope) async {
          order.add('gate');
          cancelled = true;
          return true;
        },
      );

      expect(result.isSuccess, isTrue);
      expect(executor.executeCalls, 0);
      expect(order, <String>['model', 'preflight', 'gate']);
    });

    test(
      'optional execution boundary starts after preflight and wraps gate plus execute',
      () async {
        final order = <String>[];
        final executor = _RecordingExecutor(order);

        final result = await debugStructuredActionProcess(
          llmClient: _validLlm(order),
          profile: _profile(),
          instruction: 'respond',
          systemPrompt: 'Return the structured envelope.',
          executor: executor,
          locale: AppLocale.en,
          beforeExecute: (_) async {
            order.add('gate');
            return true;
          },
          executionBoundary: (operation) async {
            order.add('boundary-enter');
            final result = await operation();
            order.add('boundary-exit');
            return result;
          },
        );

        expect(result.isSuccess, isTrue);
        expect(order, <String>[
          'model',
          'preflight',
          'boundary-enter',
          'gate',
          'execute',
          'boundary-exit',
        ]);
      },
    );

    test('omitting the gate preserves the existing execute path', () async {
      final order = <String>[];
      final executor = _RecordingExecutor(order);

      final result = await debugStructuredActionProcess(
        llmClient: _validLlm(order),
        profile: _profile(),
        instruction: 'respond',
        systemPrompt: 'Return the structured envelope.',
        executor: executor,
        locale: AppLocale.en,
      );

      expect(result.isSuccess, isTrue);
      expect(result.stdout, 'accepted reply');
      expect(executor.executeCalls, 1);
      expect(order, <String>['model', 'preflight', 'execute']);
    });
  });
}

_QueueLlm _validLlm(List<String> order) => _QueueLlm(
  order: order,
  responses: <String>[
    '{"reply":"accepted reply","actions":['
        '{"type":"emotion.set","emotion":"happy"}]}',
  ],
);

AgentProfile _profile() => AgentProfile(
  nickname: 'Gate Tester',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['careful'],
  catchphrase: 'ok',
);

class _QueueLlm implements LLMClient {
  _QueueLlm({required this.order, required List<String> responses})
    : _responses = List<String>.of(responses);

  final List<String> order;
  final List<String> _responses;
  int _chatCalls = 0;

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    order.add(_chatCalls++ == 0 ? 'model' : 'repair');
    if (_responses.isEmpty) {
      throw StateError('No queued LLM response');
    }
    return _responses.removeAt(0);
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('not used');

  @override
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      const Stream<String>.empty();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => const Stream<LLMStreamEvent>.empty();
}

class _RecordingExecutor extends AgentActionExecutor {
  _RecordingExecutor(this.order)
    : super(
        agentId: 'gate-test',
        skillManager: SkillManager(),
        locale: AppLocale.en,
      );

  final List<String> order;
  int executeCalls = 0;
  AgentActionEnvelope? executedEnvelope;

  @override
  void preflightSurfaceActions(AgentActionEnvelope envelope) {
    order.add('preflight');
  }

  @override
  Future<AgentActionExecutionResult> execute(
    AgentActionEnvelope envelope, {
    SurfaceWorkerActionRepair? surfaceWorkerRepair,
  }) async {
    order.add('execute');
    executeCalls += 1;
    executedEnvelope = envelope;
    return const AgentActionExecutionResult();
  }
}
