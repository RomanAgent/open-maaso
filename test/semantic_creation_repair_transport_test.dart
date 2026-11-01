import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/presentation/applet_save_confirmation.dart';
import 'package:sembast/sembast_memory.dart';

const _intent = <String, Object?>{
  'type': 'creation.intent',
  'mode': 'create',
  'kind': 'game',
  'requirements': '触屏改变重力、收集光点、暂停和二级帮助页面；完整保留任意玩法。',
};
const _primaryReply = '我可以挑个适合你的玩法。';
const _repairOnlyText = 'REPAIR_TEXT_MUST_NOT_BE_PRESENTED';

String _envelope(List<Map<String, Object?>> actions, {String reply = ''}) =>
    jsonEncode({'reply': reply, 'actions': actions});

/// This is deliberately a real optional structured transport. Native JSON
/// failure must not prevent a conversation decision from using ordinary chat.
class _NativeJsonRejectingClient extends LLMClient
    implements StructuredOutputLLMClient {
  _NativeJsonRejectingClient({required this.primary, required this.repair});

  final String primary;
  final String repair;
  final primaryRequests = <List<Message>>[];
  final repairRequests = <List<Message>>[];
  final sourceRequests = <List<Message>>[];
  final _sourceResponses = <Completer<String>>[];
  int nativeJsonRepairCalls = 0;
  int nativeJsonSourceCalls = 0;
  int generateJsonCalls = 0;
  bool _closed = false;

  @override
  Duration get defaultTimeout => const Duration(seconds: 2);

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    primaryRequests.add(List.unmodifiable(messages));
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode({'delta': primary}),
    );
  }

  static bool _isRepair(List<Message> messages) {
    if (messages.isEmpty) return false;
    try {
      final data = jsonDecode(messages.last.content);
      return data is Map && data.containsKey('previousReply');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    if (_isRepair(messages)) {
      repairRequests.add(List.unmodifiable(messages));
      if (repair == 'ordinary_transport_failure') {
        throw StateError('synthetic_ordinary_transport_failure');
      }
      return Future.value(repair);
    }
    return _holdSource(messages);
  }

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) async {
    await onAdmitted?.call();
    if (_isRepair(messages)) {
      nativeJsonRepairCalls += 1;
      throw UnsupportedError('synthetic_native_json_mode_unsupported');
    }
    nativeJsonSourceCalls += 1;
    return _holdSource(messages);
  }

  Future<String> _holdSource(List<Message> messages) {
    sourceRequests.add(List.unmodifiable(messages));
    final response = Completer<String>();
    _sourceResponses.add(response);
    if (_closed) response.complete('{}');
    return response.future;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) {
    generateJsonCalls += 1;
    throw StateError('unexpected_alternate_transport');
  }

  void close() {
    _closed = true;
    for (final response in _sourceResponses) {
      if (!response.isCompleted) response.complete('{}');
    }
  }
}

Future<void> _waitFor(bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready() && watch.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentTaskJobStore jobs;
  final clients = <_NativeJsonRejectingClient>[];
  final runtimes = <AgentRuntime>[];
  late List<String> spoken;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    spoken = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          if (call.method == 'speak') spoken.add('${call.arguments}');
          return 1;
        });
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'repair-transport-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(database);
    jobs = appServices.put(AgentTaskJobStore());
    appServices.put<AppletSaveConfirmation>((_) async => true);
    appServices.put<SurfaceWorkerFirstFrameWaiter>(
      const SurfaceWorkerTestFirstFrameWaiter(),
    );
  });

  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    for (final runtime in runtimes.reversed) {
      await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
    }
    runtimes.clear();
    clients.clear();
    await database.close();
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  AgentRuntime makeRuntime(_NativeJsonRejectingClient client) {
    clients.add(client);
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Maaso',
        avatar: '',
        bio: 'Offline transport boundary',
        personalityTraits: const ['warm'],
        catchphrase: '',
      ),
      llmClient: client,
      semanticCreationEnabled: true,
      prepareTtsForNewTurn: (_) async {},
    );
    runtimes.add(runtime);
    return runtime;
  }

  for (final repaired in {
    'full reply/actions envelope': _envelope([_intent], reply: _repairOnlyText),
    'previous bare action compatibility': jsonEncode(_intent),
  }.entries) {
    test(
      '${repaired.key} uses ordinary transport despite native JSON rejection',
      () async {
        final client = _NativeJsonRejectingClient(
          primary: _envelope([], reply: _primaryReply),
          repair: repaired.value,
        );
        final runtime = makeRuntime(client);
        final visible = <String>[];
        final subscription = runtime.onLocalReplyDelta.listen(visible.add);
        addTearDown(subscription.cancel);
        final result = await runtime.chat('你喜欢玩什么游戏，帮我做一个出来', const []);
        expect(result.isSuccess, isTrue, reason: result.stderr);
        await _waitFor(
          () => jobs.jobs.length == 1 && client.sourceRequests.isNotEmpty,
        );
        expect(client.primaryRequests, hasLength(1));
        expect(client.repairRequests, hasLength(1));
        expect(client.nativeJsonRepairCalls, 0);
        expect(client.generateJsonCalls, 0);
        expect(jobs.jobs.single.taskKind, AgentTaskKind.gameGeneration);
        expect(
          jobs.jobs.single.projectBrief,
          contains(_intent['requirements'] as String),
        );
        expect(visible.join(), isNot(contains(_repairOnlyText)));
        expect(spoken.join(), isNot(contains(_repairOnlyText)));
        final instruction = client.repairRequests.single.first.content;
        expect(instruction, contains('creation.intent'));
        expect(instruction, isNot(contains('without reply, actions')));
        expect(
          instruction,
          isNot(contains('Return one creation.intent action object')),
        );
      },
    );
  }

  final extraActions = <String, Map<String, Object?>>{
    'spoken action': {'type': 'voice.speak', 'text': _repairOnlyText},
    'tool action': {
      'type': 'skill.call',
      'tool': 'ungranted_tool',
      'args': <String, Object?>{},
    },
    'surface action': {'type': 'surface.show', 'surface': <String, Object?>{}},
  };
  for (final extra in extraActions.entries) {
    test(
      'repair rejects ${extra.key} before any task or injected speech',
      () async {
        final client = _NativeJsonRejectingClient(
          primary: _envelope([], reply: _primaryReply),
          repair: _envelope([extra.value, _intent], reply: _repairOnlyText),
        );
        final runtime = makeRuntime(client);
        final visible = <String>[];
        final subscription = runtime.onLocalReplyDelta.listen(visible.add);
        addTearDown(subscription.cancel);
        final result = await runtime.chat('帮我挑个玩法并做出来', const []);
        expect(result.isSuccess, isTrue);
        expect(
          result.stdout,
          contains(zhCH['agent_runtime.creation_intent_protocol_unavailable']!),
        );
        expect(client.primaryRequests, hasLength(1));
        expect(client.repairRequests, hasLength(1));
        expect(client.nativeJsonRepairCalls, 0);
        expect(client.sourceRequests, isEmpty);
        expect(jobs.jobs, isEmpty);
        expect(visible.join(), isNot(contains(_repairOnlyText)));
        expect(spoken.join(), isNot(contains(_repairOnlyText)));
        expect(await database.getAllWidgets(), isEmpty);
      },
    );
  }

  for (final (index, invalid) in <String>[
    'not JSON',
    _envelope([]),
    _envelope([_intent, _intent]),
    _envelope([
      _intent,
      {'type': 'voice.speak', 'text': _repairOnlyText},
    ]),
    _envelope([
      {'type': 'creation.intent', 'mode': 'invalid'},
    ]),
    _envelope([
      {..._intent, 'requirements': ''},
    ]),
    'ordinary_transport_failure',
  ].indexed) {
    test('invalid repair terminates after one request: case $index', () async {
      final client = _NativeJsonRejectingClient(
        primary: _envelope([], reply: _primaryReply),
        repair: invalid,
      );
      final runtime = makeRuntime(client);
      final visible = <String>[];
      final subscription = runtime.onLocalReplyDelta.listen(visible.add);
      addTearDown(subscription.cancel);
      final result = await runtime.chat('帮我挑个玩法并做出来', const []);
      expect(result.isSuccess, isTrue);
      expect(
        result.stdout,
        contains(zhCH['agent_runtime.creation_intent_protocol_unavailable']!),
      );
      expect(client.primaryRequests, hasLength(1));
      expect(client.repairRequests, hasLength(1));
      expect(client.nativeJsonRepairCalls, 0);
      expect(client.generateJsonCalls, 0);
      expect(client.sourceRequests, isEmpty);
      expect(jobs.jobs, isEmpty);
      expect(visible.join(), isNot(contains(_repairOnlyText)));
      expect(spoken.join(), isNot(contains(_repairOnlyText)));
      expect(await database.getAllWidgets(), isEmpty);
    });
  }

  test(
    'a valid ordinary none reply uses one stream and needs no repair',
    () async {
      final client = _NativeJsonRejectingClient(
        primary: _envelope([
          {'type': 'creation.intent', 'mode': 'none'},
        ], reply: '你好。'),
        repair: 'ordinary_transport_failure',
      );
      final runtime = makeRuntime(client);
      final result = await runtime.chat('你好', const []);
      expect(result.isSuccess, isTrue);
      expect(result.stdout, '你好。');
      expect(client.primaryRequests, hasLength(1));
      expect(client.repairRequests, isEmpty);
      expect(client.nativeJsonRepairCalls, 0);
      expect(client.generateJsonCalls, 0);
      expect(client.sourceRequests, isEmpty);
      expect(jobs.jobs, isEmpty);
    },
  );
}
