import 'app_invocation_descriptor.dart';

/// Protocol identities only. Availability requires a current native host probe;
/// these versions never confer permission or certify a particular work.
abstract final class AppInvocationRuntimeRegistry {
  static ({String id, String version}) identityFor(
    AppInvocationRuntimeKind kind,
  ) => switch (kind) {
    AppInvocationRuntimeKind.surfaceWebApp ||
    AppInvocationRuntimeKind.legacySurface => (
      id: 'maaso.surface-invocation',
      version: '2',
    ),
    AppInvocationRuntimeKind.workerCanvas => (
      id: 'maaso.worker-invocation',
      version: '1',
    ),
    AppInvocationRuntimeKind.projectBundleApplet => (
      id: 'maaso.project-control-invocation',
      version: '1',
    ),
    AppInvocationRuntimeKind.trustedGame => (
      id: 'maaso.surface-play-invocation',
      version: '1',
    ),
  };
}
