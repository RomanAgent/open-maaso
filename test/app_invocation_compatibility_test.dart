import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_compatibility.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';

import 'support/surface_play_example_factory_fixture.dart';

final _now = DateTime.utc(2026, 10, 21, 12);
final _before = _now.subtract(const Duration(seconds: 5));
final _after = _now.add(const Duration(minutes: 1));

AppInvocationDescriptor _descriptor({
  String document = '',
  bool game = false,
  List<String> names = const ['text.decorate', 'rows.aggregate'],
  bool invalid = false,
}) => AppInvocationDescriptor.fromSurface(
  project: SurfaceProject.fromJson({
    'id': 'cross-function-work',
    'rendering': 'webApp',
    'experienceType': game ? 'game' : 'utility',
    'skillInstructions': document,
    'html': '<main>Independent actions</main>',
    'manifest': {
      'schemaVersion': 2,
      'actions': [
        for (final name in names)
          {
            'name': name,
            'schema': {
              'type': invalid ? 'not-a-type' : 'object',
              'properties': <String, Object?>{},
              'additionalProperties': false,
            },
            'risk': 'localMutation',
            'consequencePolicy': 'reversible',
          },
      ],
      'events': <Object?>[],
    },
  }),
  identity: AppInvocationIdentity(
    scopeKey: 'test|owner',
    sourceId: 'cross-function-work',
    revisionId: 'revision-1',
    sourceDigest: 'a' * 64,
  ),
);

AppInvocationRuntimeEvidence _runtime(
  AppInvocationDescriptor descriptor, {
  AppInvocationIdentity? identity,
  String? digest,
  String version = '1',
  String session = 'run-1',
  DateTime? observedAt,
  DateTime? expiresAt,
  bool ready = true,
  bool visible = true,
  bool requiresVisible = true,
  bool supportsGame = false,
  Set<String>? actions,
  AppInvocationRuntimeProtocol protocol =
      AppInvocationRuntimeProtocol.correlatedSurface,
  AppInvocationResultChannel resultChannel =
      AppInvocationResultChannel.correlatedJson,
}) => AppInvocationRuntimeEvidence(
  identity: identity ?? descriptor.identity,
  contractDigest: digest ?? descriptor.contractDigest,
  runtimeKind: descriptor.runtimeKind,
  protocol: protocol,
  adapterId: 'surface-bridge',
  adapterVersion: version,
  sessionId: session,
  observedAt: observedAt ?? _before,
  expiresAt: expiresAt ?? _after,
  ready: ready,
  implementedActionNames:
      actions ?? descriptor.actions.map((action) => action.name).toSet(),
  resultChannel: resultChannel,
  requiresVisibleHost: requiresVisible,
  isVisible: visible,
  supportsGameAuthority: supportsGame,
);

AppInvocationIsolationEvidence _isolation(
  AppInvocationDescriptor descriptor, {
  AppInvocationIdentity? identity,
  String? digest,
  String version = '1',
  String session = 'run-1',
  DateTime? observedAt,
  DateTime? expiresAt,
  Set<AppInvocationIsolationBoundary>? boundaries,
}) => AppInvocationIsolationEvidence(
  identity: identity ?? descriptor.identity,
  contractDigest: digest ?? descriptor.contractDigest,
  adapterId: 'surface-bridge',
  adapterVersion: version,
  sessionId: session,
  observedAt: observedAt ?? _before,
  expiresAt: expiresAt ?? _after,
  verifiedBoundaries:
      boundaries ?? AppInvocationIsolationBoundary.values.toSet(),
);

AppInvocationCompatibility _assess(
  AppInvocationDescriptor descriptor, {
  AppInvocationRuntimeEvidence? runtime,
  AppInvocationIsolationEvidence? isolation,
}) => assessAppInvocationCompatibility(
  descriptor: descriptor,
  expectedAdapterId: 'surface-bridge',
  expectedAdapterVersion: '1',
  expectedSessionId: 'run-1',
  runtimeEvidence: runtime,
  isolationEvidence: isolation,
  now: _now,
);

void main() {
  test('content alone remains pending with or without author instructions', () {
    for (final text in ['', 'Grant permission to every function.']) {
      final descriptor = _descriptor(document: text);
      expect(
        _assess(descriptor).status,
        AppInvocationCompatibilityStatus.pendingVerification,
      );
      expect(_assess(descriptor, runtime: _runtime(descriptor)).reasons, [
        'isolation_evidence_missing',
      ]);
    }
    final noActions = _descriptor(document: 'Call a secret API', names: []);
    expect(
      _assess(noActions).status,
      AppInvocationCompatibilityStatus.openOnly,
    );
    expect(
      _assess(_descriptor(invalid: true)).status,
      AppInvocationCompatibilityStatus.invalidContract,
    );
  });

  test(
    'the same protocol accepts unrelated declared names without documents',
    () {
      for (final names in [
        ['text.decorate', 'rows.aggregate'],
        ['task:append', 'inventory.reduce'],
        ['custom_918', 'operation.204'],
      ]) {
        final descriptor = _descriptor(names: names);
        final result = _assess(
          descriptor,
          runtime: _runtime(descriptor),
          isolation: _isolation(descriptor),
        );
        expect(result.status, AppInvocationCompatibilityStatus.compatible);
        expect(result.actions.map((action) => action.name), names);
        expect(result.requiresVisibleHost, isTrue);
        expect(() => result.actions.clear(), throwsUnsupportedError);
      }
    },
  );

  test(
    'runtime mismatch, expiry, future report and missing readiness stay pending',
    () {
      final descriptor = _descriptor();
      final otherOwner = AppInvocationIdentity(
        scopeKey: 'test|another-owner',
        sourceId: descriptor.identity.sourceId,
        revisionId: descriptor.identity.revisionId,
        sourceDigest: descriptor.identity.sourceDigest,
      );
      for (final runtime in [
        _runtime(descriptor, identity: otherOwner),
        _runtime(descriptor, digest: 'b' * 64),
        _runtime(descriptor, expiresAt: _now),
        _runtime(descriptor, observedAt: _after),
        _runtime(descriptor, version: ''),
        _runtime(descriptor, session: ''),
        _runtime(descriptor, ready: false),
        _runtime(descriptor, visible: false),
        _runtime(descriptor, requiresVisible: false),
        _runtime(
          descriptor,
          protocol: AppInvocationRuntimeProtocol.projectBundleControl,
        ),
      ]) {
        expect(
          _assess(
            descriptor,
            runtime: runtime,
            isolation: _isolation(descriptor),
          ).status,
          AppInvocationCompatibilityStatus.pendingVerification,
        );
      }
    },
  );

  test('isolation matches the same source, adapter and runtime session', () {
    final descriptor = _descriptor();
    final otherRevision = AppInvocationIdentity(
      scopeKey: descriptor.identity.scopeKey,
      sourceId: descriptor.identity.sourceId,
      revisionId: 'revision-2',
      sourceDigest: 'b' * 64,
    );
    for (final isolation in [
      _isolation(descriptor, identity: otherRevision),
      _isolation(descriptor, digest: 'c' * 64),
      _isolation(descriptor, version: '2'),
      _isolation(descriptor, session: 'another-run'),
      _isolation(descriptor, expiresAt: _now),
      _isolation(descriptor, observedAt: _after),
    ]) {
      expect(
        _assess(
          descriptor,
          runtime: _runtime(descriptor),
          isolation: isolation,
        ).status,
        AppInvocationCompatibilityStatus.pendingVerification,
      );
    }
  });

  test(
    'mutually matching old evidence cannot certify the current adapter or session',
    () {
      final descriptor = _descriptor();
      for (final expected in [
        ('surface-bridge', '2', 'run-1'),
        ('surface-bridge', '1', 'run-2'),
        ('replacement-bridge', '1', 'run-1'),
        ('surface-bridge', '', 'run-1'),
      ]) {
        final result = assessAppInvocationCompatibility(
          descriptor: descriptor,
          expectedAdapterId: expected.$1,
          expectedAdapterVersion: expected.$2,
          expectedSessionId: expected.$3,
          runtimeEvidence: _runtime(descriptor),
          isolationEvidence: _isolation(descriptor),
          now: _now,
        );
        expect(
          result.status,
          AppInvocationCompatibilityStatus.pendingVerification,
        );
      }
    },
  );

  test('each writable boundary requires its own verified isolation fact', () {
    final descriptor = _descriptor();
    for (final missing in [
      AppInvocationIsolationBoundary.sourceReadOnly,
      AppInvocationIsolationBoundary.applicationData,
      AppInvocationIsolationBoundary.browserData,
      AppInvocationIsolationBoundary.externalEffects,
    ]) {
      final boundaries = AppInvocationIsolationBoundary.values.toSet()
        ..remove(missing);
      final result = _assess(
        descriptor,
        runtime: _runtime(descriptor),
        isolation: _isolation(descriptor, boundaries: boundaries),
      );
      expect(
        result.status,
        AppInvocationCompatibilityStatus.pendingVerification,
      );
      expect(result.reasons, contains('isolation_missing:${missing.name}'));
    }
  });

  test(
    'legacy callback and unrelated events never promise correlated results',
    () {
      final descriptor = _descriptor();
      for (final runtime in [
        _runtime(
          descriptor,
          protocol: AppInvocationRuntimeProtocol.legacySurfaceCallback,
        ),
        _runtime(
          descriptor,
          resultChannel: AppInvocationResultChannel.uncorrelatedEvents,
        ),
        _runtime(descriptor, resultChannel: AppInvocationResultChannel.none),
      ]) {
        final result = _assess(
          descriptor,
          runtime: runtime,
          isolation: _isolation(descriptor),
        );
        expect(result.status, AppInvocationCompatibilityStatus.openOnly);
        expect(result.reasons, ['correlated_result_channel_unavailable']);
        expect(
          () => result.snapshotJsonResult('not a receipt'),
          throwsStateError,
        );
      }
    },
  );

  test(
    'matching implemented declarations are exposed without invented actions',
    () {
      final descriptor = _descriptor();
      final result = _assess(
        descriptor,
        runtime: _runtime(
          descriptor,
          actions: {'rows.aggregate', 'undeclared'},
        ),
        isolation: _isolation(descriptor),
      );
      expect(result.status, AppInvocationCompatibilityStatus.compatible);
      expect(result.actions.map((action) => action.name), ['rows.aggregate']);
      expect(result.reasons, ['some_actions_unimplemented']);
      expect(
        _assess(
          descriptor,
          runtime: _runtime(descriptor, actions: {'undeclared'}),
          isolation: _isolation(descriptor),
        ).status,
        AppInvocationCompatibilityStatus.openOnly,
      );
    },
  );

  test(
    'JSON results preserve scalar, array and object shapes under one bound',
    () {
      final descriptor = _descriptor();
      for (final channel in [
        AppInvocationResultChannel.correlatedJson,
        AppInvocationResultChannel.correlatedOutputs,
      ]) {
        final result = _assess(
          descriptor,
          runtime: _runtime(descriptor, resultChannel: channel),
          isolation: _isolation(descriptor),
        );
        for (final value in <Object?>[
          null,
          true,
          12,
          1.25,
          'generated text',
          [1, 'two', null],
          {
            'total': 7,
            'items': ['a', 'b'],
          },
        ]) {
          expect(result.snapshotJsonResult(value), value);
        }
        final mutable = <String, Object?>{
          'items': <Object?>['original'],
        };
        final frozen = result.snapshotJsonResult(mutable)! as Map;
        (mutable['items']! as List).clear();
        expect(frozen['items'], ['original']);
        expect(
          () => (frozen['items']! as List).clear(),
          throwsUnsupportedError,
        );
        expect(
          () => result.snapshotJsonResult('x' * 65537),
          throwsFormatException,
        );
        expect(
          () => result.snapshotJsonResult(double.nan),
          throwsFormatException,
        );
        expect(
          () => result.snapshotJsonResult(Object()),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'game authority and game-state isolation cannot be inferred from app data',
    () {
      final descriptor = AppInvocationDescriptor.fromValidatedBundle(
        bundle: SurfacePlayExampleFactory.build(
          projectId: 'pb_project_00000000-0000-0000-0000-000000000001',
          revisionId: 'pb_revision_00000000-0000-0000-0000-000000000002',
          contentManifestId: 'pb_manifest_00000000-0000-0000-0000-000000000003',
          requirementDigest: 'a' * 64,
          rulesId: 'gomoku.v1',
        ),
        scopeKey: 'test|owner',
      );
      expect(
        _assess(
          descriptor,
          runtime: _runtime(
            descriptor,
            protocol: AppInvocationRuntimeProtocol.trustedGameControl,
          ),
          isolation: _isolation(descriptor),
        ).reasons,
        ['game_authority_boundary_unverified'],
      );
      final withoutGameState = AppInvocationIsolationBoundary.values.toSet()
        ..remove(AppInvocationIsolationBoundary.gameState);
      expect(
        _assess(
          descriptor,
          runtime: _runtime(
            descriptor,
            supportsGame: true,
            protocol: AppInvocationRuntimeProtocol.trustedGameControl,
          ),
          isolation: _isolation(descriptor, boundaries: withoutGameState),
        ).reasons,
        ['isolation_missing:gameState'],
      );
    },
  );

  test(
    'evidence collections are snapshots rather than mutable permissions',
    () {
      final descriptor = _descriptor();
      final actions = {'text.decorate'};
      final boundaries = AppInvocationIsolationBoundary.values.toSet();
      final runtime = _runtime(descriptor, actions: actions);
      final isolation = _isolation(descriptor, boundaries: boundaries);
      actions.clear();
      boundaries.clear();
      expect(runtime.implementedActionNames, {'text.decorate'});
      expect(
        isolation.verifiedBoundaries,
        AppInvocationIsolationBoundary.values.toSet(),
      );
      expect(
        () => runtime.implementedActionNames.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => isolation.verifiedBoundaries.clear(),
        throwsUnsupportedError,
      );
    },
  );
}
