import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/learned_skill.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/learned_skill_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/installed_prompt_skill_adapter.dart';
import 'package:maaso/src/features/agent/application/skill_routing/learned_prompt_skill_adapter.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';

typedef InstalledSkillCardLoader =
    Future<List<InstalledSkillCard>> Function(String agentId);

class PromptSkillCatalogUpdate {
  const PromptSkillCatalogUpdate({
    required this.agentId,
    required this.snapshot,
  });

  final String agentId;
  final PromptSkillSnapshot snapshot;
}

/// Owns immutable prompt-only Skill snapshots outside the first-turn path.
///
/// [snapshotForAgent] is synchronous O(1). Disk reads and full-catalog
/// projection happen only in [warmAgent]/[refreshInstalled], and callers may
/// start those operations without awaiting them. Learned Skill mutations are
/// observed through their existing [RxList] and atomically replace snapshots.
class PromptSkillCatalogService extends AppService {
  PromptSkillCatalogService({
    required LearnedSkillService learnedSkills,
    required InstalledSkillCardLoader loadInstalled,
    InstalledPromptSkillAdapter installedAdapter =
        const InstalledPromptSkillAdapter(),
    LearnedPromptSkillAdapter learnedAdapter =
        const LearnedPromptSkillAdapter(),
  }) : _learnedSkills = learnedSkills,
       _loadInstalled = loadInstalled,
       _installedAdapter = installedAdapter,
       _learnedAdapter = learnedAdapter;

  final LearnedSkillService _learnedSkills;
  final InstalledSkillCardLoader _loadInstalled;
  final InstalledPromptSkillAdapter _installedAdapter;
  final LearnedPromptSkillAdapter _learnedAdapter;
  final Map<String, PromptSkillSnapshot> _installedByAgent = {};
  final Map<String, AppLocale> _installedLocaleByAgent = {};
  final Map<String, PromptSkillSnapshot> _combinedByAgent = {};
  final Map<String, int> _refreshGenerationByAgent = {};
  final Map<String, Future<PromptSkillSnapshot>> _warmups = {};
  final Set<String> _knownAgentIds = {};
  final StreamController<PromptSkillCatalogUpdate> _updates =
      StreamController<PromptSkillCatalogUpdate>.broadcast(sync: true);

  PromptSkillSnapshot _learnedSnapshot = PromptSkillSnapshot.empty;
  AppLocale _locale = AgentPromptCatalog.currentLocale;
  int _localeGeneration = 0;
  Worker? _learnedWorker;

  Stream<PromptSkillCatalogUpdate> get updates => _updates.stream;

  @override
  void onInit() {
    super.onInit();
    _replaceLearned(_learnedSkills.skills.value);
    _learnedWorker = ever<List<LearnedSkill>>(
      _learnedSkills.skills,
      _replaceLearned,
    );
  }

  PromptSkillSnapshot snapshotForAgent(String agentId) {
    final id = agentId.trim();
    if (id.isEmpty) return _learnedSnapshot;
    _knownAgentIds.add(id);
    return _combinedByAgent[id] ?? _learnedSnapshot;
  }

  Future<PromptSkillSnapshot> warmAgent(
    String agentId, {
    required AppLocale locale,
  }) {
    final id = _requiredAgentId(agentId);
    if (_installedLocaleByAgent[id] == locale) {
      return Future<PromptSkillSnapshot>.value(snapshotForAgent(id));
    }
    final key = '$id|${locale.name}';
    return _warmups[key] ??= _runWarm(id, locale, key);
  }

  Future<PromptSkillSnapshot> _runWarm(
    String agentId,
    AppLocale locale,
    String key,
  ) async {
    try {
      return await refreshInstalled(agentId, locale: locale);
    } finally {
      _warmups.remove(key);
    }
  }

  Future<PromptSkillSnapshot> refreshInstalled(
    String agentId, {
    required AppLocale locale,
    bool Function()? shouldApply,
  }) async {
    final id = _requiredAgentId(agentId);
    _knownAgentIds.add(id);
    _setLocale(locale);
    final localeGeneration = _localeGeneration;
    final generation = (_refreshGenerationByAgent[id] ?? 0) + 1;
    _refreshGenerationByAgent[id] = generation;
    final cards = await _loadInstalled(id);
    if (_refreshGenerationByAgent[id] != generation ||
        _localeGeneration != localeGeneration ||
        _locale != locale ||
        shouldApply?.call() == false) {
      return snapshotForAgent(id);
    }

    final installed = _installedAdapter.project(cards, locale: locale);
    _installedByAgent[id] = installed;
    _installedLocaleByAgent[id] = locale;
    return _storeCombined(id, notify: true);
  }

  /// Drops only installed Marketplace entries. Learned entries remain usable.
  /// The replacement and update notification are synchronous.
  PromptSkillSnapshot invalidateInstalled(String agentId) {
    final id = _requiredAgentId(agentId);
    _knownAgentIds.add(id);
    _refreshGenerationByAgent[id] = (_refreshGenerationByAgent[id] ?? 0) + 1;
    _installedByAgent.remove(id);
    _installedLocaleByAgent.remove(id);
    return _storeCombined(id, notify: true);
  }

  void refreshLearned() => _replaceLearned(_learnedSkills.skills.value);

  void _setLocale(AppLocale locale) {
    if (_locale == locale) return;
    _locale = locale;
    _localeGeneration++;
    _installedByAgent.clear();
    _installedLocaleByAgent.clear();
    _learnedSnapshot = _learnedAdapter.project(
      _learnedSkills.skills.value,
      locale: _locale,
    );
    for (final agentId in _knownAgentIds.toList(growable: false)) {
      _refreshGenerationByAgent[agentId] =
          (_refreshGenerationByAgent[agentId] ?? 0) + 1;
      _storeCombined(agentId, notify: true);
    }
  }

  void _replaceLearned(List<LearnedSkill> skills) {
    final next = _learnedAdapter.project(skills, locale: _locale);
    if (next.revision == _learnedSnapshot.revision) return;
    _learnedSnapshot = next;
    for (final agentId in _knownAgentIds.toList(growable: false)) {
      _storeCombined(agentId, notify: true);
    }
  }

  PromptSkillSnapshot _storeCombined(String agentId, {required bool notify}) {
    final next = PromptSkillSnapshot.merge(<PromptSkillSnapshot>[
      ?_installedByAgent[agentId],
      _learnedSnapshot,
    ]);
    final previous = _combinedByAgent[agentId];
    _combinedByAgent[agentId] = next;
    if (notify && previous?.revision != next.revision) {
      _updates.add(PromptSkillCatalogUpdate(agentId: agentId, snapshot: next));
    }
    return next;
  }

  String _requiredAgentId(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(agentId, 'agentId', 'must not be empty');
    }
    return normalized;
  }

  @override
  void onClose() {
    _learnedWorker?.dispose();
    unawaited(_updates.close());
    super.onClose();
  }
}
