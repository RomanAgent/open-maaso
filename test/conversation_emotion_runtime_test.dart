import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_affect_diagnostics.dart';
import 'package:maaso/src/features/agent/application/conversation/reply_first_facial_cue.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:sembast/sembast_memory.dart';

import 'support/agent_sound_platforms.dart';

/// Uses the real chat, decoder, published-unit cue, event bus and emotion map.
/// Fixed transport responses make failures independent of a provider/model.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(installAgentSoundPlatforms);

  for (final typed in [false, true]) {
    final transport = typed ? 'typed stream with raw proof' : 'raw JSON';
    for (final persistent in <bool?>[null, false, true]) {
      test(
        '$transport carries persistent=$persistent to the actual avatar',
        () async {
          final f = await _Fixture.create(typed: typed);
          try {
            final body = <String, Object?>{
              'mood': 'surprised',
              'gesture': 'none',
              'intensity': .55,
              'durationMs': 1800,
              'persistent': ?persistent,
            };
            final handle = f.submit('请表现惊讶的表情。');
            await f.waitForRequest();
            f.client.respond([_unit('确实很意外。', body: body)]);
            final result = await handle.done.timeout(_deadline);
            await _flush();
            expect(result.execution.isSuccess, isTrue);
            expect(
              f.messages.where((message) => !message.isUserMessage),
              hasLength(1),
            );
            final cue = f.emotions.singleWhere(
              (event) => event.semanticLabel == 'surprised',
            );
            expect(cue.persistent, persistent ?? false);
            expect(
              cue.duration,
              persistent == true ? null : const Duration(milliseconds: 1800),
            );
            expect(f.avatar.expressions.last.surprised, closeTo(.55, .00001));
            expect(f.client.requests, 1);
            expect(f.client.aggregateRequests, 0);
          } finally {
            await f.close();
          }
        },
      );
    }

    test(
      '$transport permits ordinary chat without manufacturing an emotion',
      () async {
        final f = await _Fixture.create(typed: typed);
        try {
          final handle = f.submit('今天吃什么好？');
          await f.waitForRequest();
          // Words alone are not an execution protocol, even when emotive.
          f.client.respond([_unit('这个想法还挺让人惊讶的。')]);
          final result = await handle.done.timeout(_deadline);
          await _flush();
          expect(result.execution.isSuccess, isTrue);
          expect(
            f.avatar.expressions.every((params) => params.surprised == 0),
            isTrue,
          );
          expect(
            f.emotions.where((event) => event.semanticLabel == 'surprised'),
            isEmpty,
          );
          expect(f.client.requests, 1);
          expect(f.client.aggregateRequests, 0);
        } finally {
          await f.close();
        }
      },
    );

    for (final invalid in <Map<String, Object?>>[
      {'mood': 'surprised', 'persistent': 'false'},
      {'mood': 'surprised', 'bones': <String, Object?>{}},
    ]) {
      test(
        '$transport rejects invalid body $invalid before presentation',
        () async {
          final f = await _Fixture.create(typed: typed);
          try {
            final handle = f.submit('请表现惊讶。');
            await f.waitForRequest();
            f.client.respond([_unit('很意外。', body: invalid)]);
            final result = await handle.done.timeout(_deadline);
            await _flush();
            expect(result.execution.isSuccess, isFalse);
            expect(
              f.messages.where((message) => !message.isUserMessage),
              isEmpty,
            );
            expect(
              f.avatar.expressions.every((params) => params.surprised == 0),
              isTrue,
            );
            expect(f.client.requests, 1);
            expect(f.client.aggregateRequests, 0);
          } finally {
            await f.close();
          }
        },
      );
    }

    test(
      '$transport interruption retires the current temporary facial cue',
      () async {
        final f = await _Fixture.create(typed: typed);
        try {
          final handle = f.submit('请短暂表现惊讶。');
          await f.waitForRequest();
          f.client.respond([
            _unit(
              '很意外。',
              body: {
                'mood': 'surprised',
                'gesture': 'none',
                'intensity': .8,
                'durationMs': 350,
                'persistent': false,
              },
            ),
          ]);
          await handle.done.timeout(_deadline);
          await _flush();
          expect(f.avatar.expressions.last.surprised, greaterThan(.7));
          await f.runtime.interruptConversation();
          await _flush();
          final retired = f.avatar.expressions.length;
          expect(f.avatar.expressions.last.surprised, 0);
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(
            f.avatar.expressions
                .skip(retired)
                .every((params) => params.surprised == 0),
            isTrue,
            reason: 'An expired old cue cannot regain ownership.',
          );
          expect(f.client.requests, 1);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    test(
      'contract shares semantic moods and expression intent in $locale',
      () async {
        final f = await _Fixture.create(typed: true, locale: locale);
        try {
          final handle = f.submit('Hello');
          await f.waitForRequest();
          final contract = f.client.messages.single
              .map((message) => message.content)
              .singleWhere((content) => content.contains('Keep the top-level'));
          for (final mood in AvatarBodyIntentPolicy.conversationMoods) {
            expect(contract, contains(mood));
            expect(AvatarBodyIntentPolicy.normalize({'mood': mood}), isNotNull);
          }
          expect(
            contract,
            contains('explicitly asks you to show a facial expression'),
          );
          expect(contract, contains('Omit body when no cue is useful'));
          f.client.respond([_unit('Hello')]);
          await handle.done.timeout(_deadline);
          expect(f.client.requests, 1);
          expect(f.client.aggregateRequests, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  test(
    'a proven first utterance remains publishable before the model is done',
    () async {
      final f = await _Fixture.create(typed: true);
      try {
        final first = _unit('我听到了。', after: 'continue');
        final second = _unit('我们慢慢说。');
        final handle = f.submit('陪我聊聊天。');
        await f.waitForRequest();
        f.client.events.add(
          LLMStreamEvent(
            event: 'reply.delta',
            data: jsonEncode({'delta': '{"actions":[${jsonEncode(first)},'}),
          ),
        );
        f.client.events.add(
          LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(first)),
        );
        await _waitUntil(
          () => f.messages.any((message) => !message.isUserMessage),
        );
        expect(
          f.messages.where((message) => !message.isUserMessage).single.content,
          '我听到了。',
        );
        expect(f.client.requests, 1);
        expect(f.client.aggregateRequests, 0);
        f.client.events.add(
          LLMStreamEvent(
            event: 'reply.delta',
            data: jsonEncode({
              'delta': '${jsonEncode(second)}],"reply":"我听到了。我们慢慢说。"}',
            }),
          ),
        );
        f.client.events.add(
          LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(second)),
        );
        f.client.finish();
        final result = await handle.done.timeout(_deadline);
        expect(result.execution.isSuccess, isTrue);
        expect(f.client.requests, 1);
      } finally {
        await f.close();
      }
    },
  );
  for (final typed in [false, true]) {
    final mode = typed ? 'typed/raw mirror' : 'raw';
    for (final persistent in [false, true]) {
      test(
        'shipping legacy $mode applies face once without replaying speech persistent=$persistent',
        () async {
          final f = await _Fixture.create(typed: typed, shipping: true);
          final deltas = <String>[];
          final spoken = <String>[];
          final deltaSub = f.runtime.onLocalReplyDelta.listen(deltas.add);
          final speechSub = EventBus().on<AgentSpeechQueuedEvent>().listen(
            (e) => spoken.add(e.text),
          );
          try {
            final result = f.runtime.chat('请表现明显的惊讶。', const <Message>[]);
            await f.waitForRequest();
            await f.primeReply('确实很意外。');
            final baselineBody = List<String>.of(f.avatar.bodyCalls);
            final baselineGaze = List<String>.of(f.avatar.gazeCalls);
            f.client.finishReplyFirstMetadata([
              _unit(
                '确实很意外。',
                body: {
                  'mood': 'surprised',
                  'intensity': .8,
                  'durationMs': 1800,
                  'persistent': persistent,
                },
              ),
              _noCreation,
            ]);
            final execution = await result.timeout(_deadline);
            await _flush();
            expect(execution.isSuccess, isTrue);
            expect(deltas.join(), '确实很意外。');
            expect(spoken, ['确实很意外。']);
            expect(
              f.emotions.where((e) => e.semanticLabel == 'surprised'),
              hasLength(1),
            );
            expect(
              f.avatar.expressions.any((p) => (p.surprised - .8).abs() < .0001),
              isTrue,
            );
            expect(
              f.avatar.bodyCalls,
              orderedEquals(baselineBody),
              reason: 'Omitted gesture must not infer a nod or cheer.',
            );
            expect(f.avatar.gazeCalls, orderedEquals(baselineGaze));
            await ConversationAffectDiagnostics.whenSettled;
            final records = await StoreRef<String, List<Object?>>(
              ConversationAffectDiagnostics.storeName,
            ).record('recent').get(f.database.raw);
            final receipt = Map<String, Object?>.from(records!.last! as Map);
            expect(receipt['outcome'], 'applied');
            expect(receipt['mood'], 'surprised');
            expect(receipt['rendererReady'], true);
            expect(f.client.requests, 1);
            expect(f.client.aggregateRequests, 0);
          } finally {
            await deltaSub.cancel();
            await speechSub.cancel();
            await f.close();
          }
        },
      );
    }

    test(
      'shipping legacy $mode has first text before metadata and no forced emotion',
      () async {
        final f = await _Fixture.create(typed: typed, shipping: true);
        final deltas = <String>[];
        final sub = f.runtime.onLocalReplyDelta.listen(deltas.add);
        try {
          final result = f.runtime.chat('今天吃什么？', const <Message>[]);
          await f.waitForRequest();
          f.client.delta('{"reply":"可以聊聊。"');
          await _waitUntil(() => deltas.join().isNotEmpty);
          expect(deltas.join(), '可以聊聊。');
          expect(
            f.emotions.where((e) => e.semanticLabel == 'surprised'),
            isEmpty,
          );
          expect(f.client.requests, 1);
          expect(f.client.aggregateRequests, 0);
          f.client.delta(',"actions":[${jsonEncode(_noCreation)}]}');
          f.client.finish();
          final execution = await result.timeout(_deadline);
          expect(execution.isSuccess, isTrue);
          expect(deltas.join(), '可以聊聊。');
          expect(f.avatar.expressions.every((p) => p.surprised == 0), isTrue);
          expect(f.client.requests, 1);
          expect(f.client.aggregateRequests, 0);
        } finally {
          await sub.cancel();
          await f.close();
        }
      },
    );

    for (final invalid in [
      'mismatch',
      'multiple',
      'after-creation',
      'after-lookup',
      'persistent-type',
      'raw-control',
      'body-motion',
    ]) {
      test(
        'shipping legacy $mode rejects optional face $invalid without repair',
        () async {
          final f = await _Fixture.create(typed: typed, shipping: true);
          try {
            final face = _unit(
              '很意外。',
              body: {'mood': 'surprised', 'gesture': 'none', 'intensity': .8},
            );
            final body = Map<String, Object?>.from(face['body']! as Map);
            final actions = <Map<String, Object?>>[face, _noCreation];
            switch (invalid) {
              case 'mismatch':
                actions[0] = {...face, 'text': '不是同一句。'};
              case 'multiple':
                actions.insert(0, {...face, 'after': 'continue'});
              case 'after-creation':
                actions
                  ..clear()
                  ..addAll([_noCreation, face]);
              case 'after-lookup':
                actions.insert(0, {
                  'type': 'lookup.intent',
                  'mode': 'clarify',
                  'question': '哪个城市？',
                });
              case 'persistent-type':
                actions[0] = {
                  ...face,
                  'body': {...body, 'persistent': 'false'},
                };
              case 'raw-control':
                actions[0] = {
                  ...face,
                  'body': {...body, 'bones': <String, Object?>{}},
                };
              case 'body-motion':
                actions[0] = {
                  ...face,
                  'body': {...body, 'gesture': 'wave'},
                };
              case 'actions-first':
                break;
            }
            final result = f.runtime.chat('请表现惊讶。', const <Message>[]);
            await f.waitForRequest();
            await f.primeReply('很意外。');
            final baselineBody = List<String>.of(f.avatar.bodyCalls);
            final baselineGaze = List<String>.of(f.avatar.gazeCalls);
            f.client.finishReplyFirstMetadata(actions);
            final execution = await result.timeout(_deadline);
            await _flush();
            expect(execution.isSuccess, isFalse);
            expect(
              f.emotions.where((e) => e.semanticLabel == 'surprised'),
              isEmpty,
            );
            expect(f.avatar.expressions.every((p) => p.surprised == 0), isTrue);
            expect(f.avatar.bodyCalls, orderedEquals(baselineBody));
            expect(f.avatar.gazeCalls, orderedEquals(baselineGaze));
            expect(f.client.requests, 1);
            expect(f.client.aggregateRequests, 0);
          } finally {
            await f.close();
          }
        },
      );
    }

    test(
      'shipping legacy $mode cancellation cannot admit late face metadata',
      () async {
        final f = await _Fixture.create(typed: typed, shipping: true);
        final deltas = <String>[];
        final sub = f.runtime.onLocalReplyDelta.listen(deltas.add);
        try {
          final result = f.runtime.chat('请表现惊讶。', const <Message>[]);
          await f.waitForRequest();
          f.client.delta('{"reply":"我听到了。"');
          await _waitUntil(() => deltas.isNotEmpty);
          await f.runtime.interruptConversation();
          f.client.delta(
            ',"actions":[${jsonEncode(_unit('我听到了。', body: {'mood': 'surprised', 'gesture': 'none'}))},${jsonEncode(_noCreation)}]}',
          );
          f.client.finish();
          await result.timeout(_deadline);
          await _flush();
          expect(
            f.emotions.where((e) => e.semanticLabel == 'surprised'),
            isEmpty,
          );
          expect(f.avatar.expressions.every((p) => p.surprised == 0), isTrue);
          expect(f.client.requests, 1);
          expect(f.client.aggregateRequests, 0);
        } finally {
          await sub.cancel();
          await f.close();
        }
      },
    );

    test(
      'shipping legacy $mode a new turn releases a previously held face',
      () async {
        final f = await _Fixture.create(typed: typed, shipping: true);
        try {
          final first = f.runtime.chat('保持惊讶的表情。', const <Message>[]);
          await f.waitForRequest();
          f.client.respondReplyFirst('很意外。', [
            _unit(
              '很意外。',
              body: {
                'mood': 'surprised',
                'gesture': 'none',
                'intensity': .8,
                'persistent': true,
              },
            ),
            _noCreation,
          ]);
          expect((await first.timeout(_deadline)).isSuccess, isTrue);
          await _flush();
          expect(f.avatar.expressions.last.surprised, closeTo(.8, .0001));
          final second = f.runtime.chat('恢复自然表情。', const <Message>[]);
          await _waitUntil(() => f.client.requests == 2);
          f.client.respondReplyFirst('好的。', [
            _unit(
              '好的。',
              body: {'mood': 'neutral', 'gesture': 'none', 'persistent': true},
            ),
            _noCreation,
          ]);
          expect((await second.timeout(_deadline)).isSuccess, isTrue);
          await _flush();
          expect(f.avatar.expressions.last.surprised, 0);
          expect(
            f.emotions.where((e) => e.semanticLabel == 'surprised'),
            hasLength(1),
          );
          expect(f.client.requests, 2);
          expect(f.client.aggregateRequests, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final locale in [const Locale('zh', 'CN'), const Locale('en', 'US')]) {
    test(
      'shipping reply-first facial contract is available in $locale',
      () async {
        final f = await _Fixture.create(
          typed: false,
          shipping: true,
          locale: locale,
        );
        try {
          final result = f.runtime.chat('Hello', const <Message>[]);
          await f.waitForRequest();
          final prompt = f.client.messages.single
              .map((m) => m.content)
              .join('\n');
          for (final mood in AvatarBodyIntentPolicy.conversationMoods) {
            expect(prompt, contains(mood));
          }
          expect(prompt, contains('0.65..0.85'));
          expect(prompt, contains('reply.utterance'));
          final exampleLine = prompt
              .split('\n')
              .firstWhere(
                (line) =>
                    (line.startsWith('示例：') || line.startsWith('Example:')) &&
                    line.contains('"body"'),
              );
          final example = const ConversationReplyDecoder().decode(
            exampleLine.substring(exampleLine.indexOf('{')),
          );
          expect(
            ReplyFirstFacialCue.validate(example, streamedReply: example.reply),
            isNotNull,
          );
          expect(
            prompt,
            isNot(
              contains(
                'actions contains exactly one creation.intent and no reply.utterance',
              ),
            ),
          );
          expect(
            prompt,
            isNot(
              contains(
                'actions 必须且只能包含一个 creation.intent，不得包含 reply.utterance',
              ),
            ),
          );
          f.client.respondReplyFirst('Hello', [_noCreation]);
          expect((await result.timeout(_deadline)).isSuccess, isTrue);
          expect(f.client.requests, 1);
          expect(f.client.aggregateRequests, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  test(
    'shipping generic creation ordering still uses the existing semantic repair',
    () async {
      final f = await _Fixture.create(typed: false, shipping: true);
      try {
        f.client.repairReply = '{"type":"creation.intent","mode":"none"}';
        final result = f.runtime.chat('你好。', const <Message>[]);
        await f.waitForRequest();
        f.client.respondReplyFirst('你好。', [
          _noCreation,
          {'type': 'lookup.intent', 'mode': 'clarify', 'question': '哪个城市？'},
        ]);
        await result.timeout(_deadline);
        expect(f.client.requests, 1);
        expect(
          f.client.aggregateRequests,
          1,
          reason:
              'Generic metadata ordering keeps its pre-existing repair path.',
        );
        expect(
          f.emotions.where((e) => e.semanticLabel == 'surprised'),
          isEmpty,
        );
      } finally {
        await f.close();
      }
    },
  );

  for (final aggregate in [false, true]) {
    for (final typedEvent in [false, true]) {
      test(
        'actual thin-proxy SSE ${aggregate ? 'aggregate' : 'reply-prefix'} ${typedEvent ? 'with typed mirror' : 'raw deltas only'} carries a verified face once',
        () async {
          // The real TTS lifecycle looks at the user during speaking and stop.
          // Aggregate responses cannot pause before metadata, so use an exact
          // same-text, no-face control to isolate any added presentation calls.
          List<String>? controlBody;
          List<String>? controlGaze;
          if (aggregate) {
            final control = await _Fixture.create(
              typed: true,
              shipping: true,
              proxyTransport: true,
            );
            try {
              final result = control.runtime.chat('请表现惊讶。', const <Message>[]);
              await control.waitForRequest();
              control.client.delta(
                jsonEncode({
                  'actions': [_noCreation],
                  'reply': '真意外。',
                }),
              );
              control.client.finish();
              expect((await result.timeout(_deadline)).isSuccess, isTrue);
              await control.waitForSpeechSettled();
              await _flush();
              expect(control.client.requests, 1);
              expect(control.client.aggregateRequests, 0);
              expect(
                control.emotions.where((e) => e.semanticLabel == 'surprised'),
                isEmpty,
              );
              controlBody = List.of(control.avatar.bodyCalls);
              controlGaze = List.of(control.avatar.gazeCalls);
            } finally {
              await control.close();
            }
          }
          final f = await _Fixture.create(
            typed: true,
            shipping: true,
            proxyTransport: true,
          );
          final proxy = f.client as _ProxyClient;
          final deltas = <String>[];
          final spoken = <String>[];
          final textSub = f.runtime.onLocalReplyDelta.listen(deltas.add);
          final voiceSub = EventBus().on<AgentSpeechQueuedEvent>().listen(
            (e) => spoken.add(e.text),
          );
          try {
            final result = f.runtime.chat('请表现惊讶。', const <Message>[]);
            await f.waitForRequest();
            final face = _unit(
              '真意外。',
              body: {
                'mood': 'surprised',
                'gesture': 'none',
                'intensity': .8,
                'persistent': false,
              },
            );
            late final List<String> beforeBody;
            late final List<String> beforeGaze;
            if (aggregate) {
              beforeBody = controlBody!;
              beforeGaze = controlGaze!;
              proxy.delta(
                jsonEncode({
                  'actions': [face, _noCreation],
                  'reply': '真意外。',
                }),
              );
            } else {
              await f.primeReply('真意外。');
              expect(deltas.join(), '真意外。');
              beforeBody = List.of(f.avatar.bodyCalls);
              beforeGaze = List.of(f.avatar.gazeCalls);
              expect(
                f.emotions.where((e) => e.semanticLabel == 'surprised'),
                isEmpty,
              );
              proxy.delta(
                ',"actions":[${jsonEncode(face)},${jsonEncode(_noCreation)}]}',
              );
            }
            if (typedEvent) proxy.typed(face);
            proxy.finish();
            expect((await result.timeout(_deadline)).isSuccess, isTrue);
            await f.waitForSpeechSettled();
            await _flush();
            expect(
              proxy.sentBody!['streamProtocol'],
              'maaso.sse.v2.presentation',
            );
            expect(deltas.join(), '真意外。');
            expect(spoken, ['真意外。']);
            expect(
              f.emotions.where((e) => e.semanticLabel == 'surprised'),
              hasLength(1),
            );
            expect(f.avatar.expressions.any((p) => p.surprised > .7), isTrue);
            expect(f.avatar.bodyCalls, orderedEquals(beforeBody));
            expect(f.avatar.gazeCalls, orderedEquals(beforeGaze));
            expect(proxy.requests, 1);
            expect(proxy.aggregateRequests, 0);
          } finally {
            await textSub.cancel();
            await voiceSub.cancel();
            await f.close();
          }
        },
      );
    }
  }
}

const _deadline = Duration(seconds: 5);
const _noCreation = <String, Object?>{
  'type': 'creation.intent',
  'mode': 'none',
};
Map<String, Object?> _unit(
  String text, {
  String after = 'finish',
  Map<String, Object?>? body,
}) => {'type': 'reply.utterance', 'text': text, 'after': after, 'body': ?body};

Future<void> _flush() => Future<void>.delayed(Duration.zero);
Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(_deadline);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('local fixture');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

class _Fixture {
  _Fixture(
    this.database,
    this.client,
    this.avatar,
    this.runtime,
    this.subscription,
  );
  final DBService database;
  final _Client client;
  final _Avatar avatar;
  final AgentRuntime runtime;
  final StreamSubscription<EmotionStateEvent> subscription;
  final messages = <ChatMessage>[];
  late final List<EmotionStateEvent> emotions;

  static Future<_Fixture> create({
    required bool typed,
    Locale? locale,
    bool shipping = false,
    bool proxyTransport = false,
  }) async {
    await appServices.reset();
    AppLocalization.updateLocale(locale ?? const Locale('zh', 'CN'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          return switch (call.method) {
            'getLanguages' => <String>['zh-CN', 'en-US'],
            'getVoices' => <Object>[],
            'getCurrentPosition' => 0,
            _ => 1,
          };
        });
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'conversation-emotion-${DateTime.now().microsecondsSinceEpoch}',
    );
    appServices.put(AgentTaskJobStore());
    appServices.put<DBService>(db);
    appServices.put(ShortTermMemory());
    final avatar = _Avatar();
    appServices.put(ActiveAvatarRuntime()..register(avatar));
    final client = proxyTransport
        ? _ProxyClient()
        : typed
        ? _TypedClient()
        : _Client();
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Audit',
        avatar: '',
        bio: 'test',
        personalityTraits: const ['warm'],
        catchphrase: 'ok',
      ),
      llmClient: client,
      conversationDeliveryMode: shipping
          ? ConversationDeliveryMode.legacy
          : ConversationDeliveryMode.text,
      semanticCreationEnabled: shipping,
      prepareTtsForNewTurn: (_) async {},
    );
    final emotions = <EmotionStateEvent>[];
    final subscription = EventBus().on<EmotionStateEvent>().listen(
      emotions.add,
    );
    await runtime.init(enabledSkillIds: const {});
    avatar.expressions.clear();
    return _Fixture(db, client, avatar, runtime, subscription)
      ..emotions = emotions;
  }

  ConversationTurnHandle submit(String text) => runtime.submitConversation(
    text,
    database: database,
    onMessage: messages.add,
  );
  Future<void> waitForRequest() => _waitUntil(() => client.requests == 1);
  Future<void> waitForSpeechSettled() => _waitUntil(
    () => avatar.phases.contains('speaking') && avatar.phases.last == 'stopped',
  );
  Future<void> primeReply(String text) async {
    avatar.phases.clear();
    client.delta('{"reply":${jsonEncode(text)}');
    await waitForSpeechSettled();
    await _flush();
  }

  Future<void> close() async {
    client.closeTransport();
    await runtime.retireAndDrain().timeout(_deadline);
    await subscription.cancel();
    await database.close();
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  }
}

class _Client extends LLMClient {
  var events = StreamController<LLMStreamEvent>();
  final messages = <List<Message>>[];
  int requests = 0;
  int aggregateRequests = 0;
  String? repairReply;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    aggregateRequests++;
    if (repairReply != null) return Future.value(repairReply);
    throw StateError('No aggregate or extra model request is allowed');
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) {
    aggregateRequests++;
    throw StateError('No extra classifier/repair request is allowed');
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> input, {
    Duration? timeout,
  }) {
    if (requests > 0) events = StreamController<LLMStreamEvent>();
    requests++;
    messages.add(List.of(input));
    return events.stream;
  }

  void respond(List<Map<String, Object?>> actions) {
    final raw = jsonEncode({
      'actions': actions,
      'reply': actions.map((action) => action['text']).join(),
    });
    events.add(
      LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': raw})),
    );
    if (this is _TypedClient) {
      for (final action in actions) {
        events.add(
          LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action)),
        );
      }
    }
    finish();
  }

  void delta(String raw) => events.add(
    LLMStreamEvent(event: 'reply.delta', data: jsonEncode({'delta': raw})),
  );

  void respondReplyFirst(String reply, List<Map<String, Object?>> actions) {
    delta(jsonEncode({'reply': reply, 'actions': actions}));
    if (this is _TypedClient) {
      for (final action in actions.where(
        (action) => action['type'] == 'reply.utterance',
      )) {
        events.add(
          LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action)),
        );
      }
    }
    finish();
  }

  void finishReplyFirstMetadata(List<Map<String, Object?>> actions) {
    delta(',"actions":${jsonEncode(actions)}}');
    if (this is _TypedClient) {
      for (final action in actions.where(
        (action) => action['type'] == 'reply.utterance',
      )) {
        events.add(
          LLMStreamEvent(event: 'reply.utterance', data: jsonEncode(action)),
        );
      }
    }
    finish();
  }

  void finish() {
    events.add(const LLMStreamEvent(event: 'done', data: '[DONE]'));
    unawaited(events.close());
  }

  void closeTransport() {
    if (!events.isClosed) unawaited(events.close());
  }
}

/// Parses the actual application SSE client against an in-memory HTTP body.
/// No socket, provider, API key or model is contacted by this fixture.
class _ProxyClient extends _Client implements PresentationStreamingLLMClient {
  final wire = StreamController<List<int>>();
  Map<String, dynamic>? sentBody;
  late final MaasoThinProxyLLMClient proxy = MaasoThinProxyLLMClient(
    baseUri: Uri.parse('https://example.test'),
    model: 'local-fixture',
    accessTokenProvider: () async => null,
    httpClient: _SseHttpClient((request) {
      sentBody = jsonDecode(request.body) as Map<String, dynamic>;
      return wire.stream;
    }),
  );
  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> input, {
    Duration? timeout,
  }) {
    requests++;
    messages.add(List.of(input));
    return proxy.streamPresentationChatEvents(input, timeout: timeout);
  }

  @override
  void delta(String raw) => wire.add(
    utf8.encode('event: reply.delta\ndata: ${jsonEncode({'delta': raw})}\n\n'),
  );
  void typed(Map<String, Object?> action) => wire.add(
    utf8.encode('event: reply.utterance\ndata: ${jsonEncode(action)}\n\n'),
  );
  @override
  void finish() {
    wire.add(utf8.encode('event: done\ndata: [DONE]\n\n'));
    unawaited(wire.close());
  }

  @override
  void closeTransport() {
    super.closeTransport();
    if (!wire.isClosed) unawaited(wire.close());
    proxy.close();
  }
}

class _SseHttpClient extends http.BaseClient {
  _SseHttpClient(this.response);
  final Stream<List<int>> Function(http.Request) response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        response(request as http.Request),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
}

class _TypedClient extends _Client implements PresentationStreamingLLMClient {
  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => streamChatEvents(messages, timeout: timeout);
}

class _Avatar extends AvatarRuntime implements AvatarConversationPhaseRuntime {
  final expressions = <AvatarExpressionParams>[];
  final bodyCalls = <String>[];
  final gazeCalls = <String>[];
  final phases = <String>[];
  @override
  final isReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {
    expressions.add(params);
  }

  @override
  Future<void> setConversationPhase(
    String phase, {
    required int sequence,
  }) async {
    phases.add(phase);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) {
      if (const {#setGaze, #clearGaze}.contains(invocation.memberName)) {
        gazeCalls.add(invocation.memberName.toString());
      }
      if (const {
        #playPrimitive,
        #playAnimationClip,
        #playMotion,
        #playMotionSequence,
        #setBodyPose,
      }.contains(invocation.memberName)) {
        bodyCalls.add(invocation.memberName.toString());
      }
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
