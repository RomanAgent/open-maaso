import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/capability/capability.dart';

/// Pluggable capability matcher. Keyword scoring today; Phase 2 swaps in an
/// embedding implementation behind this same interface.
abstract class CapabilitySearch {
  List<Capability> search(
    String query,
    List<Capability> pool, {
    int maxResults,
  });
}

/// Keyword/id/description scoring, mirroring [LocalSkillRetriever]'s scheme so
/// both behave consistently.
class KeywordCapabilitySearch implements CapabilitySearch {
  const KeywordCapabilitySearch();

  @override
  List<Capability> search(
    String query,
    List<Capability> pool, {
    int maxResults = 6,
  }) {
    final q = query.toLowerCase();
    final scored = <({Capability cap, int score})>[];
    for (final cap in pool) {
      var score = 0;
      // fires when the user/LLM types the exact id string (e.g. "nav.settings")
      if (q.contains(cap.id.toLowerCase())) score += 10;
      for (final kw in cap.keywords) {
        final k = kw.toLowerCase();
        if (k.isNotEmpty && q.contains(k)) score += 8;
      }
      for (final word in cap.description.toLowerCase().split(' ')) {
        if (word.length > 3 && q.contains(word)) score += 2;
      }
      if (score > 0) scored.add((cap: cap, score: score));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.cap.id.compareTo(b.cap.id);
    });
    return [for (final s in scored.take(maxResults)) s.cap];
  }
}

/// Single source of truth for agent-invocable capabilities. Registered at boot;
/// providers (navigation now, page actions later) register into it.
class CapabilityRegistry extends AppService {
  CapabilityRegistry({
    CapabilitySearch searcher = const KeywordCapabilitySearch(),
  }) : _search = searcher;

  final CapabilitySearch _search;
  final List<Capability> _caps = [];

  void register(Capability cap) => _caps.add(cap);
  void registerAll(Iterable<Capability> caps) => _caps.addAll(caps);

  List<Capability> get all => List.unmodifiable(_caps);

  Capability? byId(String id) {
    for (final c in _caps) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<Capability> byKind(CapabilityKind kind) =>
      _caps.where((c) => c.kind == kind).toList();

  List<Capability> search(String query, {int maxResults = 6}) =>
      _search.search(query, _caps, maxResults: maxResults);
}
