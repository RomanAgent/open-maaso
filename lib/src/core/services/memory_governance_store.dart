import 'package:sembast/sembast.dart';

/// Private, account-local stores used by the Memory v2 write boundary.
///
/// Episode payloads remain append-only. Mutable lifecycle facts such as
/// "current revision" and derived-projection receipts live in sidecars so a
/// rollback can ignore them without having to rewrite the canonical Episode
/// codec.
abstract final class MemoryGovernanceStores {
  static final episodes = intMapStoreFactory.store('episodes');
  static final chatMessages = intMapStoreFactory.store('chat_messages');
  static final exactDedup = StoreRef<String, Map<String, Object?>>(
    'memory_exact_dedup.v1',
  );
  static final semanticDedup = StoreRef<String, Map<String, Object?>>(
    'memory_semantic_dedup.v1',
  );
  static final claimHeads = StoreRef<String, Map<String, Object?>>(
    'memory_claim_heads.v1',
  );
  static final episodeGovernance = StoreRef<int, Map<String, Object?>>(
    'memory_episode_governance.v1',
  );
  static final governedProjections = StoreRef<int, Map<String, Object?>>(
    'memory_governed_projections.v1',
  );
  static final governedProjectionHeads = StoreRef<String, Map<String, Object?>>(
    'memory_governed_projection_heads.v1',
  );
  static final governedProjectionRollbackOverrides =
      StoreRef<String, Map<String, Object?>>(
        'memory_governed_projection_rollback_overrides.v1',
      );
  static final revisionHeads = StoreRef<int, Map<String, Object?>>(
    'memory_revision_heads.v1',
  );
  static final episodeRecallIndex = StoreRef<int, Map<String, Object?>>(
    'memory_episode_recall_index.v1',
  );
  static final episodeEmbeddingSpaces = StoreRef<int, Map<String, Object?>>(
    'memory_episode_embedding_spaces.v1',
  );
  static final episodeRecallIndexState = StoreRef<String, Map<String, Object?>>(
    'memory_episode_recall_index_state.v1',
  );
  static final sourceMaterial = StoreRef<String, Map<String, Object?>>(
    'memory_source_material.v1',
  );
  static final legacyFactMigrations = StoreRef<String, Map<String, Object?>>(
    'memory_legacy_fact_migrations.v1',
  );
  static final legacyFactMigrationState =
      StoreRef<String, Map<String, Object?>>(
        'memory_legacy_fact_migration_state.v1',
      );
  static final audit = intMapStoreFactory.store('memory_write_audit.v1');
}
