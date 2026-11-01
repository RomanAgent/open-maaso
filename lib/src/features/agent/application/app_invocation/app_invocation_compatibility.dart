import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

import 'app_invocation_descriptor.dart';

enum AppInvocationResultChannel {
  none,
  uncorrelatedEvents,
  correlatedJson,
  correlatedOutputs,
}

enum AppInvocationRuntimeProtocol {
  legacySurfaceCallback,
  isolatedWorker,
  correlatedSurface,
  workerCanvasControl,
  projectBundleControl,
  trustedGameControl,
}

enum AppInvocationIsolationBoundary {
  sourceReadOnly,
  applicationData,
  browserData,
  gameState,
  externalEffects,
}

enum AppInvocationCompatibilityStatus {
  pendingVerification,
  compatible,
  openOnly,
  invalidContract,
}

/// A host's read-only handshake report, not permission to invoke anything.
/// There is no JSON-to-grant conversion or executable callback in this model.
final class AppInvocationRuntimeEvidence {
  AppInvocationRuntimeEvidence({
    required this.identity,
    required this.contractDigest,
    required this.runtimeKind,
    required this.protocol,
    required this.adapterId,
    required this.adapterVersion,
    required this.sessionId,
    required this.observedAt,
    required this.expiresAt,
    required this.ready,
    required Set<String> implementedActionNames,
    required this.resultChannel,
    required this.requiresVisibleHost,
    required this.isVisible,
    this.supportsGameAuthority = false,
    this.externalEffectsAllowedByUser = false,
  }) : implementedActionNames = Set.unmodifiable(implementedActionNames);

  final AppInvocationIdentity identity;
  final String contractDigest, adapterId, adapterVersion, sessionId;
  final AppInvocationRuntimeKind runtimeKind;
  final AppInvocationRuntimeProtocol protocol;
  final DateTime observedAt, expiresAt;
  final bool ready, requiresVisibleHost, isVisible, supportsGameAuthority;

  /// A current native confirmation, not an authored risk declaration and not
  /// evidence that a remote service's state is isolated. Only the ordinary
  /// visible browser adapter may use this permission instead of a no-effects
  /// boundary; source, local data and browser data still require isolation.
  final bool externalEffectsAllowedByUser;
  final Set<String> implementedActionNames;
  final AppInvocationResultChannel resultChannel;
}

/// Separate verification facts for each writable boundary. A new browser or
/// session ID alone is not evidence that installed data or game state is safe.
/// A no-network runtime verifies [AppInvocationIsolationBoundary.externalEffects].
/// An ordinary visible browser may instead carry explicit current native
/// consent in runtime evidence; consent never certifies remote-state isolation.
final class AppInvocationIsolationEvidence {
  AppInvocationIsolationEvidence({
    required this.identity,
    required this.contractDigest,
    required this.adapterId,
    required this.adapterVersion,
    required this.sessionId,
    required this.observedAt,
    required this.expiresAt,
    required Set<AppInvocationIsolationBoundary> verifiedBoundaries,
  }) : verifiedBoundaries = Set.unmodifiable(verifiedBoundaries);

  final AppInvocationIdentity identity;
  final String contractDigest, adapterId, adapterVersion, sessionId;
  final DateTime observedAt, expiresAt;
  final Set<AppInvocationIsolationBoundary> verifiedBoundaries;
}

/// Technical compatibility only. Even [AppInvocationCompatibilityStatus.compatible]
/// requires a new native grant, action policy, turn ownership and cancellation
/// checks at execution time. This result is never execution authority.
final class AppInvocationCompatibility {
  AppInvocationCompatibility._(
    this.status, {
    required List<String> reasons,
    this.actions = const [],
    this.resultChannel = AppInvocationResultChannel.none,
    this.requiresVisibleHost = false,
  }) : reasons = List.unmodifiable(reasons);

  final AppInvocationCompatibilityStatus status;
  final List<String> reasons;
  final List<AppInvocationActionDescriptor> actions;
  final AppInvocationResultChannel resultChannel;
  final bool requiresVisibleHost;

  /// Both correlated channels carry bounded JSON of any JSON shape. Native
  /// output handles need independent verification; JSON objects are not files.
  /// This utility neither publishes a result nor certifies its provenance.
  Object? snapshotJsonResult(Object? value) {
    if (status != AppInvocationCompatibilityStatus.compatible ||
        !_correlated(resultChannel)) {
      throw StateError('invocation_result_channel_unavailable');
    }
    const json = ProjectJsonCanonicalizer(
      maxBytes: 64 * 1024,
      maxDepth: 16,
      maxNodes: 4096,
    );
    return json.parse(json.canonicalize(value));
  }
}

AppInvocationCompatibility assessAppInvocationCompatibility({
  required AppInvocationDescriptor descriptor,
  required String expectedAdapterId,
  required String expectedAdapterVersion,
  required String expectedSessionId,
  AppInvocationRuntimeEvidence? runtimeEvidence,
  AppInvocationIsolationEvidence? isolationEvidence,
  required DateTime now,
}) {
  AppInvocationCompatibility pending(String reason) =>
      AppInvocationCompatibility._(
        AppInvocationCompatibilityStatus.pendingVerification,
        reasons: [reason],
      );
  AppInvocationCompatibility openOnly(String reason) =>
      AppInvocationCompatibility._(
        AppInvocationCompatibilityStatus.openOnly,
        reasons: [reason],
      );
  if (descriptor.contractIssues.isNotEmpty) {
    return AppInvocationCompatibility._(
      AppInvocationCompatibilityStatus.invalidContract,
      reasons: descriptor.contractIssues,
    );
  }
  if (descriptor.actions.isEmpty) return openOnly('no_declared_actions');
  if (expectedAdapterId.trim().isEmpty ||
      expectedAdapterVersion.trim().isEmpty ||
      expectedSessionId.trim().isEmpty) {
    return pending('current_runtime_identity_missing');
  }
  final runtime = runtimeEvidence;
  if (runtime == null) return pending('runtime_evidence_missing');
  if (!runtime.identity.matches(descriptor.identity) ||
      runtime.contractDigest != descriptor.contractDigest ||
      runtime.runtimeKind != descriptor.runtimeKind ||
      runtime.adapterId != expectedAdapterId ||
      runtime.adapterVersion != expectedAdapterVersion ||
      runtime.sessionId != expectedSessionId) {
    return pending('runtime_evidence_mismatch');
  }
  if (runtime.adapterId.trim().isEmpty ||
      runtime.adapterVersion.trim().isEmpty ||
      runtime.sessionId.trim().isEmpty ||
      !_fresh(runtime.observedAt, runtime.expiresAt, now)) {
    return pending('runtime_evidence_stale_or_invalid');
  }
  if (!runtime.ready) return pending('runtime_not_ready');
  if (runtime.protocol == AppInvocationRuntimeProtocol.legacySurfaceCallback) {
    return openOnly('correlated_result_channel_unavailable');
  }
  final expectedProtocol = switch (descriptor.runtimeKind) {
    AppInvocationRuntimeKind.surfaceWebApp ||
    AppInvocationRuntimeKind.legacySurface =>
      AppInvocationRuntimeProtocol.correlatedSurface,
    AppInvocationRuntimeKind.workerCanvas =>
      AppInvocationRuntimeProtocol.workerCanvasControl,
    AppInvocationRuntimeKind.projectBundleApplet =>
      AppInvocationRuntimeProtocol.projectBundleControl,
    AppInvocationRuntimeKind.trustedGame =>
      AppInvocationRuntimeProtocol.trustedGameControl,
  };
  final isolatedWorker =
      runtime.protocol == AppInvocationRuntimeProtocol.isolatedWorker &&
      (descriptor.runtimeKind == AppInvocationRuntimeKind.surfaceWebApp ||
          descriptor.runtimeKind == AppInvocationRuntimeKind.legacySurface) &&
      !descriptor.requiresGameAuthority;
  if (!isolatedWorker && runtime.protocol != expectedProtocol) {
    return pending('runtime_protocol_mismatch');
  }
  if (!_correlated(runtime.resultChannel)) {
    return openOnly('correlated_result_channel_unavailable');
  }
  if (descriptor.requiresGameAuthority && !runtime.supportsGameAuthority) {
    return pending('game_authority_boundary_unverified');
  }
  // Current bundle-control and Surface protocols need visible hosts. Evidence
  // cannot switch off those runtime guards by reporting requiresVisible=false.
  if ((!isolatedWorker && !runtime.requiresVisibleHost) ||
      (runtime.requiresVisibleHost && !runtime.isVisible)) {
    return pending('visible_host_required');
  }
  final actions = descriptor.actions
      .where((action) => runtime.implementedActionNames.contains(action.name))
      .toList(growable: false);
  if (actions.isEmpty) return openOnly('no_implemented_declared_actions');
  final isolation = isolationEvidence;
  if (isolation == null) return pending('isolation_evidence_missing');
  if (!isolation.identity.matches(descriptor.identity) ||
      isolation.contractDigest != descriptor.contractDigest ||
      isolation.adapterId != runtime.adapterId ||
      isolation.adapterVersion != runtime.adapterVersion ||
      isolation.sessionId != runtime.sessionId) {
    return pending('isolation_evidence_mismatch');
  }
  if (!_fresh(isolation.observedAt, isolation.expiresAt, now)) {
    return pending('isolation_evidence_stale_or_invalid');
  }
  final confirmedBrowserEffects =
      runtime.externalEffectsAllowedByUser &&
      runtime.protocol == AppInvocationRuntimeProtocol.correlatedSurface &&
      (descriptor.runtimeKind == AppInvocationRuntimeKind.surfaceWebApp ||
          descriptor.runtimeKind == AppInvocationRuntimeKind.legacySurface) &&
      !descriptor.requiresGameAuthority;
  final requiredBoundaries = {
    AppInvocationIsolationBoundary.sourceReadOnly,
    AppInvocationIsolationBoundary.applicationData,
    AppInvocationIsolationBoundary.browserData,
    if (!confirmedBrowserEffects)
      AppInvocationIsolationBoundary.externalEffects,
    if (descriptor.requiresGameAuthority)
      AppInvocationIsolationBoundary.gameState,
  };
  final missing = requiredBoundaries.difference(isolation.verifiedBoundaries);
  if (missing.isNotEmpty) {
    return AppInvocationCompatibility._(
      AppInvocationCompatibilityStatus.pendingVerification,
      reasons: [
        for (final boundary in missing) 'isolation_missing:${boundary.name}',
      ],
    );
  }
  return AppInvocationCompatibility._(
    AppInvocationCompatibilityStatus.compatible,
    reasons: [
      if (actions.length != descriptor.actions.length)
        'some_actions_unimplemented',
    ],
    actions: List.unmodifiable(actions),
    resultChannel: runtime.resultChannel,
    requiresVisibleHost: runtime.requiresVisibleHost,
  );
}

bool _correlated(AppInvocationResultChannel channel) =>
    channel == AppInvocationResultChannel.correlatedJson ||
    channel == AppInvocationResultChannel.correlatedOutputs;

bool _fresh(DateTime observedAt, DateTime expiresAt, DateTime now) =>
    !observedAt.isAfter(now) &&
    expiresAt.isAfter(observedAt) &&
    now.isBefore(expiresAt);
