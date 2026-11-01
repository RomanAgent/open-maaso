import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/location_service.dart';
import 'package:maaso/src/core/services/network_region_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:sembast/sembast_memory.dart';

const _sourceUrl = 'https://weather.example.org/current';
const _sourceSnippet =
    'Verified lookup fixture: 21 C, clear, observation 10:00.';
const _answer = 'The source reports 21 C and clear skies. $_sourceUrl';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  late AgentRuntime runtime;
  late AgentTaskJobStore jobs;
  late _LookupClient llm;
  late TTSEngine? previousTts;
  final requests = <http.Request>[];
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
          final events = MethodChannel(
            'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}',
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

  Future<T> withNetwork<T>(Future<T> Function() operation) =>
      http.runWithClient(
        () => AgentPromptCatalog.runWithLocale(AppLocale.zh, operation),
        () => MockClient((request) async {
          requests.add(request);
          expect(request.url.host, 'html.duckduckgo.com');
          return http.Response(
            '<html><body><div class="result">'
            '<a class="result__a" href="$_sourceUrl">Local weather source</a>'
            '<div class="result__snippet">$_sourceSnippet</div>'
            '</div></body></html>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      );

  setUp(() async {
    await appServices.reset();
    SharedPreferences.setMockInitialValues({});
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    requests.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'semantic-lookup-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(database);
    jobs = appServices.put(AgentTaskJobStore());
    previousTts = TTSEngineRegistry.current;
    TTSEngineRegistry.current = _SilentEngine();
    llm = _LookupClient();
    runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Maaso',
        avatar: '',
        bio: 'test',
        personalityTraits: const ['warm'],
        catchphrase: '',
      ),
      llmClient: llm,
      semanticCreationEnabled: true,
      conversationDeliveryMode: ConversationDeliveryMode.legacy,
      prepareTtsForNewTurn: (_) async {},
    );
  });

  tearDown(() async {
    await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
    TTSEngineRegistry.current = previousTts;
    await database.close();
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  Future<LocationService> mountLocation(_LocationBackend backend) async {
    final service = await LocationService(platform: backend).init(
      scope: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: 'location-owner',
      ),
    );
    return appServices.put<LocationService>(service);
  }

  for (final cancel in [false, true]) {
    test(
      'real lookup starts phone without delaying HTTP and releases it: cancel=$cancel',
      () async {
        final actor = _LookupAvatar();
        final active = ActiveAvatarRuntime()..register(actor);
        appServices.put(active);
        final router = GoRouter(
          initialLocation: '/home',
          routes: [GoRoute(path: '/home', builder: (_, _) => const SizedBox())],
        );
        await router.routerDelegate.setNewRoutePath(
          router.configuration.findMatch(Uri.parse('/home')),
        );
        appNavigation.configure(router);
        try {
          final httpGate = Completer<void>();
          final readingGate = actor.readingGate = Completer<void>();
          final chunks = StreamController<String>();
          llm.streams.add(chunks.stream);
          final visible = <String>[];
          final subscription = runtime.onLocalReplyDelta.listen(visible.add);
          final pending = http.runWithClient(
            () => runtime.chat('帮我查一下巴黎的天气', const []),
            () => MockClient((request) async {
              requests.add(request);
              await httpGate.future;
              return http.Response(
                '<html><body><div class="result">'
                '<a class="result__a" href="$_sourceUrl">Weather</a>'
                '<div class="result__snippet">$_sourceSnippet</div>'
                '</div></body></html>',
                200,
              );
            }),
          );
          await _wait(() => llm.streamCalls.length == 1);
          chunks.add('{"reply":"我查一下。');
          await _wait(() => visible.join().contains('我查一下'));
          expect(actor.phases, isEmpty);
          expect(requests, isEmpty);
          chunks.add(
            '","actions":[{"type":"lookup.intent","mode":"search",'
            '"query":"Paris weather today"},'
            '{"type":"creation.intent","mode":"none"}]}',
          );
          await chunks.close();
          await _wait(() => requests.isNotEmpty);
          expect(actor.phases, [AvatarPhoneInteractionPhase.reading]);
          if (cancel) {
            runtime.cancelCurrent();
            await _wait(
              () => actor.phases.contains(AvatarPhoneInteractionPhase.none),
            );
            readingGate.complete();
            await Future<void>.delayed(Duration.zero);
            expect(actor.phases, [
              AvatarPhoneInteractionPhase.reading,
              AvatarPhoneInteractionPhase.none,
            ]);
          } else {
            readingGate.complete();
            await _wait(
              () => actor.phases.contains(AvatarPhoneInteractionPhase.replying),
            );
          }
          httpGate.complete();
          await pending;
          await _wait(
            () => actor.phases.contains(AvatarPhoneInteractionPhase.none),
          );
          expect(actor.phases.last, AvatarPhoneInteractionPhase.none);
          expect(actor.interactions.toSet(), hasLength(1));
          expect(llm.streamCalls, hasLength(1));
          expect(llm.calls, hasLength(cancel ? 0 : 1));
          await subscription.cancel();
          llm.enqueue(_envelope('你好呀。'));
          final count = actor.phases.length;
          await runtime.chat('你好', const []);
          expect(actor.phases, hasLength(count));
          await runtime.retireAndDrain();
        } finally {
          router.dispose();
        }
      },
    );
  }

  test(
    'current-area query locates after streamed reply and sends city only',
    () async {
      final backend = _LocationBackend();
      await mountLocation(backend);
      final chunks = StreamController<String>();
      llm.streams.add(chunks.stream);
      final visible = <String>[];
      final subscription = runtime.onLocalReplyDelta.listen(visible.add);
      addTearDown(subscription.cancel);
      final pending = withNetwork(() => runtime.chat('今天天气怎么样', const []));
      await _wait(() => llm.streamCalls.length == 1);
      chunks.add('{"reply":"我帮你看看这里的天气。');
      await _wait(() => visible.join().contains('我帮你'));
      expect(backend.fixes, 0);
      expect(requests, isEmpty);
      chunks.add(
        '","actions":[{"type":"lookup.intent","mode":"search",'
        '"query":"今日天气","useCurrentLocation":true},'
        '{"type":"creation.intent","mode":"none"}]}',
      );
      await chunks.close();
      final result = await pending;
      expect(result.stdout, contains(_answer));
      expect(backend.fixes, 1);
      expect(requests, hasLength(1));
      expect(requests.single.url.queryParameters['q'], contains('上海市'));
      final modelData = llm.calls
          .expand((call) => call)
          .map((m) => m.content)
          .join();
      expect(modelData, contains('上海市'));
      expect(modelData, isNot(contains('31.234567')));
      expect(modelData, isNot(contains('121.987654')));
      expect(modelData, isNot(contains('latitude')));
      expect(jobs.jobs, isEmpty);
    },
  );

  test('a specified city and ordinary chat never acquire location', () async {
    final backend = _LocationBackend();
    await mountLocation(backend);
    llm.enqueue(
      _envelope(
        '我看看巴黎的天气。',
        lookup: {'mode': 'search', 'query': 'Paris weather today'},
      ),
    );
    await withNetwork(() => runtime.chat('查巴黎天气', const []));
    expect(backend.fixes, 0);
    llm.enqueue(_envelope('你好呀。'));
    await withNetwork(() => runtime.chat('你好', const []));
    expect(backend.fixes, 0);
    expect(backend.permissionRequests, 0);
  });

  test(
    'implicit lookup automatically resolves the country again next request',
    () async {
      final backend = _LocationBackend();
      await mountLocation(backend);
      var country = 'CN';
      final region =
          await NetworkRegionService(
            countryCodeSupplier: () => country,
            deviceCountryCodeSupplier: () => 'US',
          ).init(
            scope: AccountStorageScope(
              environmentKey: 'test',
              accountUuid: 'lookup-network-owner',
            ),
          );
      appServices.put<NetworkRegionService>(region);
      var mainland = true;
      await http.runWithClient(
        () async {
          for (final selection in [true, false]) {
            mainland = selection;
            country = mainland ? 'CN' : 'US';
            llm.enqueue(
              _envelope(
                'I will check the source.',
                lookup: {'mode': 'search', 'query': 'Paris weather today'},
              ),
            );
            final result = await runtime.chat('查巴黎天气', const []);
            expect(result.stdout, contains(_answer));
          }
        },
        () => MockClient((request) async {
          requests.add(request);
          expect(
            request.url.host,
            mainland ? 'cn.bing.com' : 'html.duckduckgo.com',
          );
          return http.Response(
            mainland
                ? '<rss><channel><item><title>Weather</title>'
                      '<link>$_sourceUrl</link><description>$_sourceSnippet</description>'
                      '</item></channel></rss>'
                : '<html><body><div class="result">'
                      '<a class="result__a" href="$_sourceUrl">Weather</a>'
                      '<div class="result__snippet">$_sourceSnippet</div>'
                      '</div></body></html>',
            200,
            headers: {
              'content-type':
                  'text/${mainland ? 'xml' : 'html'}; charset=utf-8',
            },
          );
        }),
      );
      expect(requests, hasLength(2));
      expect(backend.fixes, 0);
      expect(backend.permissionRequests, 0);
      expect(jobs.jobs, isEmpty);
    },
  );

  for (final permission in [
    LocationPermissionState.denied,
    LocationPermissionState.deniedForever,
  ]) {
    test(
      'denied location asks for a city and makes no search: $permission',
      () async {
        final backend = _LocationBackend()..permission = permission;
        await mountLocation(backend);
        llm.enqueue(
          _envelope(
            '我看看这里的天气。',
            lookup: {
              'mode': 'search',
              'query': '今日天气',
              'useCurrentLocation': true,
            },
          ),
        );
        final result = await withNetwork(
          () => runtime.chat('今天天气怎么样', const []),
        );
        expect(result.stdout, contains('哪个城市'));
        expect(backend.fixes, 0);
        expect(requests, isEmpty);
        expect(llm.calls, isEmpty);
        expect(jobs.jobs, isEmpty);
      },
    );
  }

  test('turning off location discards a late lookup answer', () async {
    final backend = _LocationBackend();
    final location = await mountLocation(backend);
    llm.pendingAnswer = Completer<String>();
    llm.enqueue(
      _envelope(
        '我看看这里的天气。',
        lookup: {'mode': 'search', 'query': '今日天气', 'useCurrentLocation': true},
      ),
    );
    final pending = withNetwork(() => runtime.chat('今天天气怎么样', const []));
    await _wait(() => llm.calls.length == 1);
    await location.setEnabled(false);
    llm.pendingAnswer!.complete(jsonEncode({'reply': _answer, 'actions': []}));
    final result = await pending;
    expect(result.stdout, isNot(contains(_answer)));
    expect(location.state.value.city, isNull);
    expect(backend.fixes, 1);
  });

  test('clarification metadata cannot leave only a waiting promise', () async {
    llm.enqueue(
      _envelope(
        '我先查一下。',
        lookup: {'mode': 'clarify', 'question': '你想查询哪个城市的天气？'},
      ),
    );
    final result = await withNetwork(() => runtime.chat('今天天气怎么样', const []));
    expect(result.stdout, contains('你想查询哪个城市的天气？'));
    expect(requests, isEmpty);
    expect(llm.calls, isEmpty);
    expect(jobs.jobs, isEmpty);
  });

  for (final entry in const {
    '今天天气怎么样': '你想查询哪个城市的天气？',
    'What is the weather today?': 'Which city should I check?',
  }.entries) {
    test(
      'missing city asks in the same response without network: ${entry.key}',
      () async {
        llm.enqueue(
          _envelope(
            entry.value,
            lookup: {'mode': 'clarify', 'question': entry.value},
          ),
        );
        final result = await withNetwork(
          () => runtime.chat(entry.key, const []),
        );
        expect(result.isSuccess, isTrue);
        expect(result.stdout, entry.value);
        expect(llm.streamCalls, hasLength(1));
        expect(llm.calls, isEmpty);
        expect(requests, isEmpty);
        expect(jobs.jobs, isEmpty);
      },
    );
  }

  test(
    'disabled search reports its state without another model request',
    () async {
      await runtime.init(enabledSkillIds: const {});
      llm.enqueue(
        _envelope('我来查一下。', lookup: {'mode': 'search', 'query': '上海实时天气'}),
      );
      final result = await withNetwork(
        () => runtime.chat('上海呢', [
          Message(role: 'assistant', content: '你想查哪个城市的天气？'),
        ]),
      );
      expect(result.isSuccess, isTrue);
      expect(result.stdout, contains('网页搜索'));
      expect(result.stdout, contains('未开启或不可用'));
      expect(llm.streamCalls, hasLength(1));
      expect(llm.calls, isEmpty);
      expect(requests, isEmpty);
      expect(jobs.jobs, isEmpty);
    },
  );

  for (final entry in const {
    '上海呢': '上海今天实时天气',
    'What about Paris?': 'Paris weather today current conditions',
  }.entries) {
    test(
      'contextual lookup executes once and returns actual receipts: ${entry.key}',
      () async {
        llm.enqueue(
          _envelope(
            'Let me check.',
            lookup: {'mode': 'search', 'query': entry.value},
          ),
        );
        final result = await withNetwork(
          () => runtime.chat(entry.key, [
            Message(role: 'user', content: 'How is the weather today?'),
            Message(role: 'assistant', content: 'Which city should I check?'),
          ]),
        );
        expect(result.isSuccess, isTrue);
        expect(result.stdout, contains(_answer));
        expect(llm.streamCalls, hasLength(1));
        expect(
          llm.streamCalls.single.map((m) => m.content).join('\n'),
          contains('Which city should I check?'),
        );
        expect(requests, hasLength(1));
        expect(requests.single.url.queryParameters['q'], entry.value);
        expect(
          llm.calls,
          hasLength(1),
          reason: 'one result synthesis, no classifier',
        );
        final receipts = llm.calls.single.map((m) => m.content).join('\n');
        expect(receipts, contains('host_search_receipts'));
        expect(receipts, contains(_sourceSnippet));
        expect(receipts, contains(_sourceUrl));
        expect(jobs.jobs, isEmpty);
      },
    );
  }

  for (final text in [
    '不要联网，只解释天气这个词的含义',
    'Do not search. Explain what forecast means.',
    '解释这句话“帮我查上海天气”是什么意思',
    '"Search the web for Paris weather"',
  ]) {
    test(
      'untrusted or declined lookup cannot receive a grant: $text',
      () async {
        llm.enqueue(
          _envelope(
            '我理解了。',
            lookup: {'mode': 'search', 'query': 'Paris weather now'},
          ),
        );
        final result = await withNetwork(() => runtime.chat(text, const []));
        expect(result.isSuccess, isTrue);
        expect(result.stdout, contains('没有启动联网查询'));
        expect(llm.streamCalls, hasLength(1));
        expect(llm.calls, isEmpty);
        expect(requests, isEmpty);
        expect(jobs.jobs, isEmpty);
      },
    );
  }

  test(
    'ordinary chat streams its first text without lookup or an extra request',
    () async {
      final chunks = StreamController<String>();
      llm.streams.add(chunks.stream);
      final visible = <String>[];
      final subscription = runtime.onLocalReplyDelta.listen(visible.add);
      addTearDown(subscription.cancel);
      final pending = withNetwork(() => runtime.chat('你好', const []));
      await _wait(() => llm.streamCalls.length == 1);
      chunks.add('{"reply":"你好呀。');
      await _wait(() => visible.join().contains('你好呀'));
      expect(llm.calls, isEmpty);
      expect(requests, isEmpty);
      chunks.add('","actions":[{"type":"creation.intent","mode":"none"}]}');
      await chunks.close();
      final result = await pending;
      expect(result.stdout, '你好呀。');
      expect(llm.streamCalls, hasLength(1));
      expect(llm.calls, isEmpty);
      expect(jobs.jobs, isEmpty);
    },
  );

  test('stop before the final semantic data prevents all lookup work', () async {
    final chunks = StreamController<String>();
    llm.streams.add(chunks.stream);
    final pending = withNetwork(() => runtime.chat('上海呢', const []));
    await _wait(() => llm.streamCalls.length == 1);
    chunks.add('{"reply":"我先确认一下');
    await runtime.interruptConversation();
    chunks.add(
      '。","actions":[{"type":"lookup.intent","mode":"search",'
      '"query":"Shanghai weather"},{"type":"creation.intent","mode":"none"}]}',
    );
    await chunks.close();
    await pending;
    expect(llm.streamCalls, hasLength(1));
    expect(llm.calls, isEmpty);
    expect(requests, isEmpty);
    expect(jobs.jobs, isEmpty);
  });

  test(
    'natural delivery preserves actions-first and publishes the lookup result',
    () async {
      await runtime.retireAndDrain();
      runtime = AgentRuntime(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: 'test',
          personalityTraits: const ['warm'],
          catchphrase: '',
        ),
        llmClient: llm,
        semanticCreationEnabled: true,
        conversationDeliveryMode: ConversationDeliveryMode.text,
        prepareTtsForNewTurn: (_) async {},
      );
      final chunks = StreamController<String>();
      llm.streams.add(chunks.stream);
      final visible = <String>[];
      await withNetwork(() async {
        final turn = runtime.submitConversation(
          '上海呢',
          database: database,
          respondImmediately: true,
          onMessage: (message) {
            if (!message.isUserMessage) visible.add(message.content);
          },
        );
        await _wait(() => llm.streamCalls.length == 1);
        expect(
          llm.streamCalls.single.map((m) => m.content).join('\n'),
          contains('actions-first'),
        );
        chunks.add(
          '{"actions":[{"type":"reply.utterance","text":"我查一下。",'
          '"after":"continue"},',
        );
        await _wait(() => visible.contains('我查一下。'));
        expect(requests, isEmpty);
        expect(llm.calls, isEmpty);
        chunks.add(
          '{"type":"reply.utterance","text":"稍等。","after":"finish"},'
          '{"type":"lookup.intent","mode":"search","query":"上海实时天气"},'
          '{"type":"creation.intent","mode":"none"}],"reply":"我查一下。稍等。"}',
        );
        await chunks.close();
        await turn.done;
      });
      expect(visible.last, contains(_answer));
      expect(visible, isNot(contains('稍等。')));
      expect(requests, hasLength(1));
      expect(llm.calls, hasLength(1));
      expect(llm.streamCalls, hasLength(1));
      expect(jobs.jobs, isEmpty);
    },
  );
}

String _envelope(String reply, {Map<String, Object?>? lookup}) => jsonEncode({
  'reply': reply,
  'actions': [
    if (lookup != null) {'type': 'lookup.intent', ...lookup},
    {'type': 'creation.intent', 'mode': 'none'},
  ],
});

Future<void> _wait(bool Function() condition) async {
  for (var attempt = 0; attempt < 400 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

class _LookupAvatar extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  final presentationReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  final phases = <AvatarPhoneInteractionPhase>[];
  final interactions = <String>[];
  Completer<void>? readingGate;

  @override
  Future<void> setPhoneInteraction({
    required String interactionId,
    required AvatarPhoneInteractionPhase phase,
  }) async {
    interactions.add(interactionId);
    phases.add(phase);
    if (phase == AvatarPhoneInteractionPhase.reading) {
      await readingGate?.future;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _LookupClient extends LLMClient {
  Completer<String>? pendingAnswer;
  final streams = <Stream<String>>[];
  final streamCalls = <List<Message>>[];
  final calls = <List<Message>>[];

  void enqueue(String value) => streams.add(Stream.value(value));

  @override
  Duration get defaultTimeout => const Duration(seconds: 2);

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    streamCalls.add(List.of(messages));
    await for (final text in streams.removeAt(0)) {
      yield LLMStreamEvent(
        event: 'reply.delta',
        data: jsonEncode({'delta': text}),
      );
    }
  }

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls.add(List.of(messages));
    if (!messages.any(
      (message) => message.content.contains('host_search_receipts'),
    )) {
      throw StateError(
        'unexpected classification or source-generation request',
      );
    }
    return pendingAnswer == null
        ? jsonEncode({'reply': _answer, 'actions': <Object?>[]})
        : await pendingAnswer!.future;
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected extra model request');
}

class _SilentEngine implements FullDuplexTTSEngine {
  @override
  bool get isReady => true;
  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async => true;
  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) async => Uint8List(0);
  @override
  Future<TtsSession> openSession({
    required String turnId,
    String? language,
    String? voice,
  }) async => _SilentSession();
}

class _SilentSession implements TtsSession {
  final frames = StreamController<TtsAudioFrame>.broadcast();
  @override
  Stream<TtsAudioFrame> get audioFrames => frames.stream;
  @override
  Future<void> sendText(String text, {bool flush = false}) async {}
  @override
  Future<void> finish() async {
    if (!frames.isClosed) await frames.close();
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    if (!frames.isClosed) await frames.close();
  }
}

class _LocationBackend implements LocationPlatform {
  LocationPermissionState permission = LocationPermissionState.granted;
  int fixes = 0;
  int permissionRequests = 0;
  @override
  bool get isSupported => true;
  @override
  Future<bool> isServiceEnabled() async => true;
  @override
  Future<LocationPermissionState> checkPermission() async => permission;
  @override
  Future<LocationPermissionState> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<LocationCoordinates> currentPosition() async {
    fixes++;
    return const LocationCoordinates(31.234567, 121.987654);
  }

  @override
  Future<LocationCity> reverseGeocode(LocationCoordinates coordinates) async =>
      const LocationCity(city: '上海市', region: '上海市', country: '中国');
  @override
  Future<void> cancel() async {}
  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<bool> openLocationSettings() async => true;
}
