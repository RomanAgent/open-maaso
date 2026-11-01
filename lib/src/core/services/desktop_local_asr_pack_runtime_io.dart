import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime_contract.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

DesktopLocalAsrPackRuntime createDesktopLocalAsrPackRuntime({
  required AppPlatformCapabilities platformCapabilities,
  required String accountScopeDigest,
  required int generation,
  required DesktopLocalAsrMountFence isCurrentMount,
  Iterable<DesktopLocalAsrModelDescriptor>? descriptors,
  DesktopLocalAsrSupportDirectoryProvider? supportDirectoryProvider,
  DesktopLocalAsrFileDigestProvider? fileDigestProvider,
  DesktopLocalAsrStagingDelete? stagingDelete,
  DesktopLocalAsrPackOperationObserver? operationObserver,
}) {
  final selectedDescriptors = descriptors ?? DesktopLocalAsrModelCatalog.all;
  if (!_isDesktop(platformCapabilities.platform)) {
    return UnsupportedDesktopLocalAsrPackRuntime(
      accountScopeDigest: accountScopeDigest,
      generation: generation,
      descriptors: selectedDescriptors,
    );
  }
  return IoDesktopLocalAsrPackRuntime(
    accountScopeDigest: accountScopeDigest,
    generation: generation,
    isCurrentMount: isCurrentMount,
    descriptors: selectedDescriptors,
    supportDirectoryProvider:
        supportDirectoryProvider ?? _applicationSupportDirectoryPath,
    fileDigestProvider: fileDigestProvider ?? _sha256File,
    stagingDelete: stagingDelete ?? _deleteDirectoryRecursively,
    forceFullHashBeforeRecognition:
        platformCapabilities.platform == AppHostPlatform.windows,
    operationObserver: operationObserver,
  );
}

final class IoDesktopLocalAsrPackRuntime implements DesktopLocalAsrPackRuntime {
  IoDesktopLocalAsrPackRuntime({
    required String accountScopeDigest,
    required this.generation,
    required DesktopLocalAsrMountFence isCurrentMount,
    required Iterable<DesktopLocalAsrModelDescriptor> descriptors,
    required DesktopLocalAsrSupportDirectoryProvider supportDirectoryProvider,
    required DesktopLocalAsrFileDigestProvider fileDigestProvider,
    required DesktopLocalAsrStagingDelete stagingDelete,
    required bool forceFullHashBeforeRecognition,
    DesktopLocalAsrPackOperationObserver? operationObserver,
  }) : accountScopeDigest = _checkedAccountScopeDigest(accountScopeDigest),
       _isCurrentMount = isCurrentMount,
       _supportDirectoryProvider = supportDirectoryProvider,
       _fileDigestProvider = fileDigestProvider,
       _stagingDelete = stagingDelete,
       _forceFullHashBeforeRecognition = forceFullHashBeforeRecognition,
       _operationObserver = operationObserver,
       _descriptorsById = _indexDescriptors(descriptors) {
    if (generation < 1) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
  }

  static const String verifiedManifestName =
      '.maaso-desktop-local-asr-pack-v1.json';

  @override
  final String accountScopeDigest;

  @override
  final int generation;

  final DesktopLocalAsrMountFence _isCurrentMount;
  final DesktopLocalAsrSupportDirectoryProvider _supportDirectoryProvider;
  final DesktopLocalAsrFileDigestProvider _fileDigestProvider;
  final DesktopLocalAsrStagingDelete _stagingDelete;
  final bool _forceFullHashBeforeRecognition;
  final DesktopLocalAsrPackOperationObserver? _operationObserver;
  final Map<String, DesktopLocalAsrModelDescriptor> _descriptorsById;
  final Set<Future<void>> _activeOperations = <Future<void>>{};
  final Set<String> _stagingPaths = <String>{};
  final Map<String, _VerifiedDirectorySnapshot> _verifiedDirectories =
      <String, _VerifiedDirectorySnapshot>{};

  var _state = const DesktopLocalAsrPackRuntimeState.initial();
  bool _sealed = false;
  Future<void>? _retirement;
  int _stagingSequence = 0;

  @override
  bool get supported => true;

  @override
  DesktopLocalAsrPackRuntimeState get state => _state;

  @override
  List<DesktopLocalAsrModelDescriptor> get descriptors =>
      List<DesktopLocalAsrModelDescriptor>.unmodifiable(
        _descriptorsById.values,
      );

  @override
  Future<DesktopLocalAsrPackImportResult> importUserDirectory({
    required String modelId,
    required String sourceDirectoryPath,
    bool licenseAcknowledged = false,
  }) => _trackOperation(() async {
    try {
      await _observe(DesktopLocalAsrPackOperationPhase.admitted);
      _ensureCurrent();
      final descriptor = _descriptorFor(modelId);
      _invalidateDescriptor(descriptor);
      // Legal approval is not a caller assertion. Until a separately designed,
      // trusted authority exists, gated descriptors remain unreachable.
      if (descriptor.requiresLegalApproval) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.legalApprovalRequired,
        );
      }
      if (descriptor.requiresLicenseAcknowledgement && !licenseAcknowledged) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.licenseAcknowledgementRequired,
        );
      }

      final source = await _validateSourceDirectory(
        descriptor,
        sourceDirectoryPath,
      );
      await _observe(DesktopLocalAsrPackOperationPhase.sourceValidated);
      _ensureCurrent();

      final parent = (await _modelCacheParent(descriptor, create: true))!;
      final destination = Directory(
        p.join(parent.path, descriptor.contentDigest),
      );
      final destinationType = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (destinationType != FileSystemEntityType.notFound) {
        if (destinationType != FileSystemEntityType.directory) {
          throw const DesktopLocalAsrPackException(
            DesktopLocalAsrPackIssue.installedPackInvalid,
          );
        }
        try {
          await _verifyInstalledDirectory(
            destination,
            descriptor,
            cacheResult: true,
          );
        } on DesktopLocalAsrPackException {
          // Existing user data is never automatically removed or overwritten.
          throw const DesktopLocalAsrPackException(
            DesktopLocalAsrPackIssue.installedPackInvalid,
          );
        }
        _ensureCurrent();
        return DesktopLocalAsrPackImportResult(
          verifiedPack: DesktopLocalAsrVerifiedPack(
            descriptor: descriptor,
            directoryPath: destination.path,
          ),
          alreadyInstalled: true,
        );
      }

      Directory? staging;
      try {
        staging = await _createStagingDirectory(parent, descriptor);
        _stagingPaths.add(staging.path);
        await _observe(DesktopLocalAsrPackOperationPhase.stagingPrepared);
        _ensureCurrent();

        for (final file in descriptor.files) {
          _ensureCurrent();
          final sourceFile = File(p.join(source.path, file.name));
          await _requireRegularFile(sourceFile, file);
          final destinationFile = File(p.join(staging.path, file.name));
          await sourceFile.openRead().pipe(destinationFile.openWrite());
          await _requireRegularFile(sourceFile, file);
          await _requireRegularFile(destinationFile, file);
          await _observe(DesktopLocalAsrPackOperationPhase.fileCopied);
        }

        await File(
          p.join(staging.path, verifiedManifestName),
        ).writeAsString(_verifiedManifest(descriptor), flush: true);
        await _verifyInstalledDirectory(staging, descriptor);
        await _observe(DesktopLocalAsrPackOperationPhase.beforeCommit);
        _ensureCurrent();

        final committed = await staging.rename(destination.path);
        _stagingPaths.remove(staging.path);
        staging = null;
        await _verifyInstalledDirectory(
          committed,
          descriptor,
          cacheResult: true,
        );
        await _observe(DesktopLocalAsrPackOperationPhase.committed);
        _ensureCurrent();
        return DesktopLocalAsrPackImportResult(
          verifiedPack: DesktopLocalAsrVerifiedPack(
            descriptor: descriptor,
            directoryPath: committed.path,
          ),
          alreadyInstalled: false,
        );
      } finally {
        if (staging != null) {
          await _deleteTrackedStaging(staging);
        }
      }
    } on DesktopLocalAsrPackException {
      rethrow;
    } on FileSystemException {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.ioFailure,
      );
    } on FormatException {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.ioFailure,
      );
    }
  });

  @override
  Future<bool> isAvailable(DesktopLocalAsrModelPack modelPack) async {
    try {
      return await resolve(modelPack) != null;
    } on Object {
      return false;
    }
  }

  @override
  Future<DesktopLocalAsrVerifiedPack?> resolve(
    DesktopLocalAsrModelPack modelPack,
  ) => _resolve(modelPack, forceFullHash: false);

  @override
  Future<DesktopLocalAsrVerifiedPack?> resolveForRecognition(
    DesktopLocalAsrModelPack modelPack,
  ) => _resolve(modelPack, forceFullHash: _forceFullHashBeforeRecognition);

  Future<DesktopLocalAsrVerifiedPack?> _resolve(
    DesktopLocalAsrModelPack modelPack, {
    required bool forceFullHash,
  }) => _trackOperation(() async {
    try {
      await _observe(DesktopLocalAsrPackOperationPhase.admitted);
      _ensureCurrent();
      final descriptor = _descriptorFor(modelPack.id);
      if (descriptor.requiresLegalApproval) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.legalApprovalRequired,
        );
      }
      final parent = await _modelCacheParent(descriptor, create: false);
      if (parent == null) return null;
      final destination = Directory(
        p.join(parent.path, descriptor.contentDigest),
      );
      final type = await FileSystemEntity.type(
        destination.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.directory) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.installedPackInvalid,
        );
      }
      try {
        final cached = _verifiedDirectories[destination.path];
        if (forceFullHash ||
            cached == null ||
            !await _matchesVerifiedSnapshot(destination, descriptor, cached)) {
          _verifiedDirectories.remove(destination.path);
          await _verifyInstalledDirectory(
            destination,
            descriptor,
            cacheResult: true,
          );
        }
      } on DesktopLocalAsrPackException {
        _verifiedDirectories.remove(destination.path);
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.installedPackInvalid,
        );
      }
      await _observe(DesktopLocalAsrPackOperationPhase.resolved);
      _ensureCurrent();
      return DesktopLocalAsrVerifiedPack(
        descriptor: descriptor,
        directoryPath: destination.path,
      );
    } on DesktopLocalAsrPackException {
      rethrow;
    } on FileSystemException {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.ioFailure,
      );
    }
  });

  @override
  Future<void> sealAndDrain() {
    final existing = _retirement;
    if (existing != null) return existing;
    _sealed = true;
    _verifiedDirectories.clear();
    _publish(lifecycle: DesktopLocalAsrPackRuntimeLifecycle.sealing);
    late final Future<void> retirement;
    retirement = _drainStrictly().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      if (identical(_retirement, retirement)) _retirement = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
    _retirement = retirement;
    return retirement;
  }

  Future<void> _drainStrictly() async {
    final admitted = List<Future<void>>.of(_activeOperations);
    if (admitted.isNotEmpty) {
      await Future.wait<void>(admitted);
    }
    for (final stagingPath in List<String>.of(_stagingPaths)) {
      await _deleteTrackedStaging(Directory(stagingPath));
    }
    _publish(lifecycle: DesktopLocalAsrPackRuntimeLifecycle.retired);
  }

  Future<T> _trackOperation<T>(Future<T> Function() operation) {
    if (_sealed) {
      return Future<T>.error(
        const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.runtimeRetired,
        ),
      );
    }
    _publish(activeOperationDelta: 1, clearIssue: true);
    final result = Future<T>.sync(operation);
    final tracked = result.then<T>(
      (value) {
        _publish(activeOperationDelta: -1, completedOperationDelta: 1);
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        _verifiedDirectories.clear();
        final issue = error is DesktopLocalAsrPackException
            ? error.issue
            : DesktopLocalAsrPackIssue.ioFailure;
        _publish(
          activeOperationDelta: -1,
          failedOperationDelta: 1,
          lastIssue: issue,
        );
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    late final Future<void> drain;
    drain = tracked
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _activeOperations.remove(drain);
        });
    _activeOperations.add(drain);
    return tracked;
  }

  Future<Directory> _validateSourceDirectory(
    DesktopLocalAsrModelDescriptor descriptor,
    String sourceDirectoryPath,
  ) async {
    if (!_isSafeAbsoluteUserPath(sourceDirectoryPath)) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.unsafeSourcePath,
      );
    }
    final source = Directory(p.normalize(sourceDirectoryPath));
    final rootType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory) {
      throw DesktopLocalAsrPackException(
        rootType == FileSystemEntityType.link
            ? DesktopLocalAsrPackIssue.unsafeFilesystemEntry
            : DesktopLocalAsrPackIssue.unsafeSourcePath,
      );
    }

    final expected = <String>{for (final file in descriptor.files) file.name};
    final observed = <String>{};
    await for (final entry in source.list(followLinks: false)) {
      final relative = p.relative(entry.path, from: source.path);
      if (relative == '.' ||
          p.dirname(relative) != '.' ||
          !_isSafeBasename(relative)) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
        );
      }
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
        );
      }
      if (!expected.contains(relative)) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.extraFile,
        );
      }
      observed.add(relative);
    }
    if (!observed.containsAll(expected)) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.missingFile,
      );
    }
    for (final file in descriptor.files) {
      await _requireRegularFile(File(p.join(source.path, file.name)), file);
    }
    return source;
  }

  Future<Directory?> _modelCacheParent(
    DesktopLocalAsrModelDescriptor descriptor, {
    required bool create,
  }) async {
    final supportPath = p.normalize(await _supportDirectoryProvider());
    if (!p.isAbsolute(supportPath)) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.ioFailure,
      );
    }
    var current = Directory(supportPath);
    var type = await FileSystemEntity.type(current.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await current.create(recursive: true);
      type = await FileSystemEntity.type(current.path, followLinks: false);
    }
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
      );
    }

    for (final segment in <String>[
      'maaso',
      'desktop_local_asr',
      'v1',
      accountScopeDigest,
      descriptor.id,
    ]) {
      current = Directory(p.join(current.path, segment));
      type = await FileSystemEntity.type(current.path, followLinks: false);
      if (type == FileSystemEntityType.notFound && create) {
        await current.create();
        type = await FileSystemEntity.type(current.path, followLinks: false);
      }
      if (type == FileSystemEntityType.notFound) return null;
      if (type != FileSystemEntityType.directory) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
        );
      }
    }
    return current;
  }

  Future<Directory> _createStagingDirectory(
    Directory parent,
    DesktopLocalAsrModelDescriptor descriptor,
  ) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final sequence = ++_stagingSequence;
      final candidate = Directory(
        p.join(
          parent.path,
          '.staging-${descriptor.contentDigest.substring(0, 12)}-'
          '$generation-$sequence',
        ),
      );
      final type = await FileSystemEntity.type(
        candidate.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        await candidate.create();
        return candidate;
      }
    }
    throw const DesktopLocalAsrPackException(
      DesktopLocalAsrPackIssue.ioFailure,
    );
  }

  Future<void> _verifyInstalledDirectory(
    Directory directory,
    DesktopLocalAsrModelDescriptor descriptor, {
    bool cacheResult = false,
  }) async {
    final verifiedFiles = <String, _VerifiedFileStat>{};
    final expected = <String>{
      for (final file in descriptor.files) file.name,
      verifiedManifestName,
    };
    final observed = <String>{};
    await for (final entry in directory.list(followLinks: false)) {
      final relative = p.relative(entry.path, from: directory.path);
      if (p.dirname(relative) != '.' || !_isSafeBasename(relative)) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
        );
      }
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
        );
      }
      if (!expected.contains(relative)) {
        throw const DesktopLocalAsrPackException(
          DesktopLocalAsrPackIssue.extraFile,
        );
      }
      observed.add(relative);
    }
    if (!observed.containsAll(expected)) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.missingFile,
      );
    }
    for (final file in descriptor.files) {
      verifiedFiles[file.name] = await _requireRegularFile(
        File(p.join(directory.path, file.name)),
        file,
      );
    }
    final manifest = File(p.join(directory.path, verifiedManifestName));
    final manifestBefore = await manifest.stat();
    if (manifestBefore.type != FileSystemEntityType.file ||
        manifestBefore.size > 65536 ||
        await manifest.readAsString() != _verifiedManifest(descriptor)) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.installedPackInvalid,
      );
    }
    final manifestAfter = await manifest.stat();
    final verifiedManifestStat = _VerifiedFileStat.fromFileStat(manifestAfter);
    if (!verifiedManifestStat.sameIdentity(
      _VerifiedFileStat.fromFileStat(manifestBefore),
    )) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.installedPackInvalid,
      );
    }
    if (cacheResult) {
      _verifiedDirectories[directory.path] = _VerifiedDirectorySnapshot(
        contentDigest: descriptor.contentDigest,
        files: Map<String, _VerifiedFileStat>.unmodifiable(verifiedFiles),
        manifest: verifiedManifestStat,
      );
    }
  }

  Future<_VerifiedFileStat> _requireRegularFile(
    File file,
    DesktopLocalAsrModelFileDescriptor descriptor,
  ) async {
    final before = await file.stat();
    if (before.type == FileSystemEntityType.notFound) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.missingFile,
      );
    }
    if (before.type != FileSystemEntityType.file) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
      );
    }
    if (before.size != descriptor.byteLength) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.wrongFileSize,
      );
    }
    final digest = await _fileDigestProvider(file.path);
    if (digest != descriptor.sha256Digest) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.wrongFileDigest,
      );
    }
    final after = await file.stat();
    final beforeIdentity = _VerifiedFileStat.fromFileStat(before);
    final afterIdentity = _VerifiedFileStat.fromFileStat(after);
    if (after.type != FileSystemEntityType.file ||
        after.size != descriptor.byteLength ||
        !afterIdentity.sameIdentity(beforeIdentity)) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.installedPackInvalid,
      );
    }
    return afterIdentity;
  }

  Future<bool> _matchesVerifiedSnapshot(
    Directory directory,
    DesktopLocalAsrModelDescriptor descriptor,
    _VerifiedDirectorySnapshot snapshot,
  ) async {
    if (snapshot.contentDigest != descriptor.contentDigest) return false;
    final expected = <String>{
      for (final file in descriptor.files) file.name,
      verifiedManifestName,
    };
    final observed = <String>{};
    await for (final entry in directory.list(followLinks: false)) {
      final relative = p.relative(entry.path, from: directory.path);
      if (p.dirname(relative) != '.' ||
          !_isSafeBasename(relative) ||
          !expected.contains(relative) ||
          await FileSystemEntity.type(entry.path, followLinks: false) !=
              FileSystemEntityType.file) {
        return false;
      }
      observed.add(relative);
    }
    if (!observed.containsAll(expected)) return false;
    for (final file in descriptor.files) {
      final expectedStat = snapshot.files[file.name];
      if (expectedStat == null) return false;
      final current = await File(p.join(directory.path, file.name)).stat();
      if (!_VerifiedFileStat.fromFileStat(current).sameIdentity(expectedStat)) {
        return false;
      }
    }
    final manifest = File(p.join(directory.path, verifiedManifestName));
    final manifestStat = await manifest.stat();
    if (!_VerifiedFileStat.fromFileStat(
          manifestStat,
        ).sameIdentity(snapshot.manifest) ||
        await manifest.readAsString() != _verifiedManifest(descriptor)) {
      return false;
    }
    return true;
  }

  void _invalidateDescriptor(DesktopLocalAsrModelDescriptor descriptor) {
    _verifiedDirectories.removeWhere(
      (path, _) => p.basename(path) == descriptor.contentDigest,
    );
  }

  Future<void> _deleteTrackedStaging(Directory staging) async {
    if (!_stagingPaths.contains(staging.path)) return;
    final type = await FileSystemEntity.type(staging.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _stagingPaths.remove(staging.path);
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.unsafeFilesystemEntry,
      );
    }
    await _stagingDelete(staging.path);
    _stagingPaths.remove(staging.path);
  }

  DesktopLocalAsrModelDescriptor _descriptorFor(String modelId) {
    final descriptor = _descriptorsById[modelId.trim()];
    if (descriptor == null) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.unknownModel,
      );
    }
    return descriptor;
  }

  void _ensureCurrent() {
    if (_sealed) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.runtimeRetired,
      );
    }
    var current = false;
    try {
      current = _isCurrentMount(
        accountScopeDigest: accountScopeDigest,
        generation: generation,
      );
    } on Object {
      current = false;
    }
    if (!current) {
      throw const DesktopLocalAsrPackException(
        DesktopLocalAsrPackIssue.staleMount,
      );
    }
  }

  Future<void> _observe(DesktopLocalAsrPackOperationPhase phase) async {
    final observer = _operationObserver;
    if (observer != null) await observer(phase);
  }

  void _publish({
    DesktopLocalAsrPackRuntimeLifecycle? lifecycle,
    int activeOperationDelta = 0,
    int completedOperationDelta = 0,
    int failedOperationDelta = 0,
    DesktopLocalAsrPackIssue? lastIssue,
    bool clearIssue = false,
  }) {
    final current = _state;
    _state = DesktopLocalAsrPackRuntimeState(
      lifecycle: lifecycle ?? current.lifecycle,
      activeOperationCount: current.activeOperationCount + activeOperationDelta,
      completedOperationCount:
          current.completedOperationCount + completedOperationDelta,
      failedOperationCount: current.failedOperationCount + failedOperationDelta,
      lastIssue: clearIssue ? null : lastIssue ?? current.lastIssue,
    );
  }
}

Future<String> _applicationSupportDirectoryPath() async =>
    (await getApplicationSupportDirectory()).path;

bool _isDesktop(AppHostPlatform platform) =>
    platform == AppHostPlatform.macos ||
    platform == AppHostPlatform.windows ||
    platform == AppHostPlatform.linux;

bool _isSafeAbsoluteUserPath(String value) {
  if (value.isEmpty || value.contains('\u0000') || !p.isAbsolute(value)) {
    return false;
  }
  final segments = p.split(value);
  return !segments.contains('..') && p.normalize(value) == value;
}

bool _isSafeBasename(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.contains('/') &&
    !value.contains('\\') &&
    !value.contains('\u0000');

String _checkedAccountScopeDigest(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw ArgumentError.value(
      value,
      'accountScopeDigest',
      'must be a lowercase SHA-256 digest',
    );
  }
  return normalized;
}

Map<String, DesktopLocalAsrModelDescriptor> _indexDescriptors(
  Iterable<DesktopLocalAsrModelDescriptor> values,
) {
  final result = <String, DesktopLocalAsrModelDescriptor>{};
  for (final descriptor in values) {
    if (result.containsKey(descriptor.id)) {
      throw ArgumentError.value(
        descriptor.id,
        'descriptors',
        'contains a duplicate',
      );
    }
    result[descriptor.id] = descriptor;
  }
  if (result.isEmpty) {
    throw ArgumentError.value(values, 'descriptors', 'must not be empty');
  }
  return Map<String, DesktopLocalAsrModelDescriptor>.unmodifiable(result);
}

String _verifiedManifest(DesktopLocalAsrModelDescriptor descriptor) =>
    jsonEncode(<String, Object>{
      'schemaVersion': 1,
      'kind': 'maaso.desktop_local_asr.verified_pack',
      'modelId': descriptor.id,
      'engine': descriptor.engine.name,
      'sourceRevision': descriptor.sourceRevision,
      'contentDigest': descriptor.contentDigest,
      'license': <String, Object>{
        'id': descriptor.licenseId,
        'requiresLicenseAcknowledgement':
            descriptor.requiresLicenseAcknowledgement,
        'requiresLegalApproval': descriptor.requiresLegalApproval,
      },
      'files': <Map<String, Object>>[
        for (final file in descriptor.files)
          <String, Object>{
            'name': file.name,
            'byteLength': file.byteLength,
            'sha256': file.sha256Digest,
          },
      ],
    });

Future<String> _sha256File(String absoluteFilePath) async =>
    (await sha256.bind(File(absoluteFilePath).openRead()).single).toString();

Future<void> _deleteDirectoryRecursively(String absoluteDirectoryPath) =>
    Directory(absoluteDirectoryPath).delete(recursive: true);

final class _VerifiedDirectorySnapshot {
  const _VerifiedDirectorySnapshot({
    required this.contentDigest,
    required this.files,
    required this.manifest,
  });

  final String contentDigest;
  final Map<String, _VerifiedFileStat> files;
  final _VerifiedFileStat manifest;
}

final class _VerifiedFileStat {
  const _VerifiedFileStat({
    required this.size,
    required this.modifiedMicroseconds,
    required this.changedMicroseconds,
    required this.mode,
  });

  factory _VerifiedFileStat.fromFileStat(FileStat stat) => _VerifiedFileStat(
    size: stat.size,
    modifiedMicroseconds: stat.modified.microsecondsSinceEpoch,
    changedMicroseconds: stat.changed.microsecondsSinceEpoch,
    mode: stat.mode,
  );

  final int size;
  final int modifiedMicroseconds;
  final int changedMicroseconds;
  final int mode;

  bool sameIdentity(_VerifiedFileStat other) =>
      size == other.size &&
      modifiedMicroseconds == other.modifiedMicroseconds &&
      changedMicroseconds == other.changedMicroseconds &&
      mode == other.mode;
}
