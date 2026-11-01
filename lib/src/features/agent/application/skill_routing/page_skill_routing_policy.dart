import 'dart:collection';

import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_page_scope.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';

/// Immutable, metadata-only routing prior for one canonical page scope.
///
/// [preferredHostSkillIds] is deliberately not an execution grant. A caller
/// must first route the user's text, then pass the router's lexical matches to
/// [eligiblePreferredHostSkillIds]. This prevents merely opening a page from
/// authorizing or activating a Host Skill.
class PageSkillRoutingPrior {
  factory PageSkillRoutingPrior({
    required String pageScope,
    required Iterable<String> preferredHostSkillIds,
    int activationBudget = 1,
    double minimumIntentConfidence = 0.52,
  }) {
    final normalizedScope = _normalizeScope(pageScope);
    if (normalizedScope.isEmpty) {
      throw ArgumentError.value(
        pageScope,
        'pageScope',
        'must be a canonical page scope',
      );
    }
    if (activationBudget <= 0 || activationBudget > maxConfiguredHostSkillIds) {
      throw ArgumentError.value(
        activationBudget,
        'activationBudget',
        'must be between 1 and $maxConfiguredHostSkillIds',
      );
    }
    if (minimumIntentConfidence < 0 || minimumIntentConfidence > 1) {
      throw ArgumentError.value(
        minimumIntentConfidence,
        'minimumIntentConfidence',
        'must be between 0 and 1',
      );
    }

    final ids = <String>[];
    final normalizedIds = <String>{};
    for (final value in preferredHostSkillIds) {
      final id = value.trim();
      final normalizedId = SkillLexicalText.normalize(id);
      if (id.isEmpty || normalizedId.isEmpty) {
        throw ArgumentError.value(
          value,
          'preferredHostSkillIds',
          'must contain non-empty descriptor ids',
        );
      }
      if (normalizedIds.add(normalizedId)) ids.add(id);
    }
    if (ids.isEmpty || ids.length > maxConfiguredHostSkillIds) {
      throw ArgumentError.value(
        ids,
        'preferredHostSkillIds',
        'must contain 1-$maxConfiguredHostSkillIds unique ids',
      );
    }

    return PageSkillRoutingPrior._(
      pageScope: normalizedScope,
      preferredHostSkillIds: List<String>.unmodifiable(ids),
      activationBudget: activationBudget,
      minimumIntentConfidence: minimumIntentConfidence,
    );
  }

  const PageSkillRoutingPrior._({
    required this.pageScope,
    required this.preferredHostSkillIds,
    required this.activationBudget,
    required this.minimumIntentConfidence,
  });

  static const int maxConfiguredHostSkillIds = 3;

  static const none = PageSkillRoutingPrior._(
    pageScope: '',
    preferredHostSkillIds: <String>[],
    activationBudget: 0,
    minimumIntentConfidence: 1,
  );

  final String pageScope;

  /// Ordered candidate ids. These are hints only, never an allowlist.
  final List<String> preferredHostSkillIds;

  /// Maximum number of evidence-backed page candidates a caller may retain.
  /// The policy itself never activates a factory.
  final int activationBudget;

  /// Minimum lexical router confidence required before a page hint is usable.
  final double minimumIntentConfidence;

  bool get isEmpty => preferredHostSkillIds.isEmpty;

  /// Returns page candidates that already have lexical evidence from Router.
  ///
  /// Output follows the configured page-prior order, is deduplicated, and is
  /// capped by [activationBudget]. It remains routing metadata: a separate,
  /// turn-scoped executable grant must still be issued by the Host registry.
  List<String> eligiblePreferredHostSkillIds(
    Iterable<SkillRouteMatch> lexicalMatches,
  ) {
    if (isEmpty) return const <String>[];
    final eligibleIds = <String>{};
    for (final match in lexicalMatches) {
      if (match.confidence < minimumIntentConfidence) continue;
      eligibleIds.add(SkillLexicalText.normalize(match.descriptor.id));
    }
    if (eligibleIds.isEmpty) return const <String>[];

    final selected = <String>[];
    for (final id in preferredHostSkillIds) {
      if (!eligibleIds.contains(SkillLexicalText.normalize(id))) continue;
      selected.add(id);
      if (selected.length >= activationBudget) break;
    }
    return List<String>.unmodifiable(selected);
  }

  static final RegExp _canonicalScope = RegExp(
    r'^[a-z0-9]+(?:[._][a-z0-9]+)*$',
  );

  static String _normalizeScope(String value) {
    final normalized = value.trim().toLowerCase();
    return _canonicalScope.hasMatch(normalized) ? normalized : '';
  }
}

/// Bounded built-in Host Skill priors for known, currently navigable pages.
///
/// The table is intentionally small and does not mirror the full skill
/// catalog. Entries correspond to current [SkillPageScope] values.
class PageSkillRoutingPolicy {
  factory PageSkillRoutingPolicy(Iterable<PageSkillRoutingPrior> priors) {
    final byScope = <String, PageSkillRoutingPrior>{};
    for (final prior in priors) {
      if (prior.isEmpty) {
        throw ArgumentError.value(prior, 'priors', 'must not contain none');
      }
      if (byScope.containsKey(prior.pageScope)) {
        throw ArgumentError('Duplicate page skill scope: ${prior.pageScope}');
      }
      byScope[prior.pageScope] = prior;
    }
    return PageSkillRoutingPolicy._(
      Map<String, PageSkillRoutingPrior>.unmodifiable(byScope),
    );
  }

  const PageSkillRoutingPolicy._(this._byScope);

  static final PageSkillRoutingPolicy defaults = PageSkillRoutingPolicy(
    <PageSkillRoutingPrior>[
      PageSkillRoutingPrior(
        pageScope: 'widgets_hub',
        preferredHostSkillIds: <String>['AppletDiscovery'],
      ),
      PageSkillRoutingPrior(
        pageScope: 'game_feed',
        preferredHostSkillIds: <String>['AppletDiscovery'],
      ),
    ],
  );

  final Map<String, PageSkillRoutingPrior> _byScope;

  List<String> get supportedPageScopes =>
      List<String>.unmodifiable(_byScope.keys);

  PageSkillRoutingPrior forRoute(String route) {
    final scope = SkillPageScope.fromRoute(route);
    return scope == null ? PageSkillRoutingPrior.none : forScope(scope);
  }

  PageSkillRoutingPrior forScope(String? pageScope) {
    final normalized = PageSkillRoutingPrior._normalizeScope(pageScope ?? '');
    return _byScope[normalized] ?? PageSkillRoutingPrior.none;
  }

  Map<String, PageSkillRoutingPrior> get snapshot =>
      UnmodifiableMapView<String, PageSkillRoutingPrior>(_byScope);
}
