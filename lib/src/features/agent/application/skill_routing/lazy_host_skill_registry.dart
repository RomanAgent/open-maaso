import 'dart:async';

import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_skill_descriptor_factory.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

/// One exact Host tool binding authorized for a single runtime generation.
final class GrantedHostTool {
  const GrantedHostTool._({
    required this.skill,
    required this.method,
    required this.usesJsonArguments,
  });

  final AgentSkill skill;
  final String method;
  final bool usesJsonArguments;
}

/// Unforgeable, generation-bound execution authority for selected Host Skills.
///
/// Only [LazyHostSkillRegistry.issueGrant] can create a non-empty instance.
/// Router grants and prompt-only descriptors are deliberately insufficient.
final class ExecutableHostGrant {
  const ExecutableHostGrant._({
    required String? agentId,
    required _HostGrantAuthority? authority,
    required int generation,
    required List<AgentSkill> activatedSkills,
    required Set<String> allowedSkillNames,
    required Map<String, GrantedHostTool> tools,
    AppCapabilitySnapshotService? capabilitySnapshotService,
    AppCapabilitySnapshotLease? capabilitySnapshotLease,
  }) : _agentId = agentId,
       _authority = authority,
       _generation = generation,
       _activatedSkills = activatedSkills,
       _allowedSkillNames = allowedSkillNames,
       _tools = tools,
       _capabilitySnapshotService = capabilitySnapshotService,
       _capabilitySnapshotLease = capabilitySnapshotLease;

  static const none = ExecutableHostGrant._(
    agentId: null,
    authority: null,
    generation: -1,
    activatedSkills: <AgentSkill>[],
    allowedSkillNames: <String>{},
    tools: <String, GrantedHostTool>{},
  );

  final String? _agentId;
  final _HostGrantAuthority? _authority;
  final int _generation;
  final List<AgentSkill> _activatedSkills;
  final Set<String> _allowedSkillNames;
  final Map<String, GrantedHostTool> _tools;
  final AppCapabilitySnapshotService? _capabilitySnapshotService;
  final AppCapabilitySnapshotLease? _capabilitySnapshotLease;

  bool get isCurrent {
    if (_authority?.accepts(_generation) != true || _agentId == null) {
      return false;
    }
    final capabilityService = _capabilitySnapshotService;
    final capabilityLease = _capabilitySnapshotLease;
    if (capabilityService == null || capabilityLease == null) {
      return capabilityService == null && capabilityLease == null;
    }
    try {
      return capabilityService.isCurrent(capabilityLease);
    } catch (_) {
      return false;
    }
  }

  /// Sticky signal completed after this exact grant generation is revoked.
  Future<void> get whenInvalidated {
    final authority = _authority;
    if (authority == null) return Future<void>.value();
    final registryInvalidated = authority.whenInvalidated(_generation);
    final capabilityService = _capabilitySnapshotService;
    final capabilityLease = _capabilitySnapshotLease;
    if (capabilityService == null && capabilityLease == null) {
      return registryInvalidated;
    }
    if (capabilityService == null || capabilityLease == null || !isCurrent) {
      return Future<void>.value();
    }
    return Future.any<void>(<Future<void>>[
      registryInvalidated,
      capabilityLease.whenInvalidated,
    ]);
  }

  bool get isEmpty => !isCurrent || _activatedSkills.isEmpty;

  List<AgentSkill> get activatedSkills =>
      isCurrent ? _activatedSkills : const <AgentSkill>[];

  Set<String> get allowedSkillNames =>
      isCurrent ? _allowedSkillNames : const <String>{};

  String get cacheKey {
    if (!isCurrent) return 'stale';
    final names = _allowedSkillNames.toList()..sort();
    final capabilityLease = _capabilitySnapshotLease;
    if (capabilityLease == null) return '$_generation:${names.join(",")}';
    return '$_generation:${capabilityLease.cacheKey}:${names.join(",")}';
  }

  bool allowsSkillName(String skillName) =>
      isCurrent && _allowedSkillNames.contains(skillName);

  GrantedHostTool? authorize({required String agentId, required String tool}) {
    if (!isCurrent || agentId != _agentId) return null;
    return _tools[tool];
  }
}

/// Indexes executable host Skills as pure metadata and materializes only an
/// explicitly selected, enabled Skill.
class LazyHostSkillRegistry {
  factory LazyHostSkillRegistry({
    required String agentId,
    required Iterable<SkillSpec> specs,
    Set<String>? enabledSkillIds,
    AppCapabilitySnapshotService? capabilitySnapshotService,
  }) {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty) {
      throw ArgumentError.value(agentId, 'agentId', 'must not be empty');
    }

    final registrations = <_HostSkillRegistration>[];
    final catalogIds = <String>{};
    final hostNames = <String, String>{};
    final nativeTools = <String, String>{};
    final coreCatalogIds = <String>{};
    for (final spec in specs) {
      if (!catalogIds.add(spec.id)) {
        throw StateError('duplicate_host_catalog_id:${spec.id}');
      }
      final manifest = spec.hostRouting;
      final factory = spec.factory;
      if (manifest == null) continue;
      if (spec.isComingSoon || factory == null) {
        throw StateError('host_manifest_without_factory:${spec.id}');
      }
      final hostKey = manifest.skillName.toLowerCase();
      final previousHost = hostNames[hostKey];
      if (previousHost != null) {
        throw StateError(
          'duplicate_host_skill:${manifest.skillName}:$previousHost:${spec.id}',
        );
      }
      hostNames[hostKey] = spec.id;
      for (final method in manifest.methods) {
        final tool = HostSkillRoutingManifest.nativeToolName(
          manifest.skillName,
          method,
        );
        final previousTool = nativeTools[tool];
        if (previousTool != null) {
          throw StateError(
            'duplicate_host_tool:$tool:$previousTool:${spec.id}',
          );
        }
        nativeTools[tool] = spec.id;
      }
      if (spec.isCore) coreCatalogIds.add(spec.id);
      registrations.add(
        _HostSkillRegistration(
          catalogId: spec.id,
          isCore: spec.isCore,
          manifest: manifest,
          factory: factory,
          availability: spec.availability,
        ),
      );
    }

    final knownIds = registrations
        .map((registration) => registration.catalogId)
        .toSet();
    final requested = enabledSkillIds ?? knownIds;
    final resolvedCapabilitySnapshotService =
        capabilitySnapshotService ??
        appServices.maybeFind<AppCapabilitySnapshotService>();
    return LazyHostSkillRegistry._(
      agentId: normalizedAgentId,
      registrations: List<_HostSkillRegistration>.unmodifiable(registrations),
      coreCatalogIds: Set<String>.unmodifiable(coreCatalogIds),
      enabledCatalogIds: <String>{
        ...requested.where(knownIds.contains),
        ...coreCatalogIds,
      },
      capabilitySnapshotService: resolvedCapabilitySnapshotService,
    );
  }

  LazyHostSkillRegistry._({
    required this.agentId,
    required List<_HostSkillRegistration> registrations,
    required Set<String> coreCatalogIds,
    required Set<String> enabledCatalogIds,
    required AppCapabilitySnapshotService? capabilitySnapshotService,
  }) : _registrations = registrations,
       _coreCatalogIds = coreCatalogIds,
       _enabledCatalogIds = Set<String>.unmodifiable(enabledCatalogIds),
       _capabilitySnapshotService = capabilitySnapshotService,
       _bySkillName = Map<String, _HostSkillRegistration>.unmodifiable({
         for (final registration in registrations)
           registration.manifest.skillName: registration,
       });

  final String agentId;
  final List<_HostSkillRegistration> _registrations;
  final Map<String, _HostSkillRegistration> _bySkillName;
  final Set<String> _coreCatalogIds;
  final AppCapabilitySnapshotService? _capabilitySnapshotService;
  Set<String> _enabledCatalogIds;
  final Map<String, AgentSkill> _active = <String, AgentSkill>{};
  final Map<String, AgentSkill> _temporarilyUnavailable =
      <String, AgentSkill>{};
  final _HostGrantAuthority _authority = _HostGrantAuthority();
  final Map<AppLocale?, List<SkillDescriptor>> _descriptorLists =
      <AppLocale?, List<SkillDescriptor>>{};
  final Map<AppLocale?, Map<String, SkillDescriptor>> _descriptorsBySkillName =
      <AppLocale?, Map<String, SkillDescriptor>>{};
  final Map<SkillDescriptor, _HostSkillRegistration> _registrationByDescriptor =
      Map<SkillDescriptor, _HostSkillRegistration>.identity();
  bool _invalidated = false;
  Set<String> _availableCatalogIds = const <String>{};
  String? _capabilitySnapshotCacheKey;

  int get activeCount => _active.length;

  /// Immutable registration-order snapshot of currently enabled instances.
  List<AgentSkill> get activeSkills {
    synchronizeAvailability();
    if (_invalidated) return const <AgentSkill>[];
    return List<AgentSkill>.unmodifiable([
      for (final registration in _registrations)
        ?_active[registration.manifest.skillName],
    ]);
  }

  List<HostSkillRoutingManifest> get enabledManifests {
    synchronizeAvailability();
    if (_invalidated) return const <HostSkillRoutingManifest>[];
    return List<HostSkillRoutingManifest>.unmodifiable(
      _registrations
          .where(_isRegistrationEnabled)
          .map((registration) => registration.manifest),
    );
  }

  List<SkillDescriptor> descriptors({AppLocale? locale}) {
    synchronizeAvailability();
    if (_invalidated) return const <SkillDescriptor>[];
    return _descriptorLists.putIfAbsent(locale, () {
      final descriptors = <SkillDescriptor>[];
      final bySkillName = <String, SkillDescriptor>{};
      for (final registration in _registrations) {
        if (!_isRegistrationEnabled(registration)) continue;
        final descriptor = AgentSkillDescriptorFactory.fromManifest(
          registration.manifest,
          locale: locale,
        );
        descriptors.add(descriptor);
        bySkillName[registration.manifest.skillName] = descriptor;
        _registrationByDescriptor[descriptor] = registration;
      }
      _descriptorsBySkillName[locale] =
          Map<String, SkillDescriptor>.unmodifiable(bySkillName);
      return List<SkillDescriptor>.unmodifiable(descriptors);
    });
  }

  SkillDescriptor? descriptorFor(String skillName, {AppLocale? locale}) {
    descriptors(locale: locale);
    return _descriptorsBySkillName[locale]?[skillName];
  }

  /// Intersects a model-visible selection with descriptors owned by this
  /// exact registry generation, then activates only that bounded Host subset.
  ExecutableHostGrant issueGrant(TurnSkillGrant promptGrant) {
    synchronizeAvailability();
    if (_invalidated || promptGrant.isEmpty) return ExecutableHostGrant.none;
    final selected = <_HostSkillRegistration>[];
    final seen = <String>{};
    for (final descriptor in promptGrant.descriptors) {
      final registration = _registrationByDescriptor[descriptor];
      if (registration == null || !_isRegistrationEnabled(registration)) {
        continue;
      }
      if (seen.add(registration.manifest.skillName)) {
        selected.add(registration);
      }
    }
    if (selected.isEmpty) return ExecutableHostGrant.none;

    final capabilityService = _capabilitySnapshotService;
    AppCapabilitySnapshotLease? capabilityLease;
    if (capabilityService != null) {
      try {
        final acquisition = capabilityService.acquireLease(<AppCapabilityKey>[
          for (final registration in selected)
            AppCapabilityKey.skill(registration.catalogId),
        ], requireVisible: true);
        capabilityLease = acquisition.lease;
        if (!acquisition.isGranted || capabilityLease == null) {
          return ExecutableHostGrant.none;
        }
      } catch (_) {
        return ExecutableHostGrant.none;
      }
    }

    final skills = <AgentSkill>[];
    final names = <String>{};
    final tools = <String, GrantedHostTool>{};
    for (final registration in selected) {
      if (!_canContinueGrantMaterialization(
        registration: registration,
        capabilityService: capabilityService,
        capabilityLease: capabilityLease,
      )) {
        return ExecutableHostGrant.none;
      }
      late final AgentSkill skill;
      try {
        skill = activate(registration.manifest.skillName);
      } catch (_) {
        if (!_canContinueGrantMaterialization(
          registration: registration,
          capabilityService: capabilityService,
          capabilityLease: capabilityLease,
        )) {
          return ExecutableHostGrant.none;
        }
        rethrow;
      }
      if (!_canContinueGrantMaterialization(
        registration: registration,
        capabilityService: capabilityService,
        capabilityLease: capabilityLease,
      )) {
        return ExecutableHostGrant.none;
      }
      skills.add(skill);
      names.add(skill.skillName);
      final nativeMethods = registration.manifest.nativeMethods.toSet();
      for (final method in registration.manifest.methods) {
        final tool = HostSkillRoutingManifest.nativeToolName(
          skill.skillName,
          method,
        );
        tools[tool] = GrantedHostTool._(
          skill: skill,
          method: method,
          usesJsonArguments: nativeMethods.contains(method),
        );
      }
    }
    if (capabilityService != null &&
        (capabilityLease == null ||
            !capabilityService.isCurrent(capabilityLease))) {
      return ExecutableHostGrant.none;
    }
    return ExecutableHostGrant._(
      agentId: agentId,
      authority: _authority,
      generation: _authority.generation,
      activatedSkills: List<AgentSkill>.unmodifiable(skills),
      allowedSkillNames: Set<String>.unmodifiable(names),
      tools: Map<String, GrantedHostTool>.unmodifiable(tools),
      capabilitySnapshotService: capabilityService,
      capabilitySnapshotLease: capabilityLease,
    );
  }

  bool isEnabled(String skillName) {
    synchronizeAvailability();
    if (_invalidated) return false;
    final registration = _bySkillName[skillName];
    return registration != null && _isRegistrationEnabled(registration);
  }

  AgentSkill activate(String skillName) {
    synchronizeAvailability();
    if (_invalidated) throw StateError('host_registry_invalidated');
    final registration = _bySkillName[skillName];
    if (registration == null) {
      throw StateError('unknown_host_skill:$skillName');
    }
    if (!_isRegistrationEnabled(registration)) {
      throw StateError('host_skill_disabled:$skillName');
    }
    final cached = _active[skillName];
    if (cached != null) return cached;
    final retained = _temporarilyUnavailable.remove(skillName);
    if (retained != null) {
      _active[skillName] = retained;
      return retained;
    }

    final skill = registration.factory(agentId);
    _validateFactoryProduct(registration, skill);
    _active[skillName] = skill;
    return skill;
  }

  List<AgentSkill> activateSelected(Iterable<String> skillNames) {
    final selected = <AgentSkill>[];
    final seen = <String>{};
    for (final skillName in skillNames) {
      if (seen.add(skillName)) selected.add(activate(skillName));
    }
    return List<AgentSkill>.unmodifiable(selected);
  }

  /// Applies the same enablement semantics as the Skills UI: unknown ids are
  /// ignored and core Skills remain enabled.
  void reload(Set<String> enabledSkillIds) {
    if (_invalidated) throw StateError('host_registry_invalidated');
    final knownIds = _registrations
        .map((registration) => registration.catalogId)
        .toSet();
    final nextEnabledCatalogIds = <String>{
      ...enabledSkillIds.where(knownIds.contains),
      ..._coreCatalogIds,
    };
    if (_sameSet(_enabledCatalogIds, nextEnabledCatalogIds)) return;
    _enabledCatalogIds = Set<String>.unmodifiable(nextEnabledCatalogIds);
    _active.removeWhere((skillName, _) {
      final registration = _bySkillName[skillName];
      return registration == null || !_isRegistrationEnabled(registration);
    });
    _temporarilyUnavailable.removeWhere((skillName, _) {
      final registration = _bySkillName[skillName];
      return registration == null || !_isRegistrationEnabled(registration);
    });
    _authority.advance();
    _clearDescriptorCache();
  }

  /// Re-evaluates fail-closed catalog predicates and capability decisions as
  /// one registry snapshot. Any change advances the registry authority
  /// generation independently from the capability snapshot generation.
  bool synchronizeAvailability() {
    if (_invalidated) return false;
    final catalogAvailability = <String, bool>{
      for (final registration in _registrations)
        registration.catalogId: registration.isAvailable,
    };
    final capabilityService = _capabilitySnapshotService;
    AppCapabilitySnapshot? capabilitySnapshot;
    String? nextCapabilitySnapshotCacheKey;
    if (capabilityService != null) {
      try {
        if (capabilityService.isClosed) {
          nextCapabilitySnapshotCacheKey = 'closed';
        } else {
          capabilitySnapshot = capabilityService.value;
          nextCapabilitySnapshotCacheKey = capabilitySnapshot.cacheKey;
        }
      } catch (_) {
        nextCapabilitySnapshotCacheKey = 'unavailable';
      }
    }
    final next = <String>{
      for (final registration in _registrations)
        if (catalogAvailability[registration.catalogId] == true &&
            (capabilityService == null ||
                _snapshotAllowsRegistration(capabilitySnapshot, registration)))
          registration.catalogId,
    };
    final capabilityChanged =
        _capabilitySnapshotCacheKey != nextCapabilitySnapshotCacheKey;
    if (!capabilityChanged && _sameSet(_availableCatalogIds, next)) {
      return false;
    }
    _availableCatalogIds = Set<String>.unmodifiable(next);
    _capabilitySnapshotCacheKey = nextCapabilitySnapshotCacheKey;
    for (final entry in _active.entries.toList(growable: false)) {
      final registration = _bySkillName[entry.key];
      if (registration != null && _isRegistrationEnabled(registration)) {
        continue;
      }
      _temporarilyUnavailable[entry.key] = entry.value;
      _active.remove(entry.key);
    }
    _authority.advance();
    _clearDescriptorCache();
    return true;
  }

  /// Permanently revokes grants when a runtime replaces or disposes this
  /// registry. The instance cannot be reused afterwards.
  void invalidate() {
    if (_invalidated) return;
    _invalidated = true;
    _authority.invalidate();
    _active.clear();
    _temporarilyUnavailable.clear();
    _clearDescriptorCache();
  }

  void _clearDescriptorCache() {
    _descriptorLists.clear();
    _descriptorsBySkillName.clear();
    _registrationByDescriptor.clear();
  }

  bool _isRegistrationEnabled(_HostSkillRegistration registration) =>
      _availableCatalogIds.contains(registration.catalogId) &&
      (registration.isCore ||
          _enabledCatalogIds.contains(registration.catalogId));

  bool _snapshotAllowsRegistration(
    AppCapabilitySnapshot? snapshot,
    _HostSkillRegistration registration,
  ) {
    if (snapshot == null) return false;
    try {
      return snapshot.allows(
        AppCapabilityKey.skill(registration.catalogId),
        requireVisible: true,
      );
    } catch (_) {
      return false;
    }
  }

  bool _canContinueGrantMaterialization({
    required _HostSkillRegistration registration,
    required AppCapabilitySnapshotService? capabilityService,
    required AppCapabilitySnapshotLease? capabilityLease,
  }) {
    synchronizeAvailability();
    if (_invalidated || !_isRegistrationEnabled(registration)) return false;
    if (capabilityService == null) return capabilityLease == null;
    if (capabilityLease == null) return false;
    try {
      return capabilityService.isCurrent(capabilityLease);
    } catch (_) {
      return false;
    }
  }

  void _validateFactoryProduct(
    _HostSkillRegistration registration,
    AgentSkill skill,
  ) {
    final manifest = registration.manifest;
    if (skill.skillName != manifest.skillName) {
      throw StateError(
        'host_skill_name_mismatch:${registration.catalogId}:'
        '${manifest.skillName}:${skill.skillName}',
      );
    }
    final actualMethods = skill.methods.keys.toSet();
    if (!_sameSet(actualMethods, manifest.methods.toSet())) {
      throw StateError('host_skill_methods_mismatch:${registration.catalogId}');
    }
    final schemas = skill.nativeToolSchemas ?? const <String, dynamic>{};
    if (!_sameSet(schemas.keys.toSet(), manifest.nativeMethods.toSet())) {
      throw StateError(
        'host_skill_native_methods_mismatch:${registration.catalogId}',
      );
    }
    final actualTools = <String>[
      for (final method in schemas.keys)
        SkillManager.nativeToolName(skill, method),
    ];
    if (!_sameSet(actualTools.toSet(), manifest.nativeToolNames.toSet())) {
      throw StateError('host_skill_tools_mismatch:${registration.catalogId}');
    }
  }

  bool _sameSet(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);
}

class _HostGrantAuthority {
  int generation = 0;
  bool _active = true;
  Completer<void> _generationInvalidated = Completer<void>.sync();

  bool accepts(int candidate) => _active && candidate == generation;

  Future<void> whenInvalidated(int candidate) =>
      accepts(candidate) ? _generationInvalidated.future : Future<void>.value();

  void advance() {
    final previous = _generationInvalidated;
    generation++;
    _generationInvalidated = Completer<void>.sync();
    if (!previous.isCompleted) previous.complete();
  }

  void invalidate() {
    final previous = _generationInvalidated;
    _active = false;
    generation++;
    _generationInvalidated = Completer<void>.sync()..complete();
    if (!previous.isCompleted) previous.complete();
  }
}

class _HostSkillRegistration {
  const _HostSkillRegistration({
    required this.catalogId,
    required this.isCore,
    required this.manifest,
    required this.factory,
    required this.availability,
  });

  final String catalogId;
  final bool isCore;
  final HostSkillRoutingManifest manifest;
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
