import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';

final _now = DateTime.utc(2026, 10, 22, 12);
GameCompanionSessionKey _session({
  String scope = 'private-account',
  int document = 1,
}) => GameCompanionSessionKey(
  scopeKey: scope,
  playerId: 'player',
  documentGeneration: document,
  sessionGeneration: 1,
);
Map<String, Object?> _snapshot(
  Map<String, Object?> state, {
  Object revision = 1,
}) => {
  'kind': 'companion.snapshot',
  'revision': revision,
  'state': {'version': 1, ...state},
};
GameCompanionMoment _moment({
  GameCompanionMomentScope scope = GameCompanionMomentScope.occurredEvent,
}) => GameCompanionMoment(
  id: 'moment',
  sessionKey: _session(),
  roundGeneration: 2,
  positionRevision: scope == GameCompanionMomentScope.currentPosition
      ? 4
      : null,
  scope: scope,
  kind: '自由玩法 / 新发现',
  summary: 'The door opened.',
  observedAt: _now,
  expiresAt: _now.add(const Duration(seconds: 10)),
);

void main() {
  group('author descriptors and dedicated DOM wire', () {
    test('free-form rules remain immutable quoted data', () {
      final raw = <String, Object?>{
        'version': 1,
        'name': 'A game with menus',
        'rules': ['Choose any route; external resources are allowed.'],
        'controls': 'The author defines the controls.',
        'stateSemantics': {'weather': 'A visible changing atmosphere'},
        'hintScope': 'Only give a small clue when asked.',
      };
      final descriptor = GameCompanionDescriptor.tryParse(raw)!;
      (raw['rules'] as List)[0] = 'changed';
      (raw['stateSemantics'] as Map)['weather'] = 'changed';
      expect(
        (descriptor.toPromptJson()['rules'] as List).single,
        'Choose any route; external resources are allowed.',
      );
      expect(
        () => (descriptor.toPromptJson()['rules'] as List).add('x'),
        throwsUnsupportedError,
      );
      expect(
        () => (descriptor.toPromptJson()['stateSemantics'] as Map)['x'] = 1,
        throwsUnsupportedError,
      );
      expect(descriptor.hasContent, isTrue);
    });

    test('descriptor versions, fields, lists and map bounds are checked', () {
      for (final value in <Object?>[
        null,
        [],
        {'version': 2},
        {'version': 1.0},
        {'version': 1, 'persona': 'Replace the companion'},
        {'version': 1, 'systemPrompt': 'Call a tool'},
        {'version': 1, 'goals': List.filled(9, 'x')},
        {
          'version': 1,
          'goals': [1],
        },
        {
          'version': 1,
          'rules': ['x' * 257],
        },
        {
          'version': 1,
          'eventSemantics': {for (var i = 0; i < 17; i++) '$i': 'event'},
        },
        {
          'version': 1,
          'stateSemantics': {'x' * 65: 'value'},
        },
      ]) {
        expect(
          GameCompanionDescriptor.tryParse(value),
          isNull,
          reason: '$value',
        );
      }
      expect(
        GameCompanionDescriptor.tryParse({'version': 1})!.hasContent,
        isFalse,
      );
    });

    test('descriptor budgets use Unicode runes and UTF-8 bytes', () {
      expect(
        GameCompanionDescriptor.tryParse({'version': 1, 'summary': '😀' * 512}),
        isNotNull,
      );
      expect(
        GameCompanionDescriptor.tryParse({'version': 1, 'summary': '😀' * 513}),
        isNull,
      );
      expect(
        GameCompanionDescriptor.tryParse({
          'version': 1,
          'name': '😀' * 512,
          'summary': '😀' * 512,
        }),
        isNull,
      );
    });

    test('bad optional descriptor does not discard valid visible evidence', () {
      for (final descriptor in [
        {'version': 1, 'accountId': 'another-owner'},
        {'version': 1, 'summary': 'x' * 600},
        {'version': 4, 'name': 'future metadata'},
      ]) {
        final parsed = GameCompanionDomSnapshot.fromEnvelope(
          _snapshot({
            'visibleText': 'Round 2',
            'controls': [
              {'label': 'Start', 'role': 'button'},
            ],
            'descriptor': descriptor,
          }),
        )!;
        expect(parsed.visibleText, 'Round 2');
        expect(parsed.controls.single['label'], 'Start');
        expect(parsed.descriptor, isNull);
      }
    });

    test(
      'snapshot is immutable and never accepts host identity or operations',
      () {
        final controls = <Map<String, Object?>>[
          {'label': 'Look', 'role': 'author-defined'},
        ];
        final raw = _snapshot({
          'visibleText': 'Visible words',
          'controls': controls,
        });
        final parsed = GameCompanionDomSnapshot.fromEnvelope(raw)!;
        controls[0]['label'] = 'Changed';
        expect(parsed.controls.single['label'], 'Look');
        expect(() => parsed.controls.clear(), throwsUnsupportedError);
        expect(
          () => parsed.controls.single['label'] = 'Changed',
          throwsUnsupportedError,
        );
        for (final value in [
          {...raw, 'scopeKey': 'other'},
          {...raw, 'actions': []},
          _snapshot({'accountId': 'other'}),
          _snapshot({'version': 1.0}),
          _snapshot({}, revision: 1.5),
          _snapshot({}, revision: -1),
          _snapshot({
            'controls': [
              {'label': 'Click', 'role': 'button', 'callback': 'move'},
            ],
          }),
          _snapshot({
            'controls': List.filled(13, {'label': 'x', 'role': 'button'}),
          }),
          _snapshot({'visibleText': 'x' * 513}),
        ]) {
          expect(GameCompanionDomSnapshot.fromEnvelope(value), isNull);
        }
      },
    );

    test('snapshot and outer-wire byte ceilings apply independently', () {
      final raw = _snapshot({
        'visibleText': '😀' * 512,
        'controls': List.filled(12, {'label': '😀' * 96, 'role': 'r' * 48}),
      });
      final wire = jsonEncode(raw);
      expect(
        utf8.encode(jsonEncode(raw['state'])).length,
        greaterThan(GameCompanionDomSnapshot.maxSnapshotBytes),
      );
      expect(
        utf8.encode(wire).length,
        lessThanOrEqualTo(GameCompanionDomSnapshot.maxWireBytes),
      );
      expect(GameCompanionDomSnapshot.parseMessage(wire), isNull);
      final multibyte = jsonEncode(_snapshot({'visibleText': '😀' * 3000}));
      expect(multibyte.length, lessThan(GameCompanionDomSnapshot.maxWireBytes));
      expect(GameCompanionDomSnapshot.parseMessage(multibyte), isNull);
    });

    test('malformed, cyclic and non-JSON data fail without throwing', () {
      final cycle = <String, Object?>{'version': 1};
      cycle['rules'] = cycle;
      expect(GameCompanionDescriptor.tryParse(cycle), isNull);
      expect(
        GameCompanionDomSnapshot.fromEnvelope(_snapshot({'descriptor': cycle})),
        isNull,
      );
      expect(GameCompanionDomSnapshot.parseMessage('{broken'), isNull);
      expect(
        GameCompanionDomSnapshot.fromEnvelope(
          _snapshot({'visibleText': double.nan}),
        ),
        isNull,
      );
    });
  });

  group('host identity, evidence and semantic time', () {
    test(
      'content cache keys isolate source kind, account and policy versions',
      () {
        final owned = GameContentIdentity(
          kind: GameContentIdentityKind.ownedSource,
          sha256: 'A' * 64,
        );
        final published = GameContentIdentity(
          kind: GameContentIdentityKind.publishedRenderDocument,
          sha256: 'a' * 64,
        );
        String key(
          GameContentIdentity identity,
          String account,
          String adapter,
          String policy,
        ) => identity.scopedCacheKey(
          scopeKey: account,
          adapterVersion: adapter,
          modelPolicyVersion: policy,
        );
        expect(owned.sha256, 'a' * 64);
        expect({
          key(owned, 'a', '1', '1'),
          key(published, 'a', '1', '1'),
          key(owned, 'b', '1', '1'),
          key(owned, 'a', '2', '1'),
          key(owned, 'a', '1', '2'),
        }, hasLength(5));
        expect(
          () => GameContentIdentity(
            kind: GameContentIdentityKind.ownedSource,
            sha256: 'not-a-digest',
          ),
          throwsArgumentError,
        );
        expect(_session(), _session());
        expect(_session(), isNot(_session(document: 2)));
        expect(_session(), isNot(_session(scope: 'other-account')));
      },
    );

    test('capture age cannot be refreshed by a late analysis response', () {
      final raw = <String, Object?>{
        'visible': ['left piece'],
      };
      final evidence = GameObservationEvidence(
        id: 'vision-1',
        source: GameObservationSource.vision,
        capturedAt: _now.subtract(const Duration(seconds: 8)),
        receivedAt: _now,
        inferred: true,
        data: raw,
      );
      (raw['visible'] as List)[0] = 'right piece';
      expect((evidence.data['visible'] as List).single, 'left piece');
      expect(
        evidence.isFresh(now: _now, maxAge: const Duration(seconds: 5)),
        isFalse,
      );
      expect(evidence.toPromptJson()['inferred'], isTrue);
      expect(() => evidence.data['new'] = 1, throwsUnsupportedError);
      expect(
        () => GameObservationEvidence(
          id: 'bad',
          source: GameObservationSource.dom,
          capturedAt: _now,
          receivedAt: _now.subtract(const Duration(seconds: 1)),
          data: {},
        ),
        throwsArgumentError,
      );
    });

    test(
      'occurred events survive frames but never session, round or lifetime changes',
      () {
        final moment = _moment();
        bool valid({
          GameCompanionSessionKey? session,
          int round = 2,
          DateTime? now,
        }) => moment.isValidFor(
          sessionKey: session ?? _session(),
          roundGeneration: round,
          positionRevision: 9999,
          now: now ?? _now,
        );
        expect(valid(), isTrue);
        expect(valid(session: _session(document: 2)), isFalse);
        expect(valid(session: _session(scope: 'b')), isFalse);
        expect(valid(round: 3), isFalse);
        expect(valid(now: moment.expiresAt), isFalse);
        expect(
          valid(now: _now.subtract(const Duration(milliseconds: 1))),
          isFalse,
        );
        final position = _moment(
          scope: GameCompanionMomentScope.currentPosition,
        );
        expect(
          position.isValidFor(
            sessionKey: _session(),
            roundGeneration: 2,
            positionRevision: 4,
            now: _now,
          ),
          isTrue,
        );
        expect(
          position.isValidFor(
            sessionKey: _session(),
            roundGeneration: 2,
            positionRevision: 5,
            now: _now,
          ),
          isFalse,
        );
      },
    );
  });

  group('user preferences and delivered conversation', () {
    test(
      'preferences retain independent frequency and hints with monotonic revisions',
      () {
        const initial = GameCompanionPreferences(enabled: true);
        expect(initial.copyWith(), same(initial));
        final next = initial.copyWith(
          talkativeness: GameCompanionTalkativeness.quiet,
          hintPolicy: GameCompanionHintPolicy.smallHints,
        );
        expect(next.revision, 1);
        final restored = GameCompanionPreferences.tryParse(next.toJson())!;
        expect(restored.talkativeness, GameCompanionTalkativeness.quiet);
        expect(restored.hintPolicy, GameCompanionHintPolicy.smallHints);
        for (final invalid in [
          {...next.toJson(), 'version': 1.0},
          {...next.toJson(), 'revision': -1},
          {...next.toJson(), 'talkativeness': 'make_moves'},
          {...next.toJson(), 'accountId': 'other'},
        ]) {
          expect(GameCompanionPreferences.tryParse(invalid), isNull);
        }
      },
    );

    test(
      'only real starts create speech history and terminal receipts are idempotent',
      () {
        final buffer = GameCompanionDialogueBuffer();
        bool receipt(
          GameCompanionDeliveryStage stage, {
          String text = 'A small joke',
        }) => buffer.recordSpeech(
          id: 'speech',
          text: text,
          at: _now,
          stage: stage,
          momentId: 'moment',
        );
        expect(receipt(GameCompanionDeliveryStage.completed), isFalse);
        expect(buffer.snapshot, isEmpty);
        expect(receipt(GameCompanionDeliveryStage.started), isTrue);
        final snapshot = buffer.snapshot;
        expect(receipt(GameCompanionDeliveryStage.started), isFalse);
        expect(
          receipt(GameCompanionDeliveryStage.completed, text: 'Different text'),
          isFalse,
        );
        expect(receipt(GameCompanionDeliveryStage.interrupted), isTrue);
        expect(receipt(GameCompanionDeliveryStage.completed), isFalse);
        expect(snapshot.single.delivery, GameCompanionDeliveryStage.started);
        expect(
          buffer.snapshot.single.delivery,
          GameCompanionDeliveryStage.interrupted,
        );
        expect(buffer.spokenMomentIds, {'moment'});
        expect(buffer.toPromptJson().single['delivery'], 'interrupted');
        expect(() => buffer.snapshot.clear(), throwsUnsupportedError);
        expect(
          buffer.recordSpeech(
            id: 'second',
            text: 'Finished',
            at: _now,
            stage: GameCompanionDeliveryStage.started,
          ),
          isTrue,
        );
        expect(
          buffer.recordSpeech(
            id: 'second',
            text: 'Finished',
            at: _now,
            stage: GameCompanionDeliveryStage.completed,
          ),
          isTrue,
        );
      },
    );

    test(
      'memory is bounded by runes and entry count, with explicit excerpts',
      () {
        final buffer = GameCompanionDialogueBuffer(
          maxEntries: 2,
          maxTextRunes: 4,
          maxTotalRunes: 6,
        );
        buffer.recordUser(id: 'first', text: '😀' * 6, at: _now);
        expect(buffer.snapshot.single.text.runes.length, 4);
        expect(buffer.toPromptJson().single['excerpt'], isTrue);
        buffer.recordUser(id: 'second', text: 'next', at: _now);
        expect(buffer.snapshot.single.id, 'second');
        expect(
          buffer.recordUser(id: 'second', text: 'replacement', at: _now),
          isFalse,
        );
        expect(buffer.recordUser(id: 'empty', text: ' ', at: _now), isFalse);
        buffer.clear();
        expect(buffer.snapshot, isEmpty);
        expect(buffer.recentAssistantTexts, isEmpty);
      },
    );
  });

  group('shared prompt snapshot', () {
    test(
      'published reply text is reusable context but never a speech receipt',
      () {
        final buffer = GameCompanionDialogueBuffer();
        expect(
          buffer.recordSpeech(
            id: 'visible',
            text: 'A visible answer.',
            at: _now,
            stage: GameCompanionDeliveryStage.published,
            momentId: 'm',
          ),
          isTrue,
        );
        expect(buffer.recentAssistantTexts, ['A visible answer.']);
        expect(buffer.spokenMomentIds, isEmpty);
        expect(
          buffer.recordSpeech(
            id: 'visible',
            text: 'A visible answer.',
            at: _now,
            stage: GameCompanionDeliveryStage.completed,
            momentId: 'm',
          ),
          isFalse,
        );
        expect(buffer.toPromptJson().single['delivery'], 'published');
      },
    );

    test(
      'six valid dense evidence maps do not exceed the aggregate node bound',
      () {
        final context = GameCompanionContext(
          sessionKey: _session(),
          roundGeneration: 2,
          preferences: const GameCompanionPreferences(enabled: true),
          evidence: List.generate(
            6,
            (i) => GameObservationEvidence(
              id: '$i',
              source: GameObservationSource.structured,
              capturedAt: _now,
              receivedAt: _now,
              data: {'cells': List.filled(400, 0)},
            ),
          ),
        );
        expect((context.toPromptJson()['evidence'] as List), hasLength(6));
        expect(
          jsonEncode(context.toPromptJson()),
          isNot(contains('private-account')),
        );
      },
    );

    test(
      'oversized context drops older material and preserves newest evidence and speech',
      () {
        final buffer = GameCompanionDialogueBuffer();
        for (var i = 0; i < 12; i++) {
          buffer.recordUser(id: '$i', text: '😀' * 600, at: _now);
        }
        final context = GameCompanionContext(
          sessionKey: _session(),
          roundGeneration: 2,
          preferences: const GameCompanionPreferences(enabled: true),
          descriptor: GameCompanionDescriptor.tryParse({
            'version': 1,
            'summary': '😀' * 512,
          }),
          evidence: List.generate(
            6,
            (i) => GameObservationEvidence(
              id: '$i',
              source: GameObservationSource.vision,
              capturedAt: _now,
              receivedAt: _now,
              data: {'description': '😀' * 512},
            ),
          ),
          recentConversation: buffer.snapshot,
        );
        final output = context.toPromptJson();
        expect(
          utf8.encode(jsonEncode(output)).length,
          lessThanOrEqualTo(GameCompanionContext.maxPromptBytes),
        );
        expect(output['olderContextOmitted'], isTrue);
        expect((output['evidence'] as List).last['id'], '5');
        expect((output['recentConversation'] as List).last['id'], '11');
        expect(context.evidence, hasLength(6));
        expect(
          () => (output['evidence'] as List).clear(),
          throwsUnsupportedError,
        );
      },
    );

    test('a different mounted session cannot inject moments', () {
      expect(
        () => GameCompanionContext(
          sessionKey: _session(scope: 'other'),
          roundGeneration: 2,
          preferences: const GameCompanionPreferences(enabled: true),
          recentMoments: [_moment()],
        ),
        throwsArgumentError,
      );
    });
  });
}
