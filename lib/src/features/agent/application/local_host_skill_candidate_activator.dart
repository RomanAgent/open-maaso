import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

/// Caches local-safe catalog metadata and materializes only retrieved hosts.
///
/// Constructing this catalog never calls a Skill factory. Activated instances
/// are cached per owning agent and can be registered into a fresh turn-local
/// [SkillManager] without rebuilding unrelated hosts.
class LocalHostSkillCandidateActivator {
  factory LocalHostSkillCandidateActivator({
    required String agentId,
    required Iterable<SkillSpec> specs,
    AppCapabilitySnapshotService? capabilitySnapshotService,
  }) {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty) {
      throw ArgumentError.value(agentId, 'agentId', 'must not be empty');
    }

    final registrations = <String, _LocalHostRegistration>{};
    final manifests = <LocalSkillManifest>[];
    final manifestIds = <String>{};
    for (final spec in specs) {
      final manifest = spec.localManifest;
      final factory = spec.factory;
      if (manifest == null || !manifest.localEligible) continue;
      if (spec.isComingSoon || factory == null) {
        throw StateError('local_manifest_without_factory:${spec.id}');
      }
      if (!manifestIds.add(manifest.id)) {
        throw StateError('duplicate_local_manifest_id:${manifest.id}');
      }
      if (registrations.containsKey(manifest.skillName)) {
        throw StateError('duplicate_local_skill:${manifest.skillName}');
      }
      manifests.add(manifest);
      registrations[manifest.skillName] = _LocalHostRegistration(
        catalogId: spec.id,
        manifest: manifest,
        factory: factory,
        availability: () => spec.isAvailable,
      );
    }
    return LocalHostSkillCandidateActivator._(
      agentId: normalizedAgentId,
      manifests: List<LocalSkillManifest>.unmodifiable(manifests),
      registrations: Map<String, _LocalHostRegistration>.unmodifiable(
        registrations,
      ),
      capabilitySnapshotService:
          capabilitySnapshotService ??
          appServices.maybeFind<AppCapabilitySnapshotService>(),
    );
  }

  LocalHostSkillCandidateActivator._({
    required this.agentId,
    required this.manifests,
    required Map<String, _LocalHostRegistration> registrations,
    required AppCapabilitySnapshotService? capabilitySnapshotService,
  }) : _registrations = registrations,
       _capabilitySnapshotService = capabilitySnapshotService;

  final String agentId;
  final List<LocalSkillManifest> manifests;
  final Map<String, _LocalHostRegistration> _registrations;
  final AppCapabilitySnapshotService? _capabilitySnapshotService;
  final Map<String, AgentSkill> _active = <String, AgentSkill>{};
  AgentSkill? _navigationSkill;
  int _availabilityGeneration = 0;
  Set<String> _availableSkillNames = const <String>{};
  String? _capabilitySnapshotCacheKey;

  int get activeCount => _active.length + (_navigationSkill == null ? 0 : 1);

  int get availabilityGeneration => _availabilityGeneration;

  Set<AppCapabilityKey>? capabilityKeysFor(LocalSkillManifest manifest) {
    final registration = _registrationFor(manifest);
    return registration == null
        ? null
        : Set<AppCapabilityKey>.unmodifiable(<AppCapabilityKey>{
            AppCapabilityKey.skill(registration.catalogId),
          });
  }

  bool isManifestAvailable(LocalSkillManifest manifest) {
    synchronizeAvailability();
    final registration = _registrationFor(manifest);
    if (registration == null ||
        !_availableSkillNames.contains(manifest.skillName)) {
      return false;
    }
    AppCapabilitySnapshot? snapshot;
    try {
      final service = _capabilitySnapshotService;
      if (service?.isClosed == true) return false;
      snapshot = service?.value;
    } catch (_) {
      return false;
    }
    return _isRegistrationAvailable(registration, snapshot);
  }

  List<LocalSkillManifest> get availableManifests {
    synchronizeAvailability();
    return List<LocalSkillManifest>.unmodifiable(
      manifests.where(
        (manifest) => _availableSkillNames.contains(manifest.skillName),
      ),
    );
  }

  bool synchronizeAvailability() {
    final service = _capabilitySnapshotService;
    AppCapabilitySnapshot? snapshot;
    String? nextCapabilitySnapshotCacheKey;
    if (service != null) {
      try {
        if (service.isClosed) {
          nextCapabilitySnapshotCacheKey = 'closed';
        } else {
          snapshot = service.value;
          nextCapabilitySnapshotCacheKey = snapshot.cacheKey;
        }
      } catch (_) {
        nextCapabilitySnapshotCacheKey = 'unavailable';
      }
    }
    final next = <String>{
      for (final entry in _registrations.entries)
        if (_isRegistrationAvailable(entry.value, snapshot)) entry.key,
    };
    final capabilityChanged =
        _capabilitySnapshotCacheKey != nextCapabilitySnapshotCacheKey;
    if (!capabilityChanged && _sameSet(_availableSkillNames, next)) {
      return false;
    }
    _availableSkillNames = Set<String>.unmodifiable(next);
    _capabilitySnapshotCacheKey = nextCapabilitySnapshotCacheKey;
    _active.removeWhere((name, _) => !next.contains(name));
    _availabilityGeneration += 1;
    return true;
  }

  /// Builds a manager containing only unique hosts represented by [candidates].
  SkillManager activateCandidates(
    Iterable<LocalSkillManifest> candidates, {
    AgentSkill Function()? navigationFactory,
  }) {
    synchronizeAvailability();
    final manager = SkillManager();
    final seen = <String>{};
    for (final candidate in candidates) {
      final skillName = candidate.skillName;
      if (!seen.add(skillName)) continue;

      final registration = _registrations[skillName];
      final snapshot = _capabilitySnapshotService?.value;
      if (registration != null &&
          _availableSkillNames.contains(skillName) &&
          _isRegistrationAvailable(registration, snapshot)) {
        final skill = _active.putIfAbsent(
          skillName,
          () => _createAndValidate(registration),
        );
        manager.registerSkill(skill);
        continue;
      }

      if (skillName == 'AppNavigate' && navigationFactory != null) {
        final skill = _navigationSkill ??= navigationFactory();
        if (skill.skillName != skillName) {
          _navigationSkill = null;
          throw StateError(
            'local_navigation_skill_name_mismatch:$skillName:'
            '${skill.skillName}',
          );
        }
        manager.registerSkill(skill);
      }
    }
    return manager;
  }

  bool _isRegistrationAvailable(
    _LocalHostRegistration registration,
    AppCapabilitySnapshot? snapshot,
  ) {
    if (!registration.isAvailable) return false;
    if (_capabilitySnapshotService == null) return true;
    if (snapshot == null) return false;
    return snapshot.allows(
      AppCapabilityKey.skill(registration.catalogId),
      requireVisible: true,
    );
  }

  _LocalHostRegistration? _registrationFor(LocalSkillManifest manifest) {
    final registration = _registrations[manifest.skillName];
    if (registration == null || registration.manifest.id != manifest.id) {
      return null;
    }
    return registration;
  }

  AgentSkill _createAndValidate(_LocalHostRegistration registration) {
    final skill = registration.factory(agentId);
    if (skill.skillName != registration.manifest.skillName) {
      throw StateError(
        'local_skill_name_mismatch:${registration.catalogId}:'
        '${registration.manifest.skillName}:${skill.skillName}',
      );
    }
    if (!skill.methods.containsKey(registration.manifest.method)) {
      throw StateError(
        'local_skill_method_mismatch:${registration.catalogId}:'
        '${registration.manifest.method}',
      );
    }
    return skill;
  }
}

class _LocalHostRegistration {
  const _LocalHostRegistration({
    required this.catalogId,
    required this.manifest,
    required this.factory,
    required this.availability,
  });

  final String catalogId;
  final LocalSkillManifest manifest;
  final AgentSkill Function(String agentId) factory;
  final bool Function()? availability;

  bool get isAvailable {
    final predicate = availability;
    if (predicate == null) return true;
    try {
      return predicate();
    } on Object {
      return false;
    }
  }
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
