import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_compatibility.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

final _now = DateTime.utc(2026, 10, 23);

AppInvocationDescriptor _descriptor({
  String rendering = 'webApp',
  bool game = false,
}) => AppInvocationDescriptor.fromSurface(
  project: SurfaceProject.fromJson({
    'id': 'browser-work',
    'rendering': rendering,
    'experienceType': game ? 'game' : 'utility',
    'html': '<main id="result">Ready</main>',
    'js': 'Surface.onAgent = (name, args) => args;',
    'manifest': {
      'schemaVersion': 2,
      'actions': [
        {
          'name': 'configure',
          'schema': {
            'type': 'object',
            'properties': <String, Object?>{},
            'additionalProperties': false,
          },
          'risk': 'localMutation',
          'consequencePolicy': 'reversible',
        },
      ],
    },
  }),
  identity: AppInvocationIdentity(
    scopeKey: 'test|owner',
    sourceId: 'browser-work',
    revisionId: 'r1',
    sourceDigest: 'a' * 64,
  ),
);

AppInvocationCompatibility _assess(
  AppInvocationDescriptor descriptor, {
  bool confirmed = false,
  bool visible = true,
  String runtimeSession = 'run-1',
  AppInvocationRuntimeProtocol protocol =
      AppInvocationRuntimeProtocol.correlatedSurface,
  Set<AppInvocationIsolationBoundary> boundaries = const {
    AppInvocationIsolationBoundary.sourceReadOnly,
    AppInvocationIsolationBoundary.applicationData,
    AppInvocationIsolationBoundary.browserData,
  },
}) => assessAppInvocationCompatibility(
  descriptor: descriptor,
  expectedAdapterId: 'browser',
  expectedAdapterVersion: '2',
  expectedSessionId: 'run-1',
  now: _now,
  runtimeEvidence: AppInvocationRuntimeEvidence(
    identity: descriptor.identity,
    contractDigest: descriptor.contractDigest,
    runtimeKind: descriptor.runtimeKind,
    protocol: protocol,
    adapterId: 'browser',
    adapterVersion: '2',
    sessionId: runtimeSession,
    observedAt: _now,
    expiresAt: _now.add(const Duration(minutes: 1)),
    ready: true,
    implementedActionNames: {'configure'},
    resultChannel: AppInvocationResultChannel.correlatedJson,
    requiresVisibleHost: true,
    isVisible: visible,
    externalEffectsAllowedByUser: confirmed,
  ),
  isolationEvidence: AppInvocationIsolationEvidence(
    identity: descriptor.identity,
    contractDigest: descriptor.contractDigest,
    adapterId: 'browser',
    adapterVersion: '2',
    sessionId: 'run-1',
    observedAt: _now,
    expiresAt: _now.add(const Duration(minutes: 1)),
    verifiedBoundaries: boundaries,
  ),
);

void main() {
  test('a browser game category does not claim native game authority', () {
    final game = _descriptor(game: true);
    expect(game.requiresGameAuthority, isFalse);
    expect(
      _assess(game, confirmed: true).status,
      AppInvocationCompatibilityStatus.compatible,
    );
    expect(
      _descriptor(rendering: 'workerCanvas', game: true).requiresGameAuthority,
      isTrue,
    );
  });

  test('networked browser execution requires current native consent', () {
    final descriptor = _descriptor();
    expect(_assess(descriptor).reasons, ['isolation_missing:externalEffects']);
    expect(
      _assess(descriptor, confirmed: true).status,
      AppInvocationCompatibilityStatus.compatible,
    );
    expect(
      _assess(descriptor, confirmed: true, runtimeSession: 'older-run').reasons,
      ['runtime_evidence_mismatch'],
    );
    expect(_assess(descriptor, confirmed: true, visible: false).reasons, [
      'visible_host_required',
    ]);
  });

  test('consent cannot stand in for source or local data isolation', () {
    for (final boundary in [
      AppInvocationIsolationBoundary.sourceReadOnly,
      AppInvocationIsolationBoundary.applicationData,
      AppInvocationIsolationBoundary.browserData,
    ]) {
      final boundaries = AppInvocationIsolationBoundary.values.toSet()
        ..remove(boundary)
        ..remove(AppInvocationIsolationBoundary.externalEffects);
      expect(
        _assess(_descriptor(), confirmed: true, boundaries: boundaries).reasons,
        ['isolation_missing:${boundary.name}'],
      );
    }
  });

  test('browser consent never authorizes network effects for a worker', () {
    expect(
      _assess(
        _descriptor(),
        confirmed: true,
        protocol: AppInvocationRuntimeProtocol.isolatedWorker,
      ).reasons,
      ['isolation_missing:externalEffects'],
    );
  });
}
