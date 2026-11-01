import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/application/game_frame_processor.dart';
import 'package:maaso/src/features/widgets_hub/application/game_perception_coordinator.dart';
import 'package:maaso/src/features/widgets_hub/data/game_perception_gateway.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:sembast/sembast_memory.dart';

class _Registry extends AgentRuntimeRegistry {
  _Registry([this.runtime]);
  final AgentRuntime? runtime;
  int ensures = 0;
  @override
  AgentRuntime? get(String id) => runtime;
  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async {
    ensures++;
    throw StateError('The test expects its installed local runtime');
  }
}

class _LocalRuntime extends AgentRuntime {
  _LocalRuntime()
    : super(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const [],
          catchphrase: '',
        ),
        llmClient: _UnusedModel(),
      );
  final texts = <String>[];
  final histories = <List<Message>>[];
  final answers = <Completer<ExecutionResult>>[];
  final revoked = <String>[];
  final speechPermissions =
      <({bool Function()? allowed, Future<void>? revoked})>[];
  int wideCancels = 0;
  // This fixture explicitly exercises the retained legacy voice entry.
  @override
  bool get usesConversationTurns => false;
  @override
  Stream<String> get onLocalReplyDelta => const Stream.empty();
  @override
  Future<ExecutionResult> runGuardedVoiceChat(
    String text,
    List<Message> history, {
    required bool Function() isCurrent,
    Future<void>? onRevoked,
    TurnOrigin origin = TurnOrigin.voice,
    StreamingAudioSink? liveAudioSink,
    bool Function()? spokenRepliesAllowed,
    Future<void>? onSpeechRevoked,
  }) {
    speechPermissions.add((
      allowed: spokenRepliesAllowed,
      revoked: onSpeechRevoked,
    ));
    onRevoked?.then((_) => revoked.add(text));
    final response = chat(text, history, origin: origin);
    return onRevoked == null
        ? response
        : Future.any<ExecutionResult>([
            response,
            onRevoked.then((_) => ExecutionResult.error('page_revoked')),
          ]);
  }

  @override
  Future<ExecutionResult> chat(
    String text,
    List<Message> history, {
    TurnOrigin origin = TurnOrigin.user,
    String? currentUserText,
    StreamingAudioSink? liveAudioSink,
    String? expectedAppletScopeKey,
  }) {
    texts.add(text);
    histories.add(List.of(history));
    final answer = Completer<ExecutionResult>();
    answers.add(answer);
    return answer.future;
  }

  @override
  void cancelCurrent() {
    wideCancels++;
  }
}

class _UnusedModel implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// This one loopback integration fixture needs a real socket rather than the
// widget-test binding's global HTTP-400 stub. Other tests keep mocked clients.
class _LoopbackHttpOverrides extends HttpOverrides {}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 300 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

Uint8List _pixels() =>
    Uint8List.fromList(image.encodeJpg(image.Image(width: 16, height: 16)));

GamePerceptionCoordinator _perception(
  GameVoiceCompanionSession session,
  GamePerceptionGateway gateway,
) => GamePerceptionCoordinator(
  capture: session.capture,
  gateway: gateway,
  isCurrent: () => session.isCurrent,
  onObservation: session.observeVisual,
  onStatus: session.updatePerceptionStatus,
  question: () => 'Describe the visible game.',
  locale: () => 'en',
  samplingInterval: const Duration(hours: 1),
  staticSamplingInterval: const Duration(hours: 1),
  minimumDispatchInterval: Duration.zero,
  processor: (bytes) async => ProcessedGameFrame(
    jpegBytes: bytes,
    contentHash: sha256.convert(bytes).toString(),
    width: 16,
    height: 16,
    fingerprint: Uint8List(1024),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService database;
  setUp(() async {
    await appServices.reset();
    MaasoTtsPlugin.soundEnabled.value = true;
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'game-voice-${DateTime.now().microsecondsSinceEpoch}',
    );
  });
  tearDown(() async {
    await appServices.reset();
    await database.close();
    MaasoTtsPlugin.soundEnabled.value = true;
  });

  test(
    'local voice receives the original game question and observation and persists one reply',
    () async {
      final context = appServices.put(CompanionBrowsingContextService());
      final games = appServices.put(
        GameVoiceCompanionService(
          browsingContext: context,
          commentary:
              (observation, {required isCurrent, required onRevoked}) async =>
                  false,
        ),
      );
      games
          .openSession(
            scopeKey: 'owner-a',
            playerId: 'game-a',
            title: 'Gomoku',
            summary: 'Local CPU',
            isCurrent: () => true,
          )
          .observeEnvelope({
            'kind': 'game.state',
            'revision': 1,
            'state': {
              'board': [0, 1, 0],
            },
          });
      final runtime = _LocalRuntime();
      final registry = _Registry(runtime);
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: registry,
        browsingContext: context,
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'What is happening?';
      final send = controller.sendVoiceMessage();
      await _until(() => runtime.answers.isNotEmpty);
      expect(registry.ensures, 0);
      expect(runtime.texts.single, 'What is happening?');
      expect(runtime.histories.single.first.content, contains('board'));
      expect(runtime.histories.single.first.content, contains('untrusted'));
      runtime.answers.single.complete(
        ExecutionResult.success('Your local opponent just moved.'),
      );
      await send;
      expect(runtime.texts, hasLength(1));
      expect(controller.latestReply, 'Your local opponent just moved.');
      final rows = await database.getMessages('self');
      expect(rows.map((row) => row.content), [
        'What is happening?',
        'Your local opponent just moved.',
      ]);
      expect(rows.every((row) => row.turnOrigin == 'voice'), isTrue);
    },
  );

  test(
    'page cancellation revokes its local voice turn and rejects a late reply',
    () async {
      final runtime = _LocalRuntime();
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _Registry(runtime),
      );
      addTearDown(controller.dispose);
      final pageClosed = Completer<void>();
      controller.activate();
      controller.inputController.text = 'first game';
      final first = controller.sendVoiceMessage(onRevoked: pageClosed.future);
      await _until(() => runtime.answers.length == 1);
      pageClosed.complete();
      await first;
      await _until(() => runtime.revoked.contains('first game'));
      controller.inputController.text = 'next game';
      final next = controller.sendVoiceMessage();
      await _until(() => runtime.answers.length == 2);
      runtime.answers.first.complete(
        ExecutionResult.success('Old stale reply'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(runtime.revoked, ['first game']);
      expect(runtime.wideCancels, 0);
      expect(controller.latestReply, isNot('Old stale reply'));
      runtime.answers.last.complete(ExecutionResult.success('Current reply'));
      await next;
      expect(controller.latestReply, 'Current reply');
      expect((await database.getMessages('self')).map((row) => row.content), [
        'first game',
        'next game',
        'Current reply',
      ]);
    },
  );

  for (final boundary in ['voice off', 'companion off', 'page exit']) {
    test(
      'legacy game question carries scoped voice permission through $boundary',
      () async {
        MaasoTtsPlugin.soundEnabled.value = false;
        final context = appServices.put(CompanionBrowsingContextService());
        final games = appServices.put(
          GameVoiceCompanionService(
            browsingContext: context,
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
        final runtime = _LocalRuntime();
        final controller = CompanionVoiceSessionController(
          database: database,
          runtimeRegistry: _Registry(runtime),
          browsingContext: context,
        )..activate();
        addTearDown(controller.dispose);
        controller.inputController.text = 'Tell me a joke';
        final sending = controller.sendVoiceMessage();
        await _until(() => runtime.speechPermissions.isNotEmpty);
        final permission = runtime.speechPermissions.single;
        expect(permission.allowed, isNotNull);
        expect(permission.allowed!(), isTrue);
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
        if (boundary == 'voice off') {
          games.setSpokenRepliesEnabled(false);
        } else if (boundary == 'companion off') {
          games.setPreferences(games.preferences.copyWith(enabled: false));
        } else {
          session.close();
        }
        await permission.revoked!.timeout(const Duration(seconds: 1));
        expect(permission.allowed!(), isFalse);
        if (boundary == 'page exit') {
          games.openSession(
            scopeKey: 'owner-a',
            playerId: 'game-b',
            title: 'New puzzle',
            summary: '',
            isCurrent: () => true,
          );
          expect(games.currentSession!.spokenRepliesEnabled, isTrue);
          expect(
            permission.allowed!(),
            isFalse,
            reason: 'A new player cannot authorize the old reply.',
          );
        }
        runtime.answers.single.complete(
          ExecutionResult.success('A text answer.'),
        );
        await sending;
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      },
    );
  }

  for (final initiallyEnabled in [true, false]) {
    test(
      'legacy question cannot acquire a new voice epoch after DOM wait: $initiallyEnabled',
      () async {
        MaasoTtsPlugin.soundEnabled.value = false;
        final context = appServices.put(CompanionBrowsingContextService());
        final games = appServices.put(
          GameVoiceCompanionService(
            browsingContext: context,
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
        final runtime = _LocalRuntime();
        final controller = CompanionVoiceSessionController(
          database: database,
          runtimeRegistry: _Registry(runtime),
          browsingContext: context,
        )..activate();
        addTearDown(controller.dispose);
        controller.inputController.text = 'Tell me a joke';
        final sending = controller.sendVoiceMessage();
        await reading.future.timeout(const Duration(seconds: 1));
        expect(runtime.speechPermissions, isEmpty);
        if (initiallyEnabled) games.setSpokenRepliesEnabled(false);
        games.setSpokenRepliesEnabled(true);
        await originalEpoch.timeout(const Duration(seconds: 1));
        expect(session.onSpeechRevoked, isNot(same(originalEpoch)));
        visible.complete('A puzzle is visible.');
        await _until(() => runtime.speechPermissions.isNotEmpty);
        final old = runtime.speechPermissions.single;
        expect(old.revoked, same(originalEpoch));
        expect(old.allowed!(), isFalse);
        await old.revoked!.timeout(const Duration(seconds: 1));
        runtime.answers.single.complete(
          ExecutionResult.success('A text-only answer.'),
        );
        await sending;
        controller.inputController.text = 'Tell me another joke';
        final next = controller.sendVoiceMessage();
        await _until(() => runtime.speechPermissions.length == 2);
        expect(runtime.speechPermissions.last.allowed!(), isTrue);
        expect(
          runtime.speechPermissions.last.revoked,
          same(session.onSpeechRevoked),
        );
        expect(old.allowed!(), isFalse);
        runtime.answers.last.complete(ExecutionResult.success('A new answer.'));
        await next;
        expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      },
    );
  }

  test(
    'retiring an old page cannot cancel a newer shared-runtime voice turn',
    () async {
      final runtime = _LocalRuntime();
      final registry = _Registry(runtime);
      final first = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: registry,
      );
      final next = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: registry,
      );
      addTearDown(first.dispose);
      addTearDown(next.dispose);
      first.activate();
      first.inputController.text = 'old game';
      final oldSend = first.sendVoiceMessage();
      await _until(() => runtime.answers.length == 1);
      first.deactivate();
      next.activate();
      next.inputController.text = 'new game';
      final newSend = next.sendVoiceMessage();
      await _until(() => runtime.answers.length == 2);
      final retiring = first.deactivateAndDrain();
      runtime.answers.first.complete(ExecutionResult.success('Old answer'));
      await oldSend;
      await retiring;
      first.dispose();
      expect(runtime.wideCancels, 0);
      expect(runtime.revoked, contains('old game'));
      expect(runtime.revoked, isNot(contains('new game')));
      expect(next.isThinking, isTrue);
      runtime.answers.last.complete(ExecutionResult.success('New answer'));
      await newSend;
      expect(next.latestReply, 'New answer');
      expect((await database.getMessages('self')).map((m) => m.content), [
        'old game',
        'new game',
        'New answer',
      ]);
    },
  );

  test(
    'a completed reply retains its output guard until the page exits',
    () async {
      final runtime = _LocalRuntime();
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _Registry(runtime),
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'game question';
      final send = controller.sendVoiceMessage();
      await _until(() => runtime.answers.isNotEmpty);
      runtime.answers.single.complete(ExecutionResult.success('Answer'));
      await send;
      expect(runtime.revoked, isEmpty);
      controller.deactivate();
      await _until(() => runtime.revoked.isNotEmpty);
      expect(runtime.revoked, ['game question']);
      expect(runtime.wideCancels, 0);
    },
  );

  test(
    'game vision requires explicit opt-in and never uses the photo quota path',
    () async {
      final context = appServices.put(CompanionBrowsingContextService());
      var admissions = 0,
          requests = 0,
          captures = 0,
          photoAdmissions = 0,
          photoRequests = 0;
      appServices.put(
        ChatMediaService(
          database: database.raw,
          isCurrent: () => true,
          baseUri: Uri.parse('https://synthetic.invalid/'),
          accessToken: () async => 'synthetic',
          authorize: () async {
            photoAdmissions++;
          },
          client: MockClient((_) async {
            photoRequests++;
            throw StateError(
              'Game frames must not use ordinary photo analysis',
            );
          }),
        ),
      );
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        isCurrent: () => true,
        authorize: () async {
          admissions++;
        },
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/v1/proxy/game-perception/analyze');
          final body = jsonDecode(request.body) as Map;
          expect(body['question'], 'Describe the visible game.');
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': {
                'description': 'The piece is in the center.',
                'modelId': 'synthetic-vision',
                'sourceMediaIds': [(body['media'] as List).single['id']],
              },
            }),
            200,
          );
        }),
      );
      final games = appServices.put(
        GameVoiceCompanionService(
          browsingContext: context,
          commentary: (_, {required isCurrent, required onRevoked}) async =>
              false,
          createPerception: (session) => _perception(session, gateway),
        ),
      );
      addTearDown(() async {
        games.currentSession?.close();
        await gateway.shutdown();
      });
      final session = games.openSession(
        scopeKey: 'a',
        playerId: 'old-game',
        title: 'Old game',
        summary: 'Description',
        isCurrent: () => true,
        captureScreenshot: () async {
          captures++;
          return _pixels();
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(captures, 0);
      expect(requests, 0);
      games.setVisualEnabled(true);
      await _until(
        () =>
            session.latest?.publicState.toString().contains(
              'The piece is in the center.',
            ) ==
            true,
      );
      final runtime = _LocalRuntime();
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _Registry(runtime),
        browsingContext: context,
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'Where is the piece?';
      final send = controller.sendVoiceMessage();
      await _until(() => runtime.answers.isNotEmpty);
      expect(admissions, 1);
      expect(requests, 1);
      expect(photoAdmissions, 0);
      expect(photoRequests, 0);
      expect(runtime.texts.single, 'Where is the piece?');
      expect(
        runtime.histories.single.first.content,
        contains('The piece is in the center.'),
      );
      expect(
        runtime.histories.single.first.content,
        isNot(contains('data:image')),
      );
      runtime.answers.single.complete(
        ExecutionResult.success('It is in the center.'),
      );
      await send;
      expect((await database.getMessages('self')).map((m) => m.content), [
        'Where is the piece?',
        'It is in the center.',
      ]);
    },
  );

  test(
    'privacy refusal stops frame dispatch while ordinary voice remains available',
    () async {
      final context = appServices.put(CompanionBrowsingContextService());
      var admissions = 0, requests = 0;
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        isCurrent: () => true,
        authorize: () async {
          admissions++;
          throw const PrivacyException('PRIVACY_CONSENT_REQUIRED');
        },
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final games = appServices.put(
        GameVoiceCompanionService(
          browsingContext: context,
          commentary: (_, {required isCurrent, required onRevoked}) async =>
              false,
          createPerception: (session) => _perception(session, gateway),
        ),
      );
      addTearDown(() async {
        games.currentSession?.close();
        await gateway.shutdown();
      });
      final session = games.openSession(
        scopeKey: 'a',
        playerId: 'private-game',
        title: 'Puzzle',
        summary: 'A local game',
        isCurrent: () => true,
        captureScreenshot: () async => _pixels(),
      );
      games.setVisualEnabled(true);
      await _until(
        () => session.perceptionStatus == GamePerceptionStatus.disabled,
      );
      final runtime = _LocalRuntime();
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _Registry(runtime),
        browsingContext: context,
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'Keep chatting with me';
      final send = controller.sendVoiceMessage();
      await _until(() => runtime.answers.isNotEmpty);
      expect(admissions, 1);
      expect(requests, 0);
      expect(runtime.texts.single, 'Keep chatting with me');
      runtime.answers.single.complete(ExecutionResult.success('I am here.'));
      await send;
    },
  );

  test(
    'late screenshot after page exit never dispatches a local voice turn',
    () async {
      final context = appServices.put(CompanionBrowsingContextService());
      final screenshot = Completer<Uint8List?>();
      var captures = 0, requests = 0;
      final gateway = GamePerceptionGateway(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final games = appServices.put(
        GameVoiceCompanionService(
          browsingContext: context,
          commentary: (_, {required isCurrent, required onRevoked}) async =>
              false,
          createPerception: (session) => _perception(session, gateway),
        ),
      );
      addTearDown(() async {
        games.currentSession?.close();
        await gateway.shutdown();
      });
      final session = games.openSession(
        scopeKey: 'a',
        playerId: 'old',
        title: 'Old',
        summary: '',
        isCurrent: () => true,
        captureScreenshot: () {
          captures++;
          return screenshot.future;
        },
      );
      games.setVisualEnabled(true);
      final runtime = _LocalRuntime();
      final registry = _Registry(runtime);
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: registry,
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'Look at this game';
      final send = controller.sendVoiceMessage(onRevoked: session.onRevoked);
      await _until(() => captures > 0);
      session.close();
      await send;
      screenshot.complete(_pixels());
      await Future<void>.delayed(Duration.zero);
      expect(runtime.texts, isEmpty);
      expect(requests, 0);
      expect(registry.ensures, 0);
      expect(controller.latestReply, isEmpty);
      expect(await database.getMessages('self'), isEmpty);
    },
  );

  test('leaving the page aborts a real in-flight game HTTP response', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Socket? connection;
    final received = Completer<void>(), disconnected = Completer<void>();
    final subscription = server.listen((socket) {
      connection = socket;
      socket.listen(
        (bytes) {
          if (!received.isCompleted) {
            expect(
              utf8.decode(bytes),
              contains('/v1/proxy/game-perception/analyze'),
            );
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n',
            );
            received.complete();
          }
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
        onError: (Object _) {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    addTearDown(() async {
      connection?.destroy();
      await subscription.cancel();
      await server.close();
    });
    final context = appServices.put(CompanionBrowsingContextService());
    final realClient = HttpOverrides.runWithHttpOverrides(
      http.Client.new,
      _LoopbackHttpOverrides(),
    );
    addTearDown(realClient.close);
    final gateway = GamePerceptionGateway(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
      client: realClient,
      accessToken: () async => 'synthetic',
      authorize: () async {},
      isCurrent: () => true,
    );
    final games = appServices.put(
      GameVoiceCompanionService(
        browsingContext: context,
        commentary: (_, {required isCurrent, required onRevoked}) async =>
            false,
        createPerception: (session) => _perception(session, gateway),
      ),
    );
    addTearDown(() async {
      games.currentSession?.close();
      await gateway.shutdown();
    });
    final session = games.openSession(
      scopeKey: 'a',
      playerId: 'http-game',
      title: 'HTTP game',
      summary: '',
      isCurrent: () => true,
      captureScreenshot: () async => _pixels(),
    );
    games.setVisualEnabled(true);
    final runtime = _LocalRuntime();
    final controller = CompanionVoiceSessionController(
      database: database,
      runtimeRegistry: _Registry(runtime),
    );
    addTearDown(controller.dispose);
    controller.activate();
    controller.inputController.text = 'What do you see right now?';
    final send = controller.sendVoiceMessage(onRevoked: session.onRevoked);
    await received.future.timeout(const Duration(seconds: 5));
    session.close();
    await disconnected.future.timeout(const Duration(seconds: 5));
    await send;
    expect(runtime.texts, isEmpty);
    expect(await database.getMessages('self'), isEmpty);
  });

  test(
    'a scene change revokes a concrete hint but not ordinary conversation',
    () async {
      final context = appServices.put(CompanionBrowsingContextService());
      final games = appServices.put(
        GameVoiceCompanionService(
          browsingContext: context,
          commentary: (_, {required isCurrent, required onRevoked}) async =>
              false,
        ),
      );
      final session = games.openSession(
        scopeKey: 'a',
        playerId: 'board',
        title: 'Board',
        summary: '',
        isCurrent: () => true,
      );
      void state(int revision) => session.observeEnvelope({
        'kind': 'game.state',
        'revision': revision,
        'state': {
          'board': [revision],
        },
      });
      state(1);
      final runtime = _LocalRuntime();
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _Registry(runtime),
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'Which move should I make right now?';
      final hint = controller.sendVoiceMessage();
      await _until(() => runtime.answers.length == 1);
      state(2);
      await hint;
      runtime.answers.first.complete(ExecutionResult.success('Stale move'));
      await _until(
        () => runtime.revoked.contains('Which move should I make right now?'),
      );
      expect(controller.latestReply, isNot('Stale move'));
      controller.inputController.text = 'Tell me a silly joke';
      final joke = controller.sendVoiceMessage();
      await _until(() => runtime.answers.length == 2);
      state(3);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.revoked, isNot(contains('Tell me a silly joke')));
      runtime.answers.last.complete(
        ExecutionResult.success('The rook called a cab.'),
      );
      await joke;
      expect(controller.latestReply, 'The rook called a cab.');
      expect((await database.getMessages('self')).map((m) => m.content), [
        'Which move should I make right now?',
        'Tell me a silly joke',
        'The rook called a cab.',
      ]);
    },
  );

  test(
    'an uninstrumented DOM game supplies quoted context without replacing human text',
    () async {
      final context = appServices.put(CompanionBrowsingContextService());
      final games = appServices.put(
        GameVoiceCompanionService(
          browsingContext: context,
          commentary: (_, {required isCurrent, required onRevoked}) async =>
              false,
        ),
      );
      games
          .openSession(
            scopeKey: 'a',
            playerId: 'dom',
            title: 'Maze',
            summary: '',
            isCurrent: () => true,
          )
          .observeEnvelope({
            'kind': 'companion.snapshot',
            'revision': 1,
            'state': {
              'version': 1,
              'visibleText': 'The blue door is open.',
              'descriptor': {'version': 1, 'rules': 'Reach the exit.'},
            },
          });
      final runtime = _LocalRuntime();
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _Registry(runtime),
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'Stay with me';
      final send = controller.sendVoiceMessage();
      await _until(() => runtime.answers.isNotEmpty);
      expect(runtime.texts.single, 'Stay with me');
      expect(
        runtime.histories.single.first.content,
        contains('The blue door is open.'),
      );
      expect(
        runtime.histories.single.first.content,
        contains('Reach the exit.'),
      );
      expect(runtime.histories.single.first.content, contains('untrusted'));
      runtime.answers.single.complete(
        ExecutionResult.success('I am watching with you.'),
      );
      await send;
    },
  );

  test(
    'unavailable local execution retains the voice draft and emits no rows',
    () async {
      final runtime = _LocalRuntime();
      final controller = CompanionVoiceSessionController(
        database: database,
        runtimeRegistry: _Registry(runtime),
        canExecute: () => false,
      );
      addTearDown(controller.dispose);
      controller.activate();
      controller.inputController.text = 'Keep this question';
      await controller.sendVoiceMessage();
      expect(runtime.texts, isEmpty);
      expect(controller.inputController.text, 'Keep this question');
      expect(await database.getMessages('self'), isEmpty);
    },
  );
}
