import 'dart:async';
import 'dart:collection';

import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';

typedef LocalizedMarketplaceSkillLoader =
    Future<MarketplaceSkill> Function(String skillVersionId);

/// Refreshes the server-selected locale projection of installed Marketplace
/// Skills without changing installation identity or learned mastery.
///
/// The Marketplace owns the distinction between localizable official content
/// and author-authored content. Author Skills therefore round-trip unchanged,
/// while official/seed Skills can return a different localized projection.
class InstalledSkillLocaleRefresher {
  const InstalledSkillLocaleRefresher({
    required InstalledSkillRegistry registry,
    required LocalizedMarketplaceSkillLoader loadSkill,
  }) : _registry = registry,
       _loadSkill = loadSkill;

  final InstalledSkillRegistry _registry;
  final LocalizedMarketplaceSkillLoader _loadSkill;

  Future<InstalledSkillLocaleRefreshResult> refreshForAgent(
    String agentId, {
    required AppLocale expectedLocale,
    bool Function()? shouldApply,
  }) async {
    final canApply = shouldApply ?? () => true;
    final cards = await _registry.installedForAgent(agentId);
    var refreshedCount = 0;
    final failures = <int, Object>{};
    var superseded = false;

    for (final card in cards) {
      if (!canApply()) {
        superseded = true;
        break;
      }
      final current = card.skill;
      try {
        final refreshed = await _loadSkill(current.skillVersionId.toString());
        if (refreshed.skillVersionId != current.skillVersionId ||
            refreshed.skillKey != current.skillKey) {
          throw StateError(
            'Localized Skill identity does not match the installed Skill',
          );
        }
        if (refreshed.requiresLocalizedPromptContent &&
            refreshed.contentLocale != expectedLocale.code) {
          throw StateError(
            'Localized Skill response does not match the requested locale',
          );
        }
        if (!canApply()) {
          superseded = true;
          break;
        }
        await _registry.upsert(
          agentId: agentId,
          skill: refreshed,
          mastery: card.mastery,
        );
        refreshedCount += 1;
      } catch (error) {
        // Keep the last sanitized card so a locale change cannot remove an
        // offline-capable Skill when the network is unavailable.
        failures[current.skillVersionId] = error;
      }
    }

    return InstalledSkillLocaleRefreshResult(
      refreshedCount: refreshedCount,
      failures: failures,
      superseded: superseded,
    );
  }
}

class InstalledSkillLocaleRefreshResult {
  InstalledSkillLocaleRefreshResult({
    required this.refreshedCount,
    required Map<int, Object> failures,
    this.superseded = false,
  }) : failures = UnmodifiableMapView(failures);

  final int refreshedCount;
  final Map<int, Object> failures;
  final bool superseded;

  bool get hasFailures => failures.isNotEmpty;
}

/// Serializes locale refreshes and invalidates work queued or in-flight before
/// a newer language selection.
class InstalledSkillLocaleRefreshQueue {
  int _generation = 0;
  Future<void> _tail = Future<void>.value();

  /// Makes queued and in-flight refreshes ineligible to update runtime state.
  void invalidate() {
    _generation += 1;
  }

  Future<void> run({
    required Future<void> Function(bool Function() isCurrent) beforeWait,
    required Future<void> Function(bool Function() isCurrent) operation,
  }) async {
    final generation = ++_generation;
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    bool isCurrent() => generation == _generation;

    try {
      // Update the runtime from the locale-filtered cache immediately, before
      // an older network refresh releases the serial queue.
      await beforeWait(isCurrent);
      if (!isCurrent()) return;
      await previous;
      if (!isCurrent()) return;
      await operation(isCurrent);
    } finally {
      gate.complete();
    }
  }
}
