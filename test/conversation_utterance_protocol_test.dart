import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';

void main() {
  const decoder = ConversationReplyDecoder();

  group('conversation reply protocol', () {
    test(
      'semantic bubbles preserve multiple sentences and very short replies',
      () {
        for (final text in [
          '今天先休息。明天再看也来得及。你不用现在决定。',
          '嗯',
          '嘿嘿',
          '喵~',
          'Oh!',
        ]) {
          final result = decoder.decodeEnvelope(_envelope([_utterance(text)]));
          expect(result.utterances, hasLength(1));
          expect(result.utterances.single.text, text);
          expect(result.utterances.single.after, ConversationAfter.finish);
        }
      },
    );

    test('ordinary text stays one utterance without punctuation splitting', () {
      const text = '今天呀，嗯，我想想。猪脚饭？\n或者看看你想吃什么。';
      final result = decoder.decode(text);
      expect(result.usesUtteranceProtocol, isFalse);
      expect(result.reply, text);
      expect(result.utterances, hasLength(1));
      expect(result.utterances.single.text, text);
      expect(result.utterances.single.after, ConversationAfter.finish);
      expect(result.utterances.single.pause, isNull);
      expect(result.utterances.single.body, isNull);
    });

    test('legacy reply and empty actions adapt to a single utterance', () {
      final result = decoder.decode('{"reply":"  可以呀。  ","actions":[]}');
      expect(result.usesUtteranceProtocol, isFalse);
      expect(result.reply, '可以呀。');
      expect(result.utterances.single.text, '可以呀。');
    });

    test('literal script names and fences inside JSON remain reply data', () {
      for (final text in [
        '这个角色叫 Dr.Claw.，只是文字。',
        '示例：\n```javascript\nconst score = 0;\n```',
        '字面代码示例 Claw.voice.speak("示例"); 不是宿主调用。',
      ]) {
        final result = decoder.decode(
          jsonEncode({'reply': text, 'actions': []}),
        );
        expect(result.reply, text);
        expect(result.utterances.single.text, text);
        expect(result.usesUtteranceProtocol, isFalse);
      }
    });

    test(
      'raw JSON and typed utterances admit identical literal marker data',
      () {
        const text = 'Dr.Claw.\n```javascript\nconst label = "sample";\n```';
        final envelope = {
          'reply': text,
          'actions': [_utterance(text)],
        };
        final raw = decoder.decode(jsonEncode(envelope));
        final typed = decoder.decodeEnvelope(envelope);
        expect(raw.reply, typed.reply);
        expect(raw.utterances.single.text, typed.utterances.single.text);
        expect(raw.usesUtteranceProtocol, isTrue);
      },
    );

    test('literal markers cannot grant non-presentation action authority', () {
      expect(
        () => decoder.decode(
          jsonEncode({
            'reply': 'Dr.Claw. ```javascript```',
            'actions': [
              _utterance('数据文字。'),
              {'type': 'skill.call', 'skill': 'unsafe'},
            ],
          }),
        ),
        _throwsCode('non_utterance_action'),
      );
      expect(
        () => decoder.decode(
          jsonEncode(
            _envelope([
              {
                ..._utterance('普通文字。'),
                'body': {'mood': 'Claw.```'},
              },
            ]),
          ),
        ),
        _throwsCode('invalid_body_token'),
      );
    });

    test('sideband remains forbidden in decoded and fallback text', () {
      for (final text in [
        '<body_intent>{"mood":"calm"}</body_intent>',
        '<task_handoff job="private">',
      ]) {
        expect(() => decoder.decode(text), _throwsCode('sideband_response'));
        expect(
          () => decoder.decode(jsonEncode({'reply': text, 'actions': []})),
          _throwsCode('sideband_response'),
        );
        expect(
          () => decoder.decode(
            jsonEncode({
              'reply': '',
              'actions': [_utterance(text)],
            }),
          ),
          _throwsCode('sideband_response'),
        );
      }
    });

    test('outer scripts and fences still cannot enter the text fallback', () {
      for (final text in [
        'Claw.voice.speak("控制");',
        '文字中的 Claw. 仍不允许作为非协议fallback。',
        '```javascript\nClaw.voice.speak("控制");\n```',
        '```json\n{"reply":"答复","actions":[]}\n```',
        '{"reply":"答复","actions":[]} Claw.voice.speak("控制");',
        'Claw.voice.speak("控制"); {"reply":"答复","actions":[]}',
      ]) {
        expect(
          () => decoder.decode(text),
          _throwsCode('wrapped_or_script_response'),
        );
      }
    });

    test('three semantic segments keep pauses and unexecuted body data', () {
      final result = decoder.decode(jsonEncode(_threePartEnvelope()));
      expect(result.usesUtteranceProtocol, isTrue);
      expect(result.utterances.map((part) => part.text), [
        '今天呀，嗯，我想想。',
        '猪脚饭？',
        '或者看你想吃啥，我都行。',
      ]);
      expect(result.utterances.map((part) => part.after), [
        ConversationAfter.continueReply,
        ConversationAfter.optional,
        ConversationAfter.finish,
      ]);
      expect(result.utterances.map((part) => part.pause), [
        ConversationPause.brief,
        ConversationPause.invite,
        null,
      ]);
      expect(result.utterances.first.body, {
        'mood': 'thinking',
        'gaze': 'away',
      });
      // The compatibility aggregate is not appended as a fourth utterance.
      expect(result.utterances, hasLength(3));
    });

    test('new protocol can also choose one complete reply or yield', () {
      for (final after in ['finish', 'yield']) {
        final result = decoder.decodeEnvelope(
          _envelope([_utterance('你想吃什么？', after: after)]),
        );
        expect(result.usesUtteranceProtocol, isTrue);
        expect(result.utterances, hasLength(1));
        expect(result.utterances.single.after.endsReply, isTrue);
        expect(result.utterances.single.after.wireValue, after);
      }
    });

    test('new protocol may have an empty compatibility aggregate', () {
      final result = decoder.decodeEnvelope({
        'reply': '',
        'actions': [_utterance('只发布这段。')],
      });
      expect(result.reply, isEmpty);
      expect(result.utterances.single.text, '只发布这段。');
    });

    test('typed envelopes and raw complete JSON use identical validation', () {
      final envelope = _threePartEnvelope();
      final raw = decoder.decode(jsonEncode(envelope));
      final typed = decoder.decodeEnvelope(envelope);
      expect(typed.reply, raw.reply);
      expect(
        typed.utterances.map((part) => part.text),
        raw.utterances.map((part) => part.text),
      );
      expect(
        typed.utterances.map((part) => part.after),
        raw.utterances.map((part) => part.after),
      );
    });

    test(
      'any other action rejects the whole mixed response in either order',
      () {
        for (final type in [
          'voice.speak',
          'emotion.set',
          'avatar.act',
          'avatar.motion',
          'skill.call',
          'world.intent',
          'unknown.action',
        ]) {
          final other = <String, Object?>{'type': type};
          for (final actions in [
            [_utterance('不能先发布这一句。'), other],
            [other, _utterance('不能绕过其它动作。')],
          ]) {
            expect(
              () => decoder.decodeEnvelope(_envelope(actions)),
              _throwsCode('non_utterance_action'),
            );
          }
        }
      },
    );

    test('legacy non-presentation actions are not silently stripped', () {
      expect(
        () =>
            decoder.decode('{"reply":"收到。","actions":[{"type":"skill.call"}]}'),
        _throwsCode('non_utterance_action'),
      );
    });

    test('more than three utterances are rejected rather than truncated', () {
      expect(
        () => decoder.decodeEnvelope(
          _envelope([
            _utterance('一。', after: 'continue'),
            _utterance('二。', after: 'continue'),
            _utterance('三。', after: 'continue'),
            _utterance('四。'),
          ]),
        ),
        _throwsCode('too_many_utterances'),
      );
    });

    test('finish and yield cannot hide later unpublished actions', () {
      for (final after in ['finish', 'yield']) {
        expect(
          () => decoder.decodeEnvelope(
            _envelope([
              _utterance('到此结束。', after: after),
              _utterance('不可达的后续。'),
            ]),
          ),
          _throwsCode('utterance_after_terminal'),
        );
      }
    });

    test('continue and optional require an already supplied continuation', () {
      for (final after in ['continue', 'optional']) {
        expect(
          () => decoder.decodeEnvelope(
            _envelope([_utterance('不发起第二次模型调用。', after: after)]),
          ),
          _throwsCode('missing_continuation'),
        );
      }
    });

    test('optional allows only one final supplement', () {
      expect(
        () => decoder.decodeEnvelope(
          _envelope([
            _utterance('可选窗口。', after: 'optional'),
            _utterance('补充一。', after: 'continue'),
            _utterance('补充二。'),
          ]),
        ),
        _throwsCode('optional_must_precede_final_utterance'),
      );
    });

    test('after and pause admit only the declared semantic values', () {
      for (final after in [null, 12, {}, 'Continue', 'later']) {
        expect(
          () => decoder.decodeEnvelope(
            _envelope([
              {..._utterance('答复。'), 'after': after},
            ]),
          ),
          _throwsCode('invalid_after'),
        );
      }
      for (final pause in [null, 1200, {}, 'long', 'forever']) {
        expect(
          () => decoder.decodeEnvelope(
            _envelope([
              {..._utterance('答复。'), 'pause': pause},
            ]),
          ),
          _throwsCode('invalid_pause'),
        );
      }
    });

    test('malformed JSON and wrapped control objects never become text', () {
      for (final raw in [
        '{"reply":"一。","actions":[',
        '{reply:"一。",actions:[]}',
        '前面文字 {reply:"一。",actions:[]} 后面文字',
        '前面文字 {"reply":"一。","actions":[]} 后面文字',
        '```json\n{"reply":"一。","actions":[]}\n```',
        '{"reply":"一。","actions":[]} trailing',
        '"unterminated JSON string',
        'prefix {"arbitrary":"object"} suffix',
        'Claw.voice.speak("控制代码");',
      ]) {
        expect(
          () => decoder.decode(raw),
          throwsA(isA<ConversationReplyProtocolException>()),
        );
      }
    });

    test('JSON strings arrays and primitives are never displayed as text', () {
      for (final raw in ['"你好。"', '[]', 'null', 'true', '42']) {
        expect(() => decoder.decode(raw), _throwsCode('top_level_not_object'));
      }
    });

    test('bad envelope shapes and empty fallback replies are rejected', () {
      final cases = <(Map<String, Object?>, String)>[
        ({'reply': '答复。'}, 'actions_not_list'),
        ({'reply': '答复。', 'actions': null}, 'actions_not_list'),
        ({'reply': 42, 'actions': []}, 'reply_not_string'),
        ({'reply': {}, 'actions': []}, 'reply_not_string'),
        ({'actions': []}, 'reply_not_string'),
        ({'reply': ' ', 'actions': []}, 'empty_reply'),
        (
          {
            'reply': '答复。',
            'actions': [null],
          },
          'action_not_object',
        ),
        (
          {
            'reply': '答复。',
            'actions': ['visible?'],
          },
          'action_not_object',
        ),
      ];
      for (final (envelope, code) in cases) {
        expect(() => decoder.decodeEnvelope(envelope), _throwsCode(code));
      }
      expect(() => decoder.decode('  '), _throwsCode('empty_response'));
    });

    test('utterance text must be a nonempty string', () {
      for (final text in [null, '', '  ', 1, {}, []]) {
        expect(
          () => decoder.decodeEnvelope(
            _envelope([
              {..._utterance('答复。'), 'text': text},
            ]),
          ),
          _throwsCode('invalid_utterance_text'),
        );
      }
    });

    test('model identity timing scope and nested actions are not accepted', () {
      for (final field in [
        'turnId',
        'utteranceId',
        'sequence',
        'delayMs',
        'pauseMs',
        'scope',
        'actions',
      ]) {
        expect(
          () => decoder.decodeEnvelope(
            _envelope([
              {..._utterance('答复。'), field: 'model-owned'},
            ]),
          ),
          _throwsCode('unknown_utterance_field'),
        );
      }
      expect(
        () => decoder.decodeEnvelope({
          ..._envelope([_utterance('答复。')]),
          'turnId': 'model-owned',
        }),
        _throwsCode('unknown_envelope_field'),
      );
    });

    test(
      'body preserves explicit none and emitMood false without defaults',
      () {
        final omitted = decoder
            .decodeEnvelope(
              _envelope([
                {
                  ..._utterance('我想想。'),
                  'body': {'mood': 'thinking'},
                },
              ]),
            )
            .utterances
            .single
            .body!;
        final explicit = decoder
            .decodeEnvelope(
              _envelope([
                {
                  ..._utterance('我想想。'),
                  'body': {
                    'mood': 'thinking',
                    'gesture': 'none',
                    'emitMood': false,
                    'intensity': 0.45,
                    'durationMs': 1200,
                  },
                },
              ]),
            )
            .utterances
            .single
            .body!;
        expect(omitted.containsKey('gesture'), isFalse);
        expect(omitted.containsKey('emitMood'), isFalse);
        expect(explicit['gesture'], 'none');
        expect(explicit['emitMood'], isFalse);
        expect(explicit['intensity'], 0.45);
        expect(explicit['durationMs'], 1200);
      },
    );

    test(
      'body cannot contain raw bones mouth curves tools or extra authority',
      () {
        for (final field in [
          'bones',
          'blendshapes',
          'mouth',
          'clip',
          'motion',
          'type',
          'agentId',
          'owner',
          'actions',
        ]) {
          expect(
            () => decoder.decodeEnvelope(
              _envelope([
                {
                  ..._utterance('答复。'),
                  'body': {'mood': 'calm', field: 'not admitted'},
                },
              ]),
            ),
            _throwsCode('unknown_body_field'),
          );
        }
      },
    );

    test('raw and typed bodies preserve the documented persistent bool', () {
      for (final persistent in [false, true]) {
        final envelope = _envelope([
          {
            ..._utterance('我会保持这个表情。'),
            'body': {
              'mood': 'surprised',
              'gesture': 'none',
              'persistent': persistent,
            },
          },
        ]);
        for (final reply in [
          decoder.decode(jsonEncode(envelope)),
          decoder.decodeEnvelope(envelope),
        ]) {
          expect(reply.utterances.single.body!['persistent'], persistent);
        }
      }
    });

    test(
      'body shape finite intensity and existing act duration are bounded',
      () {
        final cases = <(Object?, String)>[
          (null, 'invalid_body'),
          ([], 'invalid_body'),
          ({}, 'invalid_body'),
          ({'intensity': 0.5}, 'invalid_body'),
          ({'mood': {}}, 'invalid_body_token'),
          ({'mood': 'calm; execute()'}, 'invalid_body_token'),
          ({'mood': 'calm', 'intensity': double.nan}, 'invalid_body_intensity'),
          (
            {'mood': 'calm', 'intensity': double.infinity},
            'invalid_body_intensity',
          ),
          ({'mood': 'calm', 'intensity': -0.1}, 'invalid_body_intensity'),
          ({'mood': 'calm', 'intensity': 1.1}, 'invalid_body_intensity'),
          ({'mood': 'calm', 'durationMs': 349}, 'invalid_body_duration'),
          ({'mood': 'calm', 'durationMs': 5001}, 'invalid_body_duration'),
          ({'mood': 'calm', 'durationMs': 1200.5}, 'invalid_body_duration'),
          ({'mood': 'calm', 'emitMood': 'false'}, 'invalid_body_emit_mood'),
          ({'mood': 'calm', 'persistent': 'false'}, 'invalid_body_persistent'),
          ({'mood': 'calm', 'persistent': 1}, 'invalid_body_persistent'),
          ({'mood': 'calm', 'persistent': null}, 'invalid_body_persistent'),
        ];
        for (final (body, code) in cases) {
          expect(
            () => decoder.decodeEnvelope(
              _envelope([
                {..._utterance('答复。'), 'body': body},
              ]),
            ),
            _throwsCode(code),
          );
        }
      },
    );

    test('decoder defensively copies model lists and maps', () {
      final body = <String, Object?>{'mood': 'calm'};
      final actions = <Map<String, Object?>>[
        {..._utterance('原始发言。'), 'body': body},
      ];
      final result = decoder.decodeEnvelope(_envelope(actions));
      body['mood'] = 'angry';
      actions.first['text'] = '替换文本。';
      actions.clear();
      expect(result.utterances.single.text, '原始发言。');
      expect(result.utterances.single.body, {'mood': 'calm'});
      expect(() => result.utterances.clear(), throwsUnsupportedError);
      expect(
        () => result.utterances.single.body!['mood'] = 'happy',
        throwsUnsupportedError,
      );
    });

    test('draft body is deeply immutable even before protocol validation', () {
      final values = <Object?>['original'];
      final nested = <String, Object?>{'values': values};
      final draft = ConversationUtteranceDraft(
        text: '宿主数据。',
        body: {'nested': nested},
      );
      values.add('later');
      nested['changed'] = true;
      final frozen = draft.body!['nested'] as Map<String, Object?>;
      expect(frozen, {
        'values': ['original'],
      });
      expect(() => frozen['changed'] = true, throwsUnsupportedError);
      expect(() => (frozen['values'] as List).clear(), throwsUnsupportedError);
    });

    test('errors never include response contents', () {
      try {
        decoder.decode('{"private-response":"do not log me"');
        fail('Expected protocol rejection');
      } on ConversationReplyProtocolException catch (error) {
        expect(error.code, 'invalid_json');
        expect(error.toString(), isNot(contains('do not log me')));
        expect(error.toString(), isNot(contains('private-response')));
      }
    });
  });
}

Map<String, Object?> _envelope(List<Object?> actions) => {
  'reply': '兼容聚合，不额外发布。',
  'actions': actions,
};

Map<String, Object?> _utterance(String text, {String after = 'finish'}) => {
  'type': 'reply.utterance',
  'text': text,
  'after': after,
};

Map<String, Object?> _threePartEnvelope() => {
  'reply': '今天呀，嗯，我想想。猪脚饭？或者看你想吃啥，我都行。',
  'actions': [
    {
      ..._utterance('今天呀，嗯，我想想。', after: 'continue'),
      'pause': 'brief',
      'body': {'mood': 'thinking', 'gaze': 'away'},
    },
    {..._utterance('猪脚饭？', after: 'optional'), 'pause': 'invite'},
    _utterance('或者看你想吃啥，我都行。'),
  ],
};

Matcher _throwsCode(String code) => throwsA(
  isA<ConversationReplyProtocolException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);
