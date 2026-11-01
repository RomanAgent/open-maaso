import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';

typedef DesktopLocalAsrSupportDirectoryProvider = Future<String> Function();

typedef DesktopLocalAsrFileDigestProvider =
    Future<String> Function(String absoluteFilePath);

typedef DesktopLocalAsrStagingDelete =
    Future<void> Function(String absoluteDirectoryPath);

enum DesktopLocalAsrPackRuntimeLifecycle { active, sealing, retired }

enum DesktopLocalAsrPackOperationPhase {
  admitted,
  sourceValidated,
  stagingPrepared,
  fileCopied,
  beforeCommit,
  committed,
  resolved,
}

typedef DesktopLocalAsrPackOperationObserver =
    Future<void> Function(DesktopLocalAsrPackOperationPhase phase);

enum DesktopLocalAsrPackIssue {
  unsupportedHost,
  runtimeRetired,
  staleMount,
  unknownModel,
  unsafeSourcePath,
  unsafeFilesystemEntry,
  missingFile,
  extraFile,
  wrongFileSize,
  wrongFileDigest,
  licenseAcknowledgementRequired,
  legalApprovalRequired,
  installedPackInvalid,
  ioFailure,
}

final class DesktopLocalAsrPackException implements Exception {
  const DesktopLocalAsrPackException(this.issue);

  final DesktopLocalAsrPackIssue issue;

  @override
  String toString() => 'DesktopLocalAsrPackException(${issue.name})';
}

/// Non-sensitive operation counters. Source paths, PCM, and transcripts are
/// never retained here.
final class DesktopLocalAsrPackRuntimeState {
  const DesktopLocalAsrPackRuntimeState({
    required this.lifecycle,
    required this.activeOperationCount,
    required this.completedOperationCount,
    required this.failedOperationCount,
    required this.lastIssue,
  });

  const DesktopLocalAsrPackRuntimeState.initial()
    : lifecycle = DesktopLocalAsrPackRuntimeLifecycle.active,
      activeOperationCount = 0,
      completedOperationCount = 0,
      failedOperationCount = 0,
      lastIssue = null;

  final DesktopLocalAsrPackRuntimeLifecycle lifecycle;
  final int activeOperationCount;
  final int completedOperationCount;
  final int failedOperationCount;
  final DesktopLocalAsrPackIssue? lastIssue;
}

final class DesktopLocalAsrVerifiedPack {
  const DesktopLocalAsrVerifiedPack({
    required this.descriptor,
    required this.directoryPath,
  });

  final DesktopLocalAsrModelDescriptor descriptor;
  final String directoryPath;
}

final class DesktopLocalAsrPackImportResult {
  const DesktopLocalAsrPackImportResult({
    required this.verifiedPack,
    required this.alreadyInstalled,
  });

  final DesktopLocalAsrVerifiedPack verifiedPack;
  final bool alreadyInstalled;
}

/// Account-owned local-ASR model-pack boundary.
///
/// Implementations accept user directories only. There is deliberately no
/// URL/download API on this contract. The selected directory is a strict
/// runtime-only payload: upstream README/LICENSE files remain outside it and
/// the pinned license reference is presented separately by the settings UI.
abstract interface class DesktopLocalAsrPackRuntime
    implements DesktopLocalAsrModelAvailability {
  bool get supported;

  String get accountScopeDigest;

  int get generation;

  DesktopLocalAsrPackRuntimeState get state;

  List<DesktopLocalAsrModelDescriptor> get descriptors;

  Future<DesktopLocalAsrPackImportResult> importUserDirectory({
    required String modelId,
    required String sourceDirectoryPath,
    bool licenseAcknowledged = false,
  });

  Future<DesktopLocalAsrVerifiedPack?> resolve(
    DesktopLocalAsrModelPack modelPack,
  );

  /// Resolves immediately before a native worker opens model files. Hosts
  /// whose file metadata cannot prove content identity may force a full hash
  /// here while keeping per-segment [isAvailable] checks lightweight.
  Future<DesktopLocalAsrVerifiedPack?> resolveForRecognition(
    DesktopLocalAsrModelPack modelPack,
  );

  /// Stops admission and waits for every admitted import/verification before
  /// removing only this runtime's staging directories.
  Future<void> sealAndDrain();
}

final class UnsupportedDesktopLocalAsrPackRuntime
    implements DesktopLocalAsrPackRuntime {
  UnsupportedDesktopLocalAsrPackRuntime({
    required this.accountScopeDigest,
    required this.generation,
    Iterable<DesktopLocalAsrModelDescriptor> descriptors = const [],
  }) : descriptors = List<DesktopLocalAsrModelDescriptor>.unmodifiable(
         descriptors,
       );

  @override
  final String accountScopeDigest;

  @override
  final int generation;

  @override
  final List<DesktopLocalAsrModelDescriptor> descriptors;

  var _state = const DesktopLocalAsrPackRuntimeState.initial();

  @override
  bool get supported => false;

  @override
  DesktopLocalAsrPackRuntimeState get state => _state;

  @override
  Future<DesktopLocalAsrPackImportResult> importUserDirectory({
    required String modelId,
    required String sourceDirectoryPath,
    bool licenseAcknowledged = false,
  }) => Future<DesktopLocalAsrPackImportResult>.error(
    const DesktopLocalAsrPackException(
      DesktopLocalAsrPackIssue.unsupportedHost,
    ),
  );

  @override
  Future<bool> isAvailable(DesktopLocalAsrModelPack modelPack) async => false;

  @override
  Future<DesktopLocalAsrVerifiedPack?> resolve(
    DesktopLocalAsrModelPack modelPack,
  ) async => null;

  @override
  Future<DesktopLocalAsrVerifiedPack?> resolveForRecognition(
    DesktopLocalAsrModelPack modelPack,
  ) async => null;

  @override
  Future<void> sealAndDrain() async {
    _state = DesktopLocalAsrPackRuntimeState(
      lifecycle: DesktopLocalAsrPackRuntimeLifecycle.retired,
      activeOperationCount: 0,
      completedOperationCount: _state.completedOperationCount,
      failedOperationCount: _state.failedOperationCount,
      lastIssue: _state.lastIssue,
    );
  }
}
