import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';

/// Structural work performed by one [LocalSkillRetriever.retrieve] call.
///
/// [postingVisits] is the important scaling signal: retrieval work grows with
/// lexical matches and preferred ids, not with the full manifest catalog.
class LocalSkillRetrievalMetrics {
  const LocalSkillRetrievalMetrics({
    required this.indexedManifestCount,
    required this.segmentCount,
    required this.queryCodeUnitCount,
    required this.bucketProbes,
    required this.candidateTermChecks,
    required this.matchedTermCount,
    required this.postingVisits,
    required this.scoredCandidateCount,
    required this.retainedResultCount,
  });

  final int indexedManifestCount;
  final int segmentCount;
  final int queryCodeUnitCount;
  final int bucketProbes;
  final int candidateTermChecks;
  final int matchedTermCount;
  final int postingVisits;
  final int scoredCandidateCount;
  final int retainedResultCount;
}

/// Pre-normalized exact-substring retrieval for local-safe skill manifests.
///
/// Construction performs the only manifest scan and buckets ids, tags, and
/// eligible summary words by a one-to-sixteen-code-unit prefix. A turn probes
/// at most sixteen buckets per query position, verifies only bucket candidates,
/// visits matched postings, then retains a bounded Top-K heap. A term shared by
/// every skill still has O(N) postings — that is required to preserve the
/// existing additive substring score — but a no-match or selective query does
/// no catalog-wide work.
class LocalSkillRetriever {
  factory LocalSkillRetriever(Iterable<LocalSkillManifest> manifests) {
    final segment = _LocalSkillIndexSegment.build(manifests);
    return LocalSkillRetriever._(<_LocalSkillIndexSegment>[segment]);
  }

  LocalSkillRetriever._(List<_LocalSkillIndexSegment> segments)
    : _segments = List<_LocalSkillIndexSegment>.unmodifiable(
        segments.where((segment) => segment.entries.isNotEmpty),
      );

  final List<_LocalSkillIndexSegment> _segments;

  int get indexedManifestCount => _segments.fold<int>(
    0,
    (total, segment) => total + segment.entries.length,
  );

  List<LocalSkillManifest> retrieve(
    String query, {
    int maxResults = 6,
    Iterable<String> preferredSkillIds = const [],
    void Function(LocalSkillRetrievalMetrics metrics)? onMetrics,
  }) {
    if (maxResults < 0) {
      throw RangeError.range(maxResults, 0, null, 'maxResults');
    }

    final q = query.toLowerCase();
    final preferred = preferredSkillIds.map((id) => id.toLowerCase()).toSet();
    final retained = _BoundedTopK(maxResults);
    var bucketProbes = 0;
    var candidateTermChecks = 0;
    var matchedTermCount = 0;
    var postingVisits = 0;
    var scoredCandidateCount = 0;

    for (final segment in _segments) {
      final scores = <int, int>{};

      void addPostings(List<_WeightedPosting> postings) {
        postingVisits += postings.length;
        for (final posting in postings) {
          scores.update(
            posting.entryIndex,
            (score) => score + posting.weight,
            ifAbsent: () => posting.weight,
          );
        }
      }

      addPostings(segment.alwaysMatchedPostings);
      for (final preferredId in preferred) {
        final postings = segment.preferredIdPostings[preferredId];
        if (postings != null) addPostings(postings);
      }
      final matcherWork = segment.matcher.scan(q, (postings) {
        matchedTermCount++;
        addPostings(postings);
      });
      bucketProbes += matcherWork.bucketProbes;
      candidateTermChecks += matcherWork.candidateTermChecks;

      scoredCandidateCount += scores.length;
      for (final scored in scores.entries) {
        retained.add(
          _ScoredManifest(
            entry: segment.entries[scored.key],
            score: scored.value,
          ),
        );
      }
    }

    final best = retained.toBestFirstList();
    onMetrics?.call(
      LocalSkillRetrievalMetrics(
        indexedManifestCount: indexedManifestCount,
        segmentCount: _segments.length,
        queryCodeUnitCount: q.length,
        bucketProbes: bucketProbes,
        candidateTermChecks: candidateTermChecks,
        matchedTermCount: matchedTermCount,
        postingVisits: postingVisits,
        scoredCandidateCount: scoredCandidateCount,
        retainedResultCount: best.length,
      ),
    );
    return <LocalSkillManifest>[for (final item in best) item.entry.manifest];
  }
}

/// Reuses one base index and lazily adds one small, cached segment per scope.
///
/// Home uses the locale as [Scope], with navigation manifests as the scoped
/// segment. Selecting the base path therefore cannot surface AppNavigate, and
/// entering the navigation path never rebuilds or copies the 10k base index.
class ScopedLocalSkillRetrieverCache<Scope> {
  ScopedLocalSkillRetrieverCache({
    required Iterable<LocalSkillManifest> baseManifests,
    required Iterable<LocalSkillManifest> Function(Scope scope) scopedManifests,
  }) : _base = LocalSkillRetriever(baseManifests),
       _scopedManifests = scopedManifests;

  final LocalSkillRetriever _base;
  final Iterable<LocalSkillManifest> Function(Scope scope) _scopedManifests;
  final Map<Scope, LocalSkillRetriever> _scoped =
      <Scope, LocalSkillRetriever>{};

  int get cachedScopeCount => _scoped.length;

  LocalSkillRetriever forTurn({
    required Scope scope,
    required bool includeScoped,
  }) {
    if (!includeScoped) return _base;
    return _scoped.putIfAbsent(scope, () {
      final scoped = LocalSkillRetriever(_scopedManifests(scope));
      return LocalSkillRetriever._(<_LocalSkillIndexSegment>[
        ..._base._segments,
        ...scoped._segments,
      ]);
    });
  }
}

class _LocalSkillIndexSegment {
  _LocalSkillIndexSegment({
    required this.entries,
    required this.matcher,
    required this.preferredIdPostings,
    required this.alwaysMatchedPostings,
  });

  factory _LocalSkillIndexSegment.build(
    Iterable<LocalSkillManifest> manifests,
  ) {
    final entries = <_IndexedManifest>[];
    final termPostings = <String, List<_WeightedPosting>>{};
    final preferredIdPostings = <String, List<_WeightedPosting>>{};
    final alwaysMatchedPostings = <_WeightedPosting>[];

    for (final manifest in manifests) {
      if (!manifest.localEligible) continue;
      final id = manifest.id;
      final normalizedId = id.toLowerCase();
      final entryIndex = entries.length;
      entries.add(_IndexedManifest(manifest: manifest, sortId: id));
      preferredIdPostings
          .putIfAbsent(normalizedId, () => <_WeightedPosting>[])
          .add(_WeightedPosting(entryIndex: entryIndex, weight: 20));

      final weights = <String, int>{};
      weights.update(normalizedId, (weight) => weight + 10, ifAbsent: () => 10);
      for (final tag in manifest.tags) {
        final normalizedTag = tag.toLowerCase();
        if (normalizedTag.isEmpty) continue;
        weights.update(
          normalizedTag,
          (weight) => weight + 8,
          ifAbsent: () => 8,
        );
      }
      for (final word in manifest.summary.toLowerCase().split(' ')) {
        if (word.length <= 3) continue;
        weights.update(word, (weight) => weight + 2, ifAbsent: () => 2);
      }

      for (final weightedTerm in weights.entries) {
        final posting = _WeightedPosting(
          entryIndex: entryIndex,
          weight: weightedTerm.value,
        );
        if (weightedTerm.key.isEmpty) {
          alwaysMatchedPostings.add(posting);
        } else {
          termPostings
              .putIfAbsent(weightedTerm.key, () => <_WeightedPosting>[])
              .add(posting);
        }
      }
    }

    return _LocalSkillIndexSegment(
      entries: List<_IndexedManifest>.unmodifiable(entries),
      matcher: _SubstringPostingMatcher(termPostings),
      preferredIdPostings: preferredIdPostings,
      alwaysMatchedPostings: List<_WeightedPosting>.unmodifiable(
        alwaysMatchedPostings,
      ),
    );
  }

  final List<_IndexedManifest> entries;
  final _SubstringPostingMatcher matcher;
  final Map<String, List<_WeightedPosting>> preferredIdPostings;
  final List<_WeightedPosting> alwaysMatchedPostings;
}

class _IndexedManifest {
  const _IndexedManifest({required this.manifest, required this.sortId});

  final LocalSkillManifest manifest;
  final String sortId;
}

class _WeightedPosting {
  const _WeightedPosting({required this.entryIndex, required this.weight});

  final int entryIndex;
  final int weight;
}

class _SubstringPostingMatcher {
  static const _maxPrefixLength = 16;

  _SubstringPostingMatcher(Map<String, List<_WeightedPosting>> termPostings)
    : _terms = <_IndexedTerm>[
        for (final entry in termPostings.entries)
          _IndexedTerm(
            text: entry.key,
            postings: List<_WeightedPosting>.unmodifiable(entry.value),
          ),
      ] {
    for (var termIndex = 0; termIndex < _terms.length; termIndex++) {
      final term = _terms[termIndex].text;
      final width = term.length < _maxPrefixLength
          ? term.length
          : _maxPrefixLength;
      _prefixBuckets[width - 1]
          .putIfAbsent(term.substring(0, width), () => <int>[])
          .add(termIndex);
    }
  }

  final List<_IndexedTerm> _terms;
  final List<Map<String, List<int>>> _prefixBuckets =
      List<Map<String, List<int>>>.generate(
        _maxPrefixLength,
        (_) => <String, List<int>>{},
        growable: false,
      );

  ({int bucketProbes, int candidateTermChecks}) scan(
    String query,
    void Function(List<_WeightedPosting> postings) onMatchedTerm,
  ) {
    if (_terms.isEmpty || query.isEmpty) {
      return (bucketProbes: 0, candidateTermChecks: 0);
    }
    final seenTerms = <int>{};
    var bucketProbes = 0;
    var candidateTermChecks = 0;
    final maxWidth = query.length < _maxPrefixLength
        ? query.length
        : _maxPrefixLength;
    for (var width = 1; width <= maxWidth; width++) {
      final buckets = _prefixBuckets[width - 1];
      if (buckets.isEmpty) continue;
      for (var start = 0; start <= query.length - width; start++) {
        bucketProbes++;
        final candidates = buckets[query.substring(start, start + width)];
        if (candidates == null) continue;
        for (final termIndex in candidates) {
          if (!seenTerms.add(termIndex)) continue;
          candidateTermChecks++;
          final term = _terms[termIndex];
          if (query.contains(term.text)) {
            onMatchedTerm(term.postings);
          }
        }
      }
    }
    return (
      bucketProbes: bucketProbes,
      candidateTermChecks: candidateTermChecks,
    );
  }
}

class _IndexedTerm {
  const _IndexedTerm({required this.text, required this.postings});

  final String text;
  final List<_WeightedPosting> postings;
}

class _ScoredManifest {
  const _ScoredManifest({required this.entry, required this.score});

  final _IndexedManifest entry;
  final int score;
}

class _BoundedTopK {
  _BoundedTopK(this.capacity);

  final int capacity;
  final List<_ScoredManifest> _heap = <_ScoredManifest>[];

  void add(_ScoredManifest candidate) {
    if (capacity == 0) return;
    if (_heap.length < capacity) {
      _heap.add(candidate);
      _siftUp(_heap.length - 1);
      return;
    }
    if (_compareBestFirst(candidate, _heap.first) >= 0) return;
    _heap[0] = candidate;
    _siftDown(0);
  }

  List<_ScoredManifest> toBestFirstList() =>
      <_ScoredManifest>[..._heap]..sort(_compareBestFirst);

  void _siftUp(int index) {
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (!_isWorse(_heap[index], _heap[parent])) return;
      _swap(index, parent);
      index = parent;
    }
  }

  void _siftDown(int index) {
    while (true) {
      final left = index * 2 + 1;
      if (left >= _heap.length) return;
      final right = left + 1;
      var worseChild = left;
      if (right < _heap.length && _isWorse(_heap[right], _heap[left])) {
        worseChild = right;
      }
      if (!_isWorse(_heap[worseChild], _heap[index])) return;
      _swap(index, worseChild);
      index = worseChild;
    }
  }

  void _swap(int first, int second) {
    final value = _heap[first];
    _heap[first] = _heap[second];
    _heap[second] = value;
  }
}

int _compareBestFirst(_ScoredManifest first, _ScoredManifest second) {
  final byScore = second.score.compareTo(first.score);
  if (byScore != 0) return byScore;
  return first.entry.sortId.compareTo(second.entry.sortId);
}

bool _isWorse(_ScoredManifest first, _ScoredManifest second) =>
    _compareBestFirst(first, second) > 0;
