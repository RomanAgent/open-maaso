import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

enum AppCapabilityExposure { visible, hidden }

enum AppCapabilityAdmission { allowed, denied }

enum AppCapabilityReadiness { ready, unavailable }

/// Stable, namespaced identity used across route, skill, action, and UI gates.
final class AppCapabilityKey implements Comparable<AppCapabilityKey> {
  AppCapabilityKey({required String namespace, required String id})
    : namespace = _validatedComponent(namespace, 'namespace'),
      id = _validatedComponent(id, 'id');

  factory AppCapabilityKey.parse(String canonicalId) {
    final separator = canonicalId.indexOf(':');
    if (separator <= 0 || separator == canonicalId.length - 1) {
      throw const FormatException('invalid_capability_key');
    }
    return AppCapabilityKey(
      namespace: canonicalId.substring(0, separator),
      id: canonicalId.substring(separator + 1),
    );
  }

  factory AppCapabilityKey.platformAction(AppActionCapability capability) =>
      AppCapabilityKey(namespace: 'platform_action', id: capability.name);

  factory AppCapabilityKey.route(String destinationId) =>
      AppCapabilityKey(namespace: 'route', id: destinationId);

  factory AppCapabilityKey.skill(String catalogId) =>
      AppCapabilityKey(namespace: 'skill', id: catalogId);

  factory AppCapabilityKey.pageAction({
    required String route,
    required String actionId,
  }) => AppCapabilityKey(namespace: 'page_action', id: '$route#$actionId');

  static final cloudLlm = AppCapabilityKey(
    namespace: 'model_path',
    id: 'cloud_llm',
  );
  static final cloudTts = AppCapabilityKey(
    namespace: 'model_path',
    id: 'cloud_tts',
  );

  final String namespace;
  final String id;

  String get canonicalId => '$namespace:$id';

  @override
  int compareTo(AppCapabilityKey other) =>
      canonicalId.compareTo(other.canonicalId);

  @override
  bool operator ==(Object other) =>
      other is AppCapabilityKey &&
      namespace == other.namespace &&
      id == other.id;

  @override
  int get hashCode => Object.hash(namespace, id);

  @override
  String toString() => canonicalId;

  static String _validatedComponent(String raw, String field) {
    final value = raw.trim();
    if (value.isEmpty ||
        value.length > 512 ||
        !RegExp(r'^[A-Za-z0-9_./?#-]+$').hasMatch(value)) {
      throw FormatException('invalid_capability_$field');
    }
    return value;
  }
}

final class AppCapabilityDecision {
  AppCapabilityDecision({
    required this.key,
    required this.exposure,
    required this.admission,
    required this.readiness,
    Iterable<String> reasonCodes = const <String>[],
  }) : reasonCodes = Set<String>.unmodifiable(
         reasonCodes.map(_validatedReasonCode),
       );

  factory AppCapabilityDecision.available(AppCapabilityKey key) =>
      AppCapabilityDecision(
        key: key,
        exposure: AppCapabilityExposure.visible,
        admission: AppCapabilityAdmission.allowed,
        readiness: AppCapabilityReadiness.ready,
      );

  final AppCapabilityKey key;
  final AppCapabilityExposure exposure;
  final AppCapabilityAdmission admission;
  final AppCapabilityReadiness readiness;
  final Set<String> reasonCodes;

  bool get isVisible => exposure == AppCapabilityExposure.visible;
  bool get canExecute =>
      admission == AppCapabilityAdmission.allowed &&
      readiness == AppCapabilityReadiness.ready;
  bool get isUsable => isVisible && canExecute;

  static String _validatedReasonCode(String raw) {
    final value = raw.trim();
    if (value.isEmpty ||
        value.length > 256 ||
        !RegExp(r'^[a-z0-9_.:-]+$').hasMatch(value)) {
      throw const FormatException('invalid_capability_reason_code');
    }
    return value;
  }
}

final class AppCapabilitySnapshotContext {
  AppCapabilitySnapshotContext({
    required this.hostPlatform,
    required this.rolloutGeneration,
    this.accountScopeDigest,
    this.accountGeneration,
  }) {
    if (rolloutGeneration < 0) {
      throw const FormatException('invalid_rollout_generation');
    }
    final hasDigest = accountScopeDigest != null;
    final hasGeneration = accountGeneration != null;
    if (hasDigest != hasGeneration) {
      throw const FormatException('partial_capability_account_context');
    }
    if (accountScopeDigest case final digest?) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('invalid_capability_account_digest');
      }
      if (accountGeneration! < 0) {
        throw const FormatException('invalid_capability_account_generation');
      }
    }
  }

  final AppHostPlatform hostPlatform;
  final String? accountScopeDigest;
  final int? accountGeneration;
  final int rolloutGeneration;

  AppCapabilitySnapshotContext copyWith({
    AppHostPlatform? hostPlatform,
    int? rolloutGeneration,
    String? accountScopeDigest,
    int? accountGeneration,
    bool clearAccount = false,
  }) => AppCapabilitySnapshotContext(
    hostPlatform: hostPlatform ?? this.hostPlatform,
    rolloutGeneration: rolloutGeneration ?? this.rolloutGeneration,
    accountScopeDigest: clearAccount
        ? null
        : accountScopeDigest ?? this.accountScopeDigest,
    accountGeneration: clearAccount
        ? null
        : accountGeneration ?? this.accountGeneration,
  );
}

final class AppCapabilitySnapshotDraft {
  AppCapabilitySnapshotDraft({
    required this.context,
    required Iterable<AppCapabilityDecision> decisions,
  }) : decisions = _index(decisions);

  final AppCapabilitySnapshotContext context;
  final Map<AppCapabilityKey, AppCapabilityDecision> decisions;

  static Map<AppCapabilityKey, AppCapabilityDecision> _index(
    Iterable<AppCapabilityDecision> source,
  ) {
    final indexed = <AppCapabilityKey, AppCapabilityDecision>{};
    for (final decision in source) {
      if (indexed.containsKey(decision.key)) {
        throw FormatException(
          'duplicate_capability_key:${decision.key.canonicalId}',
        );
      }
      indexed[decision.key] = decision;
    }
    return Map<AppCapabilityKey, AppCapabilityDecision>.unmodifiable(indexed);
  }
}

final class AppCapabilitySnapshot {
  AppCapabilitySnapshot.materialize({
    required this.generation,
    required AppCapabilitySnapshotDraft draft,
  }) : context = draft.context,
       decisions = draft.decisions,
       revision = _revisionFor(draft) {
    if (generation < 0) {
      throw const FormatException('invalid_capability_generation');
    }
  }

  final int generation;
  final String revision;
  final AppCapabilitySnapshotContext context;
  final Map<AppCapabilityKey, AppCapabilityDecision> decisions;

  String get cacheKey => '$revision:$generation';

  AppCapabilityDecision? decision(AppCapabilityKey key) => decisions[key];

  bool exposes(AppCapabilityKey key) => decision(key)?.isVisible == true;

  bool allows(AppCapabilityKey key, {bool requireVisible = false}) {
    final resolved = decision(key);
    if (resolved == null || !resolved.canExecute) return false;
    return !requireVisible || resolved.isVisible;
  }

  Map<AppCapabilityKey, Set<String>> rejected(
    Iterable<AppCapabilityKey> keys, {
    bool requireVisible = false,
  }) {
    final rejected = <AppCapabilityKey, Set<String>>{};
    for (final key in keys) {
      final resolved = decision(key);
      if (resolved == null) {
        rejected[key] = const <String>{'capability_not_declared'};
      } else if (!resolved.canExecute ||
          (requireVisible && !resolved.isVisible)) {
        rejected[key] = resolved.reasonCodes.isEmpty
            ? const <String>{'capability_unavailable'}
            : resolved.reasonCodes;
      }
    }
    return Map<AppCapabilityKey, Set<String>>.unmodifiable(rejected);
  }

  static String _revisionFor(AppCapabilitySnapshotDraft draft) {
    final ordered = draft.decisions.values.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    final payload = <String, Object?>{
      'platform': draft.context.hostPlatform.name,
      'rolloutGeneration': draft.context.rolloutGeneration,
      'accountScopeDigest': draft.context.accountScopeDigest,
      'accountGeneration': draft.context.accountGeneration,
      'decisions': <Object?>[
        for (final decision in ordered)
          <String, Object?>{
            'key': decision.key.canonicalId,
            'exposure': decision.exposure.name,
            'admission': decision.admission.name,
            'readiness': decision.readiness.name,
            'reasons': decision.reasonCodes.toList()..sort(),
          },
      ],
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }
}

abstract interface class AppCapabilitySnapshotResolver {
  AppCapabilitySnapshotDraft resolve(AppCapabilitySnapshotContext context);
}

typedef AppSkillCapabilityAdmission = bool Function(String skillId);

/// Projects the existing host matrix into the unified decision vocabulary.
final class AppPlatformCapabilitySnapshotResolver
    implements AppCapabilitySnapshotResolver {
  AppPlatformCapabilitySnapshotResolver({
    required Iterable<String> routeIds,
    Iterable<String> skillIds = const <String>[],
    Map<String, Set<AppCapabilityKey>> skillRequirements =
        const <String, Set<AppCapabilityKey>>{},
    AppSkillCapabilityAdmission? skillAdmission,
  }) : _routeIds = Set<String>.unmodifiable(routeIds),
       _skillIds = Set<String>.unmodifiable(skillIds),
       _skillAdmission = skillAdmission,
       _skillRequirements = Map<String, Set<AppCapabilityKey>>.unmodifiable({
         for (final entry in skillRequirements.entries)
           entry.key: Set<AppCapabilityKey>.unmodifiable(entry.value),
       });

  final Set<String> _routeIds;
  final Set<String> _skillIds;
  final AppSkillCapabilityAdmission? _skillAdmission;
  final Map<String, Set<AppCapabilityKey>> _skillRequirements;

  @override
  AppCapabilitySnapshotDraft resolve(AppCapabilitySnapshotContext context) {
    final platform = AppPlatformCapabilities.forPlatform(context.hostPlatform);
    final indexed = <AppCapabilityKey, AppCapabilityDecision>{};

    void add(AppCapabilityDecision decision) {
      if (indexed.containsKey(decision.key)) {
        throw FormatException(
          'duplicate_capability_key:${decision.key.canonicalId}',
        );
      }
      indexed[decision.key] = decision;
    }

    add(AppCapabilityDecision.available(AppCapabilityKey.cloudLlm));
    add(AppCapabilityDecision.available(AppCapabilityKey.cloudTts));
    for (final capability in AppActionCapability.values) {
      final key = AppCapabilityKey.platformAction(capability);
      final available = platform.actionStatus(capability).available;
      final privateLocalPath =
          capability == AppActionCapability.advancedAiSettings ||
          capability == AppActionCapability.onDeviceLlm ||
          capability == AppActionCapability.onDeviceSpeechModels;
      add(
        AppCapabilityDecision(
          key: key,
          exposure: !available && privateLocalPath
              ? AppCapabilityExposure.hidden
              : AppCapabilityExposure.visible,
          admission: !available && privateLocalPath
              ? AppCapabilityAdmission.denied
              : AppCapabilityAdmission.allowed,
          readiness: available
              ? AppCapabilityReadiness.ready
              : AppCapabilityReadiness.unavailable,
          reasonCodes: available
              ? const <String>[]
              : const <String>['unsupported_host_platform'],
        ),
      );
    }

    for (final routeId in _routeIds) {
      final status = platform.destinationStatus(routeId);
      final routeRequirements =
          AppPlatformCapabilities.routeAvailabilityRequirements[routeId] ??
          const <AppActionCapability>{};
      final reasons = <String>{
        for (final capability in routeRequirements)
          if (!platform.actionStatus(capability).available)
            'required_capability_unavailable:${_reasonToken(capability.name)}',
      };
      add(
        AppCapabilityDecision(
          key: AppCapabilityKey.route(routeId),
          exposure: status.routeAvailable
              ? AppCapabilityExposure.visible
              : AppCapabilityExposure.hidden,
          admission: status.routeAvailable
              ? AppCapabilityAdmission.allowed
              : AppCapabilityAdmission.denied,
          readiness: status.routeAvailable
              ? AppCapabilityReadiness.ready
              : AppCapabilityReadiness.unavailable,
          reasonCodes: reasons,
        ),
      );
    }

    for (final skillId in _skillIds) {
      var policyAdmitted = true;
      try {
        policyAdmitted = _skillAdmission?.call(skillId) ?? true;
      } catch (_) {
        policyAdmitted = false;
      }
      final requirements = _skillRequirements[skillId] ?? const {};
      final missing = <String>{if (!policyAdmitted) 'skill_policy_denied'};
      var visible = policyAdmitted;
      var admitted = policyAdmitted;
      var ready = true;
      for (final required in requirements) {
        final decision = indexed[required];
        if (decision == null) {
          visible = false;
          admitted = false;
          ready = false;
          missing.add('required_capability_not_declared');
          continue;
        }
        visible = visible && decision.isVisible;
        admitted =
            admitted && decision.admission == AppCapabilityAdmission.allowed;
        ready = ready && decision.readiness == AppCapabilityReadiness.ready;
        if (!decision.canExecute || !decision.isVisible) {
          missing.addAll(decision.reasonCodes);
        }
      }
      add(
        AppCapabilityDecision(
          key: AppCapabilityKey.skill(skillId),
          exposure: visible
              ? AppCapabilityExposure.visible
              : AppCapabilityExposure.hidden,
          admission: admitted
              ? AppCapabilityAdmission.allowed
              : AppCapabilityAdmission.denied,
          readiness: ready
              ? AppCapabilityReadiness.ready
              : AppCapabilityReadiness.unavailable,
          reasonCodes: missing,
        ),
      );
    }

    return AppCapabilitySnapshotDraft(
      context: context,
      decisions: indexed.values,
    );
  }

  static String _reasonToken(String value) => value
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]}_${match[2]}',
      )
      .toLowerCase();
}
