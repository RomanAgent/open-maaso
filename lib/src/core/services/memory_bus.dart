import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/entangled_memory_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_recall_safety_gate.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/working_memory.dart';
import 'package:maaso/src/core/services/world_kb_service.dart';

class MemoryBus extends AppService {
  MemoryBus({
    FeatureRolloutMode Function()? memoryV2Mode,
    MemoryRecallSafetyGate? recallSafetyGate,
  }) : _memoryV2ModeOverride = memoryV2Mode,
       _recallSafetyGateOverride = recallSafetyGate;

  final FeatureRolloutMode Function()? _memoryV2ModeOverride;
  final MemoryRecallSafetyGate? _recallSafetyGateOverride;
  MemoryRecallSafetyGate? _fallbackRecallSafetyGate;

  SoulService get _soul => appServices.find<SoulService>();
  MasterProfileService get _master => appServices.find<MasterProfileService>();
  WorldKBService get _world => appServices.find<WorldKBService>();
  EpisodeStore get _episodes => appServices.find<EpisodeStore>();
  WorkingMemory get _l0 => appServices.find<WorkingMemory>();
  ShortTermMemory get _l1 => appServices.find<ShortTermMemory>();

  String l0Block({AppLocale? locale}) => _l0.toContextBlock(locale: locale);

  String l1Block({AppLocale? locale}) => _l1.toContextBlock(locale: locale);

  String l3Block({AppLocale? locale}) {
    final parts = <String>[];
    parts.add(_soulPromptBlock(locale: locale));
    if (_master.hasAnything) parts.add(_masterPromptBlock(locale: locale));
    if (_world.hasAnything) parts.add(_worldPromptBlock(locale: locale));
    return parts.join('\n');
  }

  /// Portable/export view. Account-owned Master Profile data is excluded by
  /// default so AgentGene compression cannot disclose it to another agent or
  /// an external compression provider without a future explicit-consent API.
  String exportableL3Block({AppLocale? locale}) {
    final parts = <String>[_soulPromptBlock(locale: locale)];
    if (_world.hasAnything) parts.add(_worldPromptBlock(locale: locale));
    return parts.join('\n');
  }

  Future<String> l2Recall(String query, {int k = 5, AppLocale? locale}) async {
    final result = await l2RecallResult(query, k: k, locale: locale);
    return result.promptBlock;
  }

  /// Typed L2 result for runtime observability. The string facade remains for
  /// existing non-runtime consumers, but timeout/failure must not collapse
  /// into an ordinary empty recall on the turn path.
  Future<MemoryRecallResult> l2RecallResult(
    String query, {
    int k = 5,
    AppLocale? locale,
  }) async {
    final result = await _recallSafetyGate.recall(query, k: k, locale: locale);
    TurnTrace.event(
      'memory.l2.gate',
      details:
          'status=${result.status.name} '
          'latency=${_latencyBucket(result.elapsed)} '
          'direct=${result.directCount} entangled=${result.entangledCount}',
    );
    return result;
  }

  MemoryRecallSafetyGate get _recallSafetyGate {
    final override = _recallSafetyGateOverride;
    if (override != null) return override;
    final registered = appServices.maybeFind<MemoryRecallSafetyGate>();
    if (registered != null) return registered;
    return _fallbackRecallSafetyGate ??= MemoryRecallSafetyGate(
      episodeStore: _episodes,
      entangledMemory: appServices.maybeFind<EntangledMemoryService>(),
    );
  }

  String fullContextBlock(String query, {AppLocale? locale}) {
    final parts = <String>[];
    final l0 = l0Block(locale: locale);
    if (l0.isNotEmpty) parts.add(l0);
    final l1 = l1Block(locale: locale);
    if (l1.isNotEmpty) parts.add(l1);
    return parts.join('\n\n');
  }

  String _soulPromptBlock({AppLocale? locale}) {
    final notes = _soul.notes.value.trim();
    return <String>[
      AgentPromptCatalog.text('app.memory.soul.header', locale: locale),
      '',
      AgentPromptCatalog.text(
        'app.memory.soul.name',
        locale: locale,
        params: <String, Object?>{'value': _soul.name.value ?? ''},
      ),
      AgentPromptCatalog.text(
        'app.memory.soul.age',
        locale: locale,
        params: <String, Object?>{'value': _soul.age.value ?? ''},
      ),
      AgentPromptCatalog.text(
        'app.memory.soul.gender',
        locale: locale,
        params: <String, Object?>{'value': _soul.gender.value ?? ''},
      ),
      '',
      AgentPromptCatalog.text('app.memory.notes.header', locale: locale),
      notes.isEmpty
          ? AgentPromptCatalog.text('app.memory.notes.empty', locale: locale)
          : notes,
    ].join('\n');
  }

  String _masterPromptBlock({AppLocale? locale}) {
    return <String>[
      AgentPromptCatalog.text('app.memory.master.header', locale: locale),
      '',
      _master.toPromptDataBlock(),
    ].join('\n');
  }

  String _worldPromptBlock({AppLocale? locale}) {
    return <String>[
      AgentPromptCatalog.text('app.memory.world.header', locale: locale),
      '',
      _world.toPromptDataBlock(),
    ].join('\n');
  }

  Future<MemoryWriteResult> writeEpisodeWithResult(Episode e) async {
    final coordinator = appServices.maybeFind<MemoryWriteCoordinator>();
    if (coordinator != null) return coordinator.writeEpisode(e);
    if (_effectiveMemoryV2Mode() == FeatureRolloutMode.enforce) {
      return const MemoryWriteResult(
        disposition: MemoryWriteDisposition.rejected,
        episode: null,
        created: false,
        projected: false,
        reason: 'memory_write_coordinator_unavailable',
      );
    }
    await _writeLegacyEpisode(e);
    return MemoryWriteResult(
      disposition: MemoryWriteDisposition.legacy,
      episode: e,
      created: true,
      projected: true,
    );
  }

  Future<int> writeEpisode(Episode e) async {
    final result = await writeEpisodeWithResult(e);
    final id = result.episodeId;
    if (id == null) {
      throw StateError(result.reason ?? 'memory_write_rejected');
    }
    return id;
  }

  Future<MemoryWriteResult> writeImportedEpisode(
    Episode e, {
    required String sourceKind,
    required String sourceKey,
    required String canonicalMaterial,
  }) async {
    final coordinator = appServices.maybeFind<MemoryWriteCoordinator>();
    if (coordinator == null) {
      if (_effectiveMemoryV2Mode() == FeatureRolloutMode.enforce) {
        return const MemoryWriteResult(
          disposition: MemoryWriteDisposition.rejected,
          episode: null,
          created: false,
          projected: false,
          reason: 'memory_write_coordinator_unavailable',
        );
      }
      final id = await _writeLegacyEpisode(e);
      return MemoryWriteResult(
        disposition: MemoryWriteDisposition.legacy,
        episode: e..id = id,
        created: true,
        projected: true,
      );
    }
    return coordinator.writeEpisode(
      e,
      source: MemoryWriteSource.imported(
        sourceKind: sourceKind,
        sourceKey: sourceKey,
        canonicalMaterial: canonicalMaterial,
      ),
      authority: MemoryWriteAuthority.inherited,
    );
  }

  Future<int> _writeLegacyEpisode(Episode e) async {
    final id = await _episodes.addLegacy(e);
    if (appServices.isRegistered<EntangledMemoryService>()) {
      try {
        await appServices.find<EntangledMemoryService>().linkEpisode(e);
      } catch (_) {
        // The primary episode is already durable; derived links are best effort.
      }
    }
    // Keep derived account writes inside the caller's runtime operation so an
    // account teardown cannot let them resume against the next mounted graph.
    if (appServices.isRegistered<RelationshipService>()) {
      try {
        await appServices
            .find<RelationshipService>()
            .maybeAutoMilestoneFromEpisode(e);
      } catch (_) {
        // The primary episode remains valid when milestone projection fails.
      }
    }
    return id;
  }

  FeatureRolloutMode _effectiveMemoryV2Mode() {
    final override = _memoryV2ModeOverride;
    if (override != null) return override();
    return appServices.maybeFind<MaasoFeatureFlagService>()?.effectiveMode(
          MaasoFeatureFlag.memoryV2,
        ) ??
        FeatureRolloutMode.off;
  }

  Future<List<Episode>> recentEpisodes({int limit = 20}) =>
      _episodes.recent(limit: limit);

  static String _latencyBucket(Duration elapsed) {
    final milliseconds = elapsed.inMilliseconds;
    if (milliseconds < 10) return 'lt10ms';
    if (milliseconds < 25) return '10to24ms';
    if (milliseconds < 50) return '25to49ms';
    return 'gte50ms';
  }
}
