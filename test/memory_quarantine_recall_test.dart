import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_gene.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/core/services/entangled_memory_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/gene_encoder_service.dart';
import 'package:maaso/src/core/services/gene_inheritance_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/world_kb_service.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  group('EpisodeStore accepted-current recall boundary', () {
    test(
      'keyword and empty-query recall omit quarantine and superseded rows',
      () async {
        final fixture = await _MemoryFixture.open('keyword-empty');
        addTearDown(fixture.close);

        final accepted = await fixture.persist(
          _episode('accepted atlas memory', EpisodeReviewState.accepted),
        );
        final pending = await fixture.persist(
          _episode('pending atlas memory', EpisodeReviewState.pending),
        );
        final rejected = await fixture.persist(
          _episode('rejected atlas memory', EpisodeReviewState.rejected),
        );
        final tombstoned = await fixture.persist(
          _episode('tombstoned atlas memory', EpisodeReviewState.tombstoned),
        );
        final superseded = await fixture.persist(
          _episode('superseded atlas memory', EpisodeReviewState.accepted),
        );
        await fixture.markCurrent(superseded, current: false);

        final keyword = await fixture.store.search('atlas', limit: 20);
        final emptyQuery = await fixture.store.search('', limit: 20);

        expect(keyword.map((episode) => episode.id), <int?>[accepted.id]);
        expect(emptyQuery.map((episode) => episode.id), <int?>[accepted.id]);
        expect(<int?>[
          pending.id,
          rejected.id,
          tombstoned.id,
          superseded.id,
        ], everyElement(isNot(isIn(keyword.map((episode) => episode.id)))));
      },
    );

    test('semantic recall omits every non accepted-current row', () async {
      final fixture = await _MemoryFixture.open('semantic');
      addTearDown(fixture.close);
      appServices.put<EmbeddingService>(_StaticEmbeddingService());

      final accepted = await fixture.persist(
        _episode(
          'accepted semantic memory',
          EpisodeReviewState.accepted,
          embedding: const <double>[1, 0],
        ),
      );
      final pending = await fixture.persist(
        _episode(
          'pending semantic memory',
          EpisodeReviewState.pending,
          embedding: const <double>[1, 0],
        ),
      );
      final rejected = await fixture.persist(
        _episode(
          'rejected semantic memory',
          EpisodeReviewState.rejected,
          embedding: const <double>[1, 0],
        ),
      );
      final tombstoned = await fixture.persist(
        _episode(
          'tombstoned semantic memory',
          EpisodeReviewState.tombstoned,
          embedding: const <double>[1, 0],
        ),
      );
      final superseded = await fixture.persist(
        _episode(
          'superseded semantic memory',
          EpisodeReviewState.accepted,
          embedding: const <double>[1, 0],
        ),
      );
      await fixture.markCurrent(superseded, current: false);

      final results = await fixture.store.search('semantic', limit: 20);

      expect(results.map((episode) => episode.id), <int?>[accepted.id]);
      final resultIds = results.map((episode) => episode.id).toSet();
      expect(resultIds, isNot(contains(pending.id)));
      expect(resultIds, isNot(contains(rejected.id)));
      expect(resultIds, isNot(contains(tombstoned.id)));
      expect(resultIds, isNot(contains(superseded.id)));
    });
  });

  group('EntangledMemoryService accepted-current boundary', () {
    test('linkEpisode creates no edge for a quarantined episode', () async {
      final fixture = await _MemoryFixture.open('entangled-link');
      addTearDown(fixture.close);
      final entangled = EntangledMemoryService();

      await fixture.persist(
        _episode(
          'accepted trip to Kyoto',
          EpisodeReviewState.accepted,
          entities: const <String>['Kyoto'],
        ),
      );
      final pending = await fixture.persist(
        _episode(
          'pending trip to Kyoto',
          EpisodeReviewState.pending,
          entities: const <String>['Kyoto'],
        ),
      );

      await entangled.linkEpisode(pending);

      expect(await _entanglements.count(fixture.database), 0);
    });

    test('expand never returns a quarantined edge target', () async {
      final fixture = await _MemoryFixture.open('entangled-expand');
      addTearDown(fixture.close);
      final entangled = EntangledMemoryService();

      final seed = await fixture.persist(
        _episode('accepted seed', EpisodeReviewState.accepted),
      );
      final pendingTarget = await fixture.persist(
        _episode('pending target', EpisodeReviewState.pending),
      );
      await _entanglements
          .record('${seed.id}:${pendingTarget.id}')
          .put(
            fixture.database,
            MemoryEntanglement(
              fromEpisodeId: seed.id!,
              toEpisodeId: pendingTarget.id!,
              weight: 0.95,
              relationType: 'entity',
              evidence: 'test edge',
              createdAt: _now,
              updatedAt: _now,
            ).toJson(),
          );

      final hits = await entangled.expand(<Episode>[seed], limit: 10);

      expect(hits, isEmpty);
    });

    test(
      'removeEpisodeLinks deletes incoming and outgoing derived edges',
      () async {
        final fixture = await _MemoryFixture.open('entangled-remove');
        addTearDown(fixture.close);
        final entangled = EntangledMemoryService();

        final first = await fixture.persist(
          _episode('accepted first memory', EpisodeReviewState.accepted),
        );
        final second = await fixture.persist(
          _episode('accepted second memory', EpisodeReviewState.accepted),
        );
        for (final edge in <MemoryEntanglement>[
          MemoryEntanglement(
            fromEpisodeId: first.id!,
            toEpisodeId: second.id!,
            weight: 0.8,
            relationType: 'entity',
            evidence: 'outgoing test edge',
            createdAt: _now,
            updatedAt: _now,
          ),
          MemoryEntanglement(
            fromEpisodeId: second.id!,
            toEpisodeId: first.id!,
            weight: 0.7,
            relationType: 'entity',
            evidence: 'incoming test edge',
            createdAt: _now,
            updatedAt: _now,
          ),
        ]) {
          await _entanglements
              .record('${edge.fromEpisodeId}:${edge.toEpisodeId}')
              .put(fixture.database, edge.toJson());
        }

        await entangled.removeEpisodeLinks(first.id!);

        expect(await _entanglements.count(fixture.database), 0);
      },
    );
  });

  test('GeneEncoder exports only accepted-current episodes', () async {
    final fixture = await _MemoryFixture.open('gene-export');
    addTearDown(fixture.close);

    await fixture.persist(
      _episode(
        'accepted gene memory',
        EpisodeReviewState.accepted,
        salience: 0.2,
      ),
    );
    await fixture.persist(
      _episode(
        'quarantined gene memory',
        EpisodeReviewState.pending,
        salience: 1,
      ),
    );
    final superseded = await fixture.persist(
      _episode(
        'superseded gene memory',
        EpisodeReviewState.accepted,
        salience: 0.9,
      ),
    );
    await fixture.markCurrent(superseded, current: false);

    final core = appServices.put<AgentCoreController>(AgentCoreController());
    await core.ensureLoaded();

    final gene = await GeneEncoderService().encode();

    expect(gene, isNotNull);
    expect(gene!.keyEpisodes.map((episode) => episode['what']), <String>[
      'accepted gene memory',
    ]);
  });

  group('GeneInheritanceService quarantine boundary', () {
    test(
      'legacy-checksummed imports become pending without WorldKB leakage',
      () async {
        final fixture = await _GeneImportFixture.open('gene-inherit-signed');
        addTearDown(fixture.close);
        final unsigned = _gene(signature: 'placeholder');
        final gene = _gene(signature: _signatureFor(unsigned));

        final received = await GeneInheritanceService().receiveGene(gene);
        final episodes = await fixture.episodes();

        expect(received, isTrue);
        expect(episodes, hasLength(1 + gene.keyEpisodes.length));
        expect(
          episodes.map((episode) => episode.reviewState),
          everyElement(EpisodeReviewState.pending),
        );
        expect(
          episodes.map((episode) => episode.sourceType),
          everyElement(EpisodeSourceType.inherited),
        );
        expect(
          episodes.expand((episode) => episode.sourceRefs),
          hasLength(episodes.length),
        );
        expect(
          episodes
              .expand((episode) => episode.sourceRefs)
              .map((source) => source.origin),
          everyElement(EpisodeSourceOrigin.imported),
        );
        expect(
          episodes.where((episode) => episode.what.contains(gene.memoryDigest)),
          hasLength(1),
        );
        for (final keyEpisode in gene.keyEpisodes) {
          expect(
            episodes.where(
              (episode) => episode.what.contains(keyEpisode['what']! as String),
            ),
            hasLength(1),
          );
        }
        for (final episode in episodes) {
          final governance = await MemoryGovernanceStores.episodeGovernance
              .record(episode.id!)
              .get(fixture.database);
          expect(governance?['current'], isFalse);
          expect(governance?['reviewState'], EpisodeReviewState.pending.name);
        }
        expect(
          await MemoryGovernanceStores.sourceMaterial.count(fixture.database),
          episodes.length,
        );
        expect(fixture.world.updateCalls, 0);
        expect(fixture.world.notes.value, isEmpty);
        expect(fixture.bus.l3Block(), isNot(contains(gene.memoryDigest)));
        expect(
          await fixture.bus.l2Recall('stargazing Kyoto watercolor'),
          isEmpty,
        );
      },
    );

    test(
      'empty signature is rejected without Episode or WorldKB writes',
      () async {
        final fixture = await _GeneImportFixture.open('gene-inherit-unsigned');
        addTearDown(fixture.close);
        final gene = _gene(signature: '');

        final received = await GeneInheritanceService().receiveGene(gene);

        expect(received, isFalse);
        expect(await fixture.episodes(), isEmpty);
        expect(
          await MemoryGovernanceStores.sourceMaterial.count(fixture.database),
          0,
        );
        expect(fixture.world.updateCalls, 0);
        expect(fixture.world.notes.value, isEmpty);
        expect(fixture.bus.l3Block(), isNot(contains(gene.memoryDigest)));
      },
    );

    test(
      'an empty agent token is rejected even with a matching checksum',
      () async {
        final fixture = await _GeneImportFixture.open('gene-empty-token');
        addTearDown(fixture.close);
        final base = _gene(signature: 'placeholder');
        final unsigned = AgentGene(
          agentToken: '',
          name: base.name,
          gender: base.gender,
          voiceId: base.voiceId,
          birthDate: base.birthDate,
          deathDate: base.deathDate,
          memoryDigest: base.memoryDigest,
          skills: base.skills,
          personalityTraits: base.personalityTraits,
          keyEpisodes: base.keyEpisodes,
          signature: 'placeholder',
        );
        final gene = AgentGene(
          agentToken: unsigned.agentToken,
          name: unsigned.name,
          gender: unsigned.gender,
          voiceId: unsigned.voiceId,
          birthDate: unsigned.birthDate,
          deathDate: unsigned.deathDate,
          memoryDigest: unsigned.memoryDigest,
          skills: unsigned.skills,
          personalityTraits: unsigned.personalityTraits,
          keyEpisodes: unsigned.keyEpisodes,
          signature: _signatureFor(unsigned),
        );

        expect(await GeneInheritanceService().receiveGene(gene), isFalse);
        expect(await fixture.episodes(), isEmpty);
        expect(
          await MemoryGovernanceStores.sourceMaterial.count(fixture.database),
          0,
        );
      },
    );

    test(
      'an empty memory digest is rejected even with a matching checksum',
      () async {
        final fixture = await _GeneImportFixture.open('gene-empty-digest');
        addTearDown(fixture.close);
        final unsigned = _copyGene(
          _gene(signature: 'placeholder'),
          memoryDigest: '',
        );
        final gene = _copyGene(unsigned, signature: _signatureFor(unsigned));

        expect(await GeneInheritanceService().receiveGene(gene), isFalse);
        expect(await fixture.episodes(), isEmpty);
        expect(
          await MemoryGovernanceStores.sourceMaterial.count(fixture.database),
          0,
        );
      },
    );

    test('missing gene dates fail closed during JSON decoding', () {
      final gene = _gene(signature: '00000000');
      for (final field in <String>['birthDate', 'deathDate']) {
        final json = Map<String, Object?>.from(gene.toJson())..remove(field);
        expect(() => AgentGene.fromJson(json), throwsFormatException);
      }
    });

    test(
      'a malformed later key episode cannot leave a partial import',
      () async {
        final fixture = await _GeneImportFixture.open('gene-preflight');
        addTearDown(fixture.close);
        final unsigned = _copyGene(
          _gene(signature: 'placeholder'),
          keyEpisodes: <Map<String, Object?>>[
            <String, Object?>{'what': 'A valid first memory.', 'salience': 0.6},
            <String, Object?>{
              'what': 'An invalid later memory.',
              'salience': 'high',
            },
          ],
        );
        final gene = _copyGene(unsigned, signature: _signatureFor(unsigned));

        expect(await GeneInheritanceService().receiveGene(gene), isFalse);
        expect(await fixture.episodes(), isEmpty);
        expect(
          await MemoryGovernanceStores.sourceMaterial.count(fixture.database),
          0,
        );
      },
    );

    test(
      'a tampered first import cannot block the original material identity',
      () async {
        final fixture = await _GeneImportFixture.open('gene-source-rebind');
        addTearDown(fixture.close);
        final unsigned = _gene(signature: 'placeholder');
        final original = _gene(signature: _signatureFor(unsigned));
        final inheritance = GeneInheritanceService();
        final tampered = _tamperFirstKeyEpisode(original);
        expect(tampered.agentToken, original.agentToken);
        expect(tampered.signature, original.signature);
        expect(_signatureFor(tampered), original.signature);

        expect(await inheritance.receiveGene(tampered), isTrue);
        expect(await fixture.episodes(), hasLength(3));
        expect(await inheritance.receiveGene(original), isTrue);
        final episodesAfter = await fixture.episodes();

        expect(
          episodesAfter.map((episode) => episode.reviewState),
          everyElement(EpisodeReviewState.pending),
        );
        expect(episodesAfter, hasLength(4));
        expect(
          episodesAfter.where(
            (episode) => episode.what.contains('tampered payload'),
          ),
          hasLength(1),
        );
        expect(
          episodesAfter.where(
            (episode) => episode.what.contains(
              original.keyEpisodes.first['what']! as String,
            ),
          ),
          hasLength(1),
        );
        expect(
          await MemoryGovernanceStores.sourceMaterial.count(fixture.database),
          4,
        );
        expect(await inheritance.receiveGene(original), isTrue);
        expect(await fixture.episodes(), hasLength(4));
        expect(fixture.world.updateCalls, 0);
        expect(fixture.world.notes.value, isEmpty);
        expect(fixture.bus.l3Block(), isNot(contains('tampered payload')));
      },
    );

    test(
      'material-bound source identities separate name and death variants',
      () async {
        final fixture = await _GeneImportFixture.open('gene-source-identity');
        addTearDown(fixture.close);
        final unsigned = _gene(signature: 'placeholder');
        final original = _gene(signature: _signatureFor(unsigned));
        final inheritance = GeneInheritanceService();

        expect(await inheritance.receiveGene(original), isTrue);
        final variants = <AgentGene>[
          _copyGene(original, name: 'Mallory'),
          _copyGene(
            original,
            deathDate: original.deathDate.add(const Duration(days: 1)),
          ),
        ];

        for (final rebound in variants) {
          expect(rebound.signature, original.signature);
          expect(_signatureFor(rebound), original.signature);
          expect(await inheritance.receiveGene(rebound), isTrue);
        }
        final episodes = await fixture.episodes();
        expect(episodes, hasLength(7));
        expect(
          episodes.map((episode) => episode.reviewState),
          everyElement(EpisodeReviewState.pending),
        );
        expect(
          await MemoryGovernanceStores.sourceMaterial.count(fixture.database),
          9,
        );
        expect(fixture.world.updateCalls, 0);
        expect(fixture.world.notes.value, isEmpty);
        expect(await fixture.bus.l2Recall('Mallory'), isEmpty);
      },
    );

    test('a key episode without when uses the gene death date', () async {
      final fixture = await _GeneImportFixture.open('gene-default-when');
      addTearDown(fixture.close);
      final unsigned = _copyGene(
        _gene(signature: 'placeholder'),
        keyEpisodes: <Map<String, Object?>>[
          <String, Object?>{
            'what': 'A memory without its own timestamp.',
            'emotion': 'calm',
            'salience': 0.6,
          },
        ],
      );
      final gene = _copyGene(unsigned, signature: _signatureFor(unsigned));

      expect(await GeneInheritanceService().receiveGene(gene), isTrue);
      final episodes = await fixture.episodes();
      final keyEpisode = episodes.singleWhere(
        (episode) => episode.what.contains('without its own timestamp'),
      );

      expect(keyEpisode.when.toUtc(), gene.deathDate.toUtc());
      expect(keyEpisode.reviewState, EpisodeReviewState.pending);
    });
  });
}

const String _accountScopeDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final DateTime _now = DateTime.utc(2026, 8, 29, 12);
final StoreRef<int, Map<String, Object?>> _episodes = intMapStoreFactory.store(
  'episodes',
);
final StoreRef<String, Map<String, Object?>> _entanglements =
    StoreRef<String, Map<String, Object?>>('memory_entanglements');
var _databaseSequence = 0;

Episode _episode(
  String what,
  EpisodeReviewState reviewState, {
  List<String> entities = const <String>['Maaso'],
  double salience = 0.5,
  List<double>? embedding,
}) => Episode(
  when: _now,
  what: what,
  entities: entities,
  salience: salience,
  embedding: embedding,
  reviewState: reviewState,
);

final class _MemoryFixture {
  _MemoryFixture({required this.dbService, required this.store});

  final DBService dbService;
  final EpisodeStore store;

  Database get database => dbService.raw;

  static Future<_MemoryFixture> open(String label) async {
    final dbService = await DBService().init(
      factory: databaseFactoryMemory,
      path: '$label-${_databaseSequence++}.db',
    );
    appServices.put<DBService>(dbService);
    final store = EpisodeStore(
      database: dbService.raw,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      clock: () => _now,
    );
    appServices.put<EpisodeStore>(store);
    return _MemoryFixture(dbService: dbService, store: store);
  }

  Future<Episode> persist(Episode episode) async {
    final id = await _episodes.add(database, episode.toJson());
    episode.id = id;
    return episode;
  }

  Future<void> markCurrent(Episode episode, {required bool current}) async {
    await MemoryGovernanceStores.episodeGovernance
        .record(episode.id!)
        .put(database, <String, Object?>{
          'schemaVersion': 1,
          'accountScopeDigest': _accountScopeDigest,
          'episodeId': episode.id,
          'current': current,
          'reviewState': episode.reviewState.name,
        });
  }

  Future<void> close() async {
    await store.deactivateAndDrain();
    await dbService.close();
  }
}

final class _StaticEmbeddingService extends EmbeddingService {
  @override
  bool get isAvailable => true;

  @override
  Future<List<double>?> embed(String text) async => const <double>[1, 0];
}

final class _GeneImportFixture {
  _GeneImportFixture({
    required this.memory,
    required this.coordinator,
    required this.bus,
    required this.world,
  });

  final _MemoryFixture memory;
  final MemoryWriteCoordinator coordinator;
  final MemoryBus bus;
  final _RecordingWorldKBService world;

  Database get database => memory.database;

  static Future<_GeneImportFixture> open(String label) async {
    final memory = await _MemoryFixture.open(label);
    final coordinator = MemoryWriteCoordinator(
      database: memory.database,
      episodeStore: memory.store,
      accountScopeDigest: _accountScopeDigest,
      memoryV2Mode: () => FeatureRolloutMode.enforce,
      clock: () => _now,
      linkEpisode: (_) async {},
      projectMilestone: (_) async {},
    );
    appServices.put<MemoryWriteCoordinator>(coordinator);
    appServices.put<SoulService>(SoulService());
    appServices.put<MasterProfileService>(MasterProfileService());
    final world = _RecordingWorldKBService();
    appServices.put<WorldKBService>(world);
    final bus = MemoryBus();
    appServices.put<MemoryBus>(bus);
    return _GeneImportFixture(
      memory: memory,
      coordinator: coordinator,
      bus: bus,
      world: world,
    );
  }

  Future<List<Episode>> episodes() async {
    final records = await _episodes.find(database);
    return records
        .map((record) => Episode.fromJson(record.value)..id = record.key)
        .toList(growable: false);
  }

  Future<Map<int, Map<String, Object?>>> rawEpisodeRows() async {
    final records = await _episodes.find(database);
    return <int, Map<String, Object?>>{
      for (final record in records)
        record.key: Map<String, Object?>.from(record.value),
    };
  }

  Future<void> close() async {
    await coordinator.deactivateAndDrain();
    await memory.close();
  }
}

final class _RecordingWorldKBService extends WorldKBService {
  int updateCalls = 0;

  @override
  Future<MemoryWriteResult> update({
    String? notesAppend,
    String? notesReplace,
  }) async {
    updateCalls += 1;
    if (notesReplace != null) {
      notes.value = notesReplace.trim();
    } else if (notesAppend != null && notesAppend.trim().isNotEmpty) {
      final appended = notesAppend.trim();
      notes.value = notes.value.isEmpty
          ? appended
          : '${notes.value}\n$appended';
    }
    return const MemoryWriteResult(
      disposition: MemoryWriteDisposition.rejected,
      episode: null,
      created: false,
      projected: false,
      reason: 'recording_test_double',
    );
  }
}

AgentGene _gene({required String signature}) => AgentGene(
  agentToken: 'gene-token-1',
  name: 'Atlas Ancestor',
  gender: 'neutral',
  voiceId: 'legacy-voice',
  birthDate: DateTime.utc(2020, 1, 2),
  deathDate: DateTime.utc(2026, 8, 28),
  memoryDigest: '祖先喜欢在天文台旁边观星。',
  keyEpisodes: <Map<String, Object?>>[
    <String, Object?>{
      'when': DateTime.utc(2024, 4, 5).toIso8601String(),
      'what': 'Visited Kyoto during the spring rain.',
      'emotion': 'calm',
      'salience': 0.8,
    },
    <String, Object?>{
      'when': DateTime.utc(2025, 6, 7).toIso8601String(),
      'what': 'Painted a blue watercolor for a friend.',
      'emotion': 'happy',
      'salience': 0.7,
    },
  ],
  signature: signature,
);

String _signatureFor(AgentGene gene) {
  final bytes = utf8.encode('${gene.agentToken}:${gene.memoryDigest}');
  var hash = 0;
  for (final byte in bytes) {
    hash = ((hash << 5) - hash + byte) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

AgentGene _tamperFirstKeyEpisode(AgentGene original) => AgentGene(
  agentToken: original.agentToken,
  name: original.name,
  gender: original.gender,
  voiceId: original.voiceId,
  birthDate: original.birthDate,
  deathDate: original.deathDate,
  memoryDigest: original.memoryDigest,
  skills: original.skills,
  personalityTraits: original.personalityTraits,
  keyEpisodes: <Map<String, Object?>>[
    <String, Object?>{
      ...original.keyEpisodes.first,
      'what': 'tampered payload with the same legacy checksum',
    },
    ...original.keyEpisodes.skip(1).map(Map<String, Object?>.from),
  ],
  signature: original.signature,
);

AgentGene _copyGene(
  AgentGene original, {
  String? name,
  DateTime? deathDate,
  String? memoryDigest,
  List<Map<String, Object?>>? keyEpisodes,
  String? signature,
}) => AgentGene(
  agentToken: original.agentToken,
  name: name ?? original.name,
  gender: original.gender,
  voiceId: original.voiceId,
  birthDate: original.birthDate,
  deathDate: deathDate ?? original.deathDate,
  memoryDigest: memoryDigest ?? original.memoryDigest,
  skills: original.skills,
  personalityTraits: original.personalityTraits,
  keyEpisodes: keyEpisodes ?? original.keyEpisodes,
  signature: signature ?? original.signature,
);
