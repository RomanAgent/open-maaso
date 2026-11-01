import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/episode.dart';

void main() {
  final when = DateTime.fromMillisecondsSinceEpoch(1770000000000);
  final createdAt = DateTime.fromMillisecondsSinceEpoch(1770000001000);
  final updatedAt = DateTime.fromMillisecondsSinceEpoch(1770000002000);
  final activatedAt = DateTime.fromMillisecondsSinceEpoch(1770000003000);
  final expiresAt = DateTime.fromMillisecondsSinceEpoch(1771000000000);

  test(
    'existing constructor remains compatible and defaults to runtimeUnknown',
    () {
      final episode = Episode(
        id: 9,
        when: when,
        what: 'A small scene',
        entities: const <String>['Maaso'],
        emotion: 'calm',
        salience: 0.7,
        embedding: const <double>[0.1, 0.2],
      );

      expect(episode.schemaVersion, Episode.currentSchemaVersion);
      expect(episode.agentId, 'self');
      expect(episode.kind, EpisodeKind.episode);
      expect(episode.sourceType, EpisodeSourceType.runtimeUnknown);
      expect(episode.sourceRefs, isEmpty);
      expect(episode.reviewState, EpisodeReviewState.accepted);
      expect(episode.revision, 1);
      expect(episode.createdAt, when);
      expect(episode.updatedAt, when);
      expect(episode.activationCount, 0);
      expect(episode.retentionClass, EpisodeRetentionClass.durable);

      final canonical = episode.toJson();
      expect(canonical['schemaVersion'], 2);
      expect(canonical['when'], when.millisecondsSinceEpoch);
      expect(canonical, isNot(contains('id')));
      expect(episode.toLegacyJson(), <String, Object?>{
        'when': when.millisecondsSinceEpoch,
        'what': 'A small scene',
        'entities': <String>['Maaso'],
        'emotion': 'calm',
        'salience': 0.7,
        'embedding': <double>[0.1, 0.2],
      });
    },
  );

  test('sparse legacy row maps to accepted legacyUnknown v2 defaults', () {
    final episode = Episode.fromJson(const <String, Object?>{});

    expect(episode.schemaVersion, 2);
    expect(episode.when.millisecondsSinceEpoch, 0);
    expect(episode.what, '');
    expect(episode.entities, isEmpty);
    expect(episode.salience, 0.5);
    expect(episode.agentId, 'self');
    expect(episode.sourceType, EpisodeSourceType.legacyUnknown);
    expect(episode.sourceRefs, isEmpty);
    expect(episode.reviewState, EpisodeReviewState.accepted);
    expect(episode.createdAt, episode.when);
    expect(episode.updatedAt, episode.when);

    final migrated = Episode.fromJson(episode.toJson());
    expect(migrated.sourceType, EpisodeSourceType.legacyUnknown);
    expect(migrated.reviewState, EpisodeReviewState.accepted);
  });

  test(
    'full legacy row preserves the old payload and accepts agent context',
    () {
      final legacy = <String, Object?>{
        'when': when.millisecondsSinceEpoch,
        'what': 'Legacy memory',
        'entities': <Object?>['friend', 7],
        'emotion': 'happy',
        'salience': 0.8,
        'embedding': <Object?>[0.25, 0.75],
      };

      final episode = Episode.fromJson(legacy, legacyAgentId: 'agent-a');

      expect(episode.agentId, 'agent-a');
      expect(episode.what, 'Legacy memory');
      expect(episode.entities, <String>['friend', '7']);
      expect(episode.embedding, <double>[0.25, 0.75]);
      expect(episode.sourceType, EpisodeSourceType.legacyUnknown);
      expect(episode.reviewState, EpisodeReviewState.accepted);
      expect(episode.toLegacyJson(), <String, Object?>{
        'when': when.millisecondsSinceEpoch,
        'what': 'Legacy memory',
        'entities': <String>['friend', '7'],
        'emotion': 'happy',
        'salience': 0.8,
        'embedding': <double>[0.25, 0.75],
      });
    },
  );

  test('explicit null, v1, and unknown schema versions are rejected', () {
    for (final version in <Object?>[null, 1, 3, '2']) {
      expect(
        () => Episode.fromJson(<String, Object?>{'schemaVersion': version}),
        throwsFormatException,
      );
    }
  });

  test('full v2 payload round-trips every field canonically', () {
    final sourceRef = EpisodeSourceRef(
      sourceId: 'message-42',
      sessionId: 'session-7',
      origin: EpisodeSourceOrigin.user,
      contentHash: _hash('a'),
    );
    final episode = Episode(
      id: 99,
      when: when,
      what: 'The user decided to travel.',
      entities: const <String>['user', 'travel'],
      emotion: 'hopeful',
      salience: 0.9,
      embedding: const <double>[0.3, -0.2, 0.8],
      agentId: 'agent-self',
      kind: EpisodeKind.plan,
      sourceRefs: <EpisodeSourceRef>[sourceRef],
      sourceType: EpisodeSourceType.conversation,
      confidence: 0.85,
      reviewState: EpisodeReviewState.pending,
      revision: 4,
      supersedesId: 12,
      contradictionIds: const <int>[3, 8],
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastActivatedAt: activatedAt,
      activationCount: 6,
      expiresAt: expiresAt,
      retentionClass: EpisodeRetentionClass.standard,
    );

    final json = episode.toJson();
    final restored = Episode.fromJson(json);

    expect(json, hasLength(22));
    expect(json, isNot(contains('id')));
    expect(restored.id, isNull);
    expect(restored.schemaVersion, 2);
    expect(restored.when, when);
    expect(restored.what, episode.what);
    expect(restored.entities, episode.entities);
    expect(restored.emotion, episode.emotion);
    expect(restored.salience, episode.salience);
    expect(restored.embedding, episode.embedding);
    expect(restored.agentId, 'agent-self');
    expect(restored.kind, EpisodeKind.plan);
    expect(restored.sourceType, EpisodeSourceType.conversation);
    expect(restored.confidence, 0.85);
    expect(restored.reviewState, EpisodeReviewState.pending);
    expect(restored.revision, 4);
    expect(restored.supersedesId, 12);
    expect(restored.contradictionIds, <int>[3, 8]);
    expect(restored.createdAt, createdAt);
    expect(restored.updatedAt, updatedAt);
    expect(restored.lastActivatedAt, activatedAt);
    expect(restored.activationCount, 6);
    expect(restored.expiresAt, expiresAt);
    expect(restored.retentionClass, EpisodeRetentionClass.standard);
    expect(restored.sourceRefs, hasLength(1));
    expect(restored.sourceRefs.single.sourceId, 'message-42');
    expect(restored.sourceRefs.single.sessionId, 'session-7');
    expect(restored.sourceRefs.single.origin, EpisodeSourceOrigin.user);
    expect(restored.sourceRefs.single.contentHash, _hash('a'));
    expect(restored.toJson(), json);
  });

  test('v2 codec rejects missing, unknown, and invalid values', () {
    final valid = _validV2(when);

    final missing = Map<String, Object?>.from(valid)..remove('confidence');
    final unknown = Map<String, Object?>.from(valid)..['futureField'] = true;
    final badConfidence = Map<String, Object?>.from(valid)
      ..['confidence'] = 1.01;
    final badKind = Map<String, Object?>.from(valid)..['kind'] = 'memory';
    final badDate = Map<String, Object?>.from(valid)
      ..['createdAt'] = '2026-01-01';
    final reversedDates = Map<String, Object?>.from(valid)
      ..['updatedAt'] = when.millisecondsSinceEpoch - 1;
    final badRevision = Map<String, Object?>.from(valid)..['revision'] = 0;
    final duplicateContradictions = Map<String, Object?>.from(valid)
      ..['contradictionIds'] = <int>[2, 2];

    for (final json in <Map<String, Object?>>[
      missing,
      unknown,
      badConfidence,
      badKind,
      badDate,
      reversedDates,
      badRevision,
      duplicateContradictions,
    ]) {
      expect(() => Episode.fromJson(json), throwsFormatException);
    }
  });

  test(
    'typed provenance requires bounded refs and unknown sources reject refs',
    () {
      expect(
        () => Episode(
          when: when,
          what: 'Missing source',
          sourceType: EpisodeSourceType.conversation,
        ),
        throwsArgumentError,
      );
      expect(
        () => Episode(
          when: when,
          what: 'False provenance',
          sourceType: EpisodeSourceType.runtimeUnknown,
          sourceRefs: <EpisodeSourceRef>[_ref()],
        ),
        throwsArgumentError,
      );
      expect(
        () => Episode(
          when: when,
          what: 'Not a decoded legacy row',
          sourceType: EpisodeSourceType.legacyUnknown,
        ),
        throwsArgumentError,
      );
      expect(
        () => EpisodeSourceRef(
          sourceId: List<String>.filled(257, 'x').join(),
          sessionId: 'session',
          origin: EpisodeSourceOrigin.system,
          contentHash: _hash('b'),
        ),
        throwsArgumentError,
      );
      expect(
        () => EpisodeSourceRef(
          sourceId: 'source',
          sessionId: 'session',
          origin: EpisodeSourceOrigin.system,
          contentHash: 'not-a-hash',
        ),
        throwsArgumentError,
      );

      final typed = Episode(
        when: when,
        what: 'Has source',
        sourceType: EpisodeSourceType.explicitSave,
        sourceRefs: <EpisodeSourceRef>[_ref()],
      );
      expect(typed.sourceRefs, hasLength(1));
    },
  );
}

Map<String, Object?> _validV2(DateTime when) => Episode(
  when: when,
  what: 'Valid',
  sourceType: EpisodeSourceType.conversation,
  sourceRefs: <EpisodeSourceRef>[_ref()],
).toJson();

EpisodeSourceRef _ref() => EpisodeSourceRef(
  sourceId: 'message-1',
  sessionId: 'session-1',
  origin: EpisodeSourceOrigin.user,
  contentHash: _hash('c'),
);

String _hash(String character) => List<String>.filled(64, character).join();
