import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/local_skill_retriever.dart';

void main() {
  test('repeated retrieval does not reread normalized manifest fields', () {
    final manifests = List<_CountingManifest>.generate(
      10000,
      (index) => _CountingManifest(index),
      growable: false,
    );
    final retriever = LocalSkillRetriever(manifests);
    for (final manifest in manifests) {
      manifest.resetReads();
    }

    LocalSkillRetrievalMetrics? firstMetrics;
    LocalSkillRetrievalMetrics? secondMetrics;
    final first = retriever.retrieve(
      'please use tag-09999',
      onMetrics: (metrics) => firstMetrics = metrics,
    );
    final second = retriever.retrieve(
      'please use tag-09999',
      onMetrics: (metrics) => secondMetrics = metrics,
    );

    expect(first, hasLength(1));
    expect(second, hasLength(1));
    expect(identical(first.single, manifests.last), isTrue);
    expect(identical(second.single, manifests.last), isTrue);
    expect(
      manifests.fold<int>(0, (total, manifest) => total + manifest.reads),
      0,
    );
    for (final metrics in <LocalSkillRetrievalMetrics>[
      firstMetrics!,
      secondMetrics!,
    ]) {
      expect(metrics.indexedManifestCount, 10000);
      expect(metrics.matchedTermCount, 1);
      expect(metrics.postingVisits, 1);
      expect(metrics.scoredCandidateCount, 1);
      expect(metrics.retainedResultCount, 1);
      expect(
        metrics.bucketProbes,
        lessThanOrEqualTo(metrics.queryCodeUnitCount * 16),
      );
      expect(metrics.candidateTermChecks, lessThanOrEqualTo(3));
    }
  });

  test('no-match work is bounded by query size rather than 10k catalog', () {
    final retriever = LocalSkillRetriever(
      List<LocalSkillManifest>.generate(
        10000,
        (index) => _manifest(
          id: 'skill-${index.toString().padLeft(5, '0')}',
          tag: 'tag-${index.toString().padLeft(5, '0')}',
        ),
        growable: false,
      ),
    );
    LocalSkillRetrievalMetrics? metrics;

    final result = retriever.retrieve(
      'unrelated request',
      onMetrics: (value) => metrics = value,
    );

    expect(result, isEmpty);
    expect(metrics!.indexedManifestCount, 10000);
    expect(metrics!.postingVisits, 0);
    expect(metrics!.scoredCandidateCount, 0);
    expect(metrics!.retainedResultCount, 0);
    expect(
      metrics!.bucketProbes,
      lessThanOrEqualTo(metrics!.queryCodeUnitCount * 16),
    );
    expect(metrics!.candidateTermChecks, 0);
  });

  test('bounded Top-K preserves score and id tie order', () {
    final manifests = <LocalSkillManifest>[
      _manifest(id: 'zeta', tag: 'shared'),
      _manifest(id: 'alpha', tag: 'shared'),
      _manifest(id: 'middle', tag: 'shared'),
      _manifest(id: 'preferred', tag: 'other'),
    ];
    LocalSkillRetrievalMetrics? metrics;

    final result = LocalSkillRetriever(manifests).retrieve(
      'shared',
      maxResults: 2,
      preferredSkillIds: const <String>['PREFERRED'],
      onMetrics: (value) => metrics = value,
    );

    expect(result.map((manifest) => manifest.id), <String>[
      'preferred',
      'alpha',
    ]);
    expect(metrics!.scoredCandidateCount, 4);
    expect(metrics!.retainedResultCount, 2);
  });

  test('indexed scoring stays equivalent to the legacy substring contract', () {
    final manifests = <LocalSkillManifest>[
      LocalSkillManifest(
        id: 'alpha',
        skillName: 'Alpha',
        method: 'run',
        summary: 'open settings open',
        tags: const <String>['set', 'set', ''],
        argsSchema: const <String, dynamic>{},
      ),
      LocalSkillManifest(
        id: 'settings',
        skillName: 'Settings',
        method: 'run',
        summary: 'settings panel',
        tags: const <String>['settings', '设置'],
        argsSchema: const <String, dynamic>{},
      ),
      LocalSkillManifest(
        id: 'hidden',
        skillName: 'Hidden',
        method: 'run',
        summary: 'open settings',
        tags: const <String>['settings'],
        argsSchema: const <String, dynamic>{},
        localEligible: false,
      ),
    ];
    final retriever = LocalSkillRetriever(manifests);
    final scenarios = <({String query, List<String> preferred, int max})>[
      (query: 'OPEN SETTINGS', preferred: const <String>[], max: 6),
      (query: '请打开设置', preferred: const <String>[], max: 6),
      (query: 'nothing lexical', preferred: const <String>['ALPHA'], max: 1),
      (
        query: 'settings set open',
        preferred: const <String>['settings'],
        max: 2,
      ),
    ];

    for (final scenario in scenarios) {
      expect(
        retriever
            .retrieve(
              scenario.query,
              maxResults: scenario.max,
              preferredSkillIds: scenario.preferred,
            )
            .map((manifest) => manifest.id),
        _legacyRetrieve(
          manifests,
          scenario.query,
          maxResults: scenario.max,
          preferredSkillIds: scenario.preferred,
        ).map((manifest) => manifest.id),
        reason: scenario.query,
      );
    }
  });

  test('scoped retrievers reuse base and one lazy index per scope', () {
    var scopedBuilds = 0;
    final cache = ScopedLocalSkillRetrieverCache<String>(
      baseManifests: <LocalSkillManifest>[
        _manifest(id: 'base-probe', tag: 'base data'),
      ],
      scopedManifests: (scope) {
        scopedBuilds++;
        return <LocalSkillManifest>[
          _manifest(id: 'nav.$scope', tag: 'open $scope'),
        ];
      },
    );

    final baseFirst = cache.forTurn(scope: 'zh', includeScoped: false);
    final baseSecond = cache.forTurn(scope: 'en', includeScoped: false);
    final zhFirst = cache.forTurn(scope: 'zh', includeScoped: true);
    final zhSecond = cache.forTurn(scope: 'zh', includeScoped: true);
    final en = cache.forTurn(scope: 'en', includeScoped: true);

    expect(identical(baseFirst, baseSecond), isTrue);
    expect(identical(zhFirst, zhSecond), isTrue);
    expect(identical(zhFirst, en), isFalse);
    expect(scopedBuilds, 2);
    expect(cache.cachedScopeCount, 2);
    expect(
      baseFirst.retrieve('open zh').map((manifest) => manifest.id),
      isNot(contains('nav.zh')),
    );
    expect(
      zhFirst.retrieve('open zh').map((manifest) => manifest.id),
      contains('nav.zh'),
    );
  });
}

LocalSkillManifest _manifest({required String id, required String tag}) =>
    LocalSkillManifest(
      id: id,
      skillName: id,
      method: 'run',
      summary: 'summary for $id',
      tags: <String>[tag],
      argsSchema: const <String, dynamic>{},
    );

List<LocalSkillManifest> _legacyRetrieve(
  Iterable<LocalSkillManifest> manifests,
  String query, {
  required int maxResults,
  required Iterable<String> preferredSkillIds,
}) {
  final q = query.toLowerCase();
  final preferred = preferredSkillIds.map((id) => id.toLowerCase()).toSet();
  final scored = <({LocalSkillManifest manifest, int score})>[];
  for (final manifest in manifests) {
    if (!manifest.localEligible) continue;
    var score = 0;
    final id = manifest.id.toLowerCase();
    if (preferred.contains(id)) score += 20;
    if (q.contains(id)) score += 10;
    for (final tag in manifest.tags) {
      final normalizedTag = tag.toLowerCase();
      if (normalizedTag.isNotEmpty && q.contains(normalizedTag)) score += 8;
    }
    for (final word in manifest.summary.toLowerCase().split(' ')) {
      if (word.length > 3 && q.contains(word)) score += 2;
    }
    if (score > 0) scored.add((manifest: manifest, score: score));
  }
  scored.sort((first, second) {
    final byScore = second.score.compareTo(first.score);
    if (byScore != 0) return byScore;
    return first.manifest.id.compareTo(second.manifest.id);
  });
  return <LocalSkillManifest>[
    for (final item in scored.take(maxResults)) item.manifest,
  ];
}

class _CountingManifest extends LocalSkillManifest {
  _CountingManifest(int index)
    : _id = 'skill-${index.toString().padLeft(5, '0')}',
      _summary = 'summary${index.toString().padLeft(5, '0')}',
      _tags = <String>['tag-${index.toString().padLeft(5, '0')}'],
      super(
        id: '',
        skillName: '',
        method: 'run',
        summary: '',
        tags: const <String>[],
        argsSchema: const <String, dynamic>{},
      );

  final String _id;
  final String _summary;
  final List<String> _tags;
  int reads = 0;

  @override
  String get id {
    reads++;
    return _id;
  }

  @override
  String get summary {
    reads++;
    return _summary;
  }

  @override
  List<String> get tags {
    reads++;
    return _tags;
  }

  void resetReads() => reads = 0;
}
