import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime_contract.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime_io.dart';
import 'package:path/path.dart' as p;

void main() {
  group('IoDesktopLocalAsrPackRuntime', () {
    late Directory sandbox;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('maaso-asr-pack-test-');
    });

    tearDown(() async {
      if (await sandbox.exists()) {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'imports exact files into an account-scoped content address',
      () async {
        final source = await _sourceDirectory(sandbox, <String, List<int>>{
          'model.onnx': <int>[1, 2, 3, 4],
        });
        final descriptor = _tinyDescriptor(
          files: <String, List<int>>{
            'model.onnx': <int>[1, 2, 3, 4],
          },
        );
        final mount = _Mount();
        final runtime = _runtime(sandbox, mount, descriptor);

        final result = await runtime.importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: source.path,
        );

        expect(result.alreadyInstalled, isFalse);
        expect(result.verifiedPack.descriptor.id, descriptor.id);
        expect(
          result.verifiedPack.directoryPath,
          p.join(
            sandbox.path,
            'support',
            'maaso',
            'desktop_local_asr',
            'v1',
            _scope,
            descriptor.id,
            descriptor.contentDigest,
          ),
        );
        expect(
          await File(
            p.join(result.verifiedPack.directoryPath, 'model.onnx'),
          ).readAsBytes(),
          <int>[1, 2, 3, 4],
        );
        expect(await runtime.isAvailable(descriptor.coreModelPack), isTrue);
        final manifest = await File(
          p.join(
            result.verifiedPack.directoryPath,
            IoDesktopLocalAsrPackRuntime.verifiedManifestName,
          ),
        ).readAsString();
        expect(jsonDecode(manifest), isA<Map<String, Object?>>());
        expect(manifest, contains('"requiresLegalApproval":false'));
        expect(manifest, isNot(contains('legalApprovalRecorded')));
        expect(manifest, isNot(contains(source.path)));
        expect(manifest, isNot(contains('sourceDirectory')));
        expect(runtime.state.completedOperationCount, 2);
        expect(runtime.state.activeOperationCount, 0);

        final repeated = await runtime.importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: source.path,
        );
        expect(repeated.alreadyInstalled, isTrue);
        await runtime.sealAndDrain();
        expect(
          runtime.state.lifecycle,
          DesktopLocalAsrPackRuntimeLifecycle.retired,
        );
      },
    );

    test(
      'rejects missing, extra, wrong-size, and wrong-digest files',
      () async {
        final bytes = <String, List<int>>{
          'model.onnx': <int>[1, 2, 3, 4],
          'tokens.txt': utf8.encode('tokens'),
        };
        final descriptor = _tinyDescriptor(files: bytes);

        final missing = await _sourceDirectory(sandbox, <String, List<int>>{
          'model.onnx': bytes['model.onnx']!,
        }, name: 'missing');
        await expectLater(
          _runtime(sandbox, _Mount(), descriptor).importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: missing.path,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.missingFile),
        );

        final extra = await _sourceDirectory(sandbox, <String, List<int>>{
          ...bytes,
          'unexpected.txt': <int>[9],
        }, name: 'extra');
        await expectLater(
          _runtime(sandbox, _Mount(), descriptor).importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: extra.path,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.extraFile),
        );

        final wrongSize = await _sourceDirectory(sandbox, <String, List<int>>{
          'model.onnx': <int>[1],
          'tokens.txt': bytes['tokens.txt']!,
        }, name: 'wrong-size');
        await expectLater(
          _runtime(sandbox, _Mount(), descriptor).importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: wrongSize.path,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.wrongFileSize),
        );

        final wrongDigest = await _sourceDirectory(sandbox, <String, List<int>>{
          'model.onnx': <int>[4, 3, 2, 1],
          'tokens.txt': bytes['tokens.txt']!,
        }, name: 'wrong-digest');
        await expectLater(
          _runtime(sandbox, _Mount(), descriptor).importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: wrongDigest.path,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.wrongFileDigest),
        );
      },
    );

    test('rejects source links and traversal paths', () async {
      final descriptor = _tinyDescriptor(
        files: <String, List<int>>{
          'model.onnx': <int>[1, 2, 3],
        },
      );
      final outside = File(p.join(sandbox.path, 'outside.onnx'));
      await outside.writeAsBytes(<int>[1, 2, 3]);
      final source = await Directory(
        p.join(sandbox.path, 'linked-file-source'),
      ).create();
      await Link(p.join(source.path, 'model.onnx')).create(outside.path);

      await expectLater(
        _runtime(sandbox, _Mount(), descriptor).importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: source.path,
        ),
        _throwsIssue(DesktopLocalAsrPackIssue.unsafeFilesystemEntry),
      );

      final realSource = await _sourceDirectory(sandbox, <String, List<int>>{
        'model.onnx': <int>[1, 2, 3],
      }, name: 'real-source');
      final sourceLink = Link(p.join(sandbox.path, 'source-link'));
      await sourceLink.create(realSource.path);
      await expectLater(
        _runtime(sandbox, _Mount(), descriptor).importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: sourceLink.path,
        ),
        _throwsIssue(DesktopLocalAsrPackIssue.unsafeFilesystemEntry),
      );
      await expectLater(
        _runtime(sandbox, _Mount(), descriptor).importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: p.join(realSource.path, '..', 'real-source'),
        ),
        _throwsIssue(DesktopLocalAsrPackIssue.unsafeSourcePath),
      );
    });

    test(
      'legal-gated packs fail closed without a caller approval escape hatch',
      () async {
        final files = <String, List<int>>{
          'model.onnx': <int>[1, 2, 3],
        };
        final descriptor = _tinyDescriptor(files: files, gated: true);
        final source = await _sourceDirectory(sandbox, files);
        final runtime = _runtime(sandbox, _Mount(), descriptor);

        await expectLater(
          runtime.importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: source.path,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.legalApprovalRequired),
        );
        await expectLater(
          runtime.importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: source.path,
            licenseAcknowledged: true,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.legalApprovalRequired),
        );
        await expectLater(
          runtime.importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: source.path,
            licenseAcknowledged: true,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.legalApprovalRequired),
        );
        expect(
          await _installedPackDirectory(sandbox, descriptor).exists(),
          isFalse,
        );
      },
    );

    test(
      'legal gate blocks a hand-crafted exact cache on every resolve path',
      () async {
        final files = <String, List<int>>{
          'model.onnx': <int>[1, 2, 3],
        };
        final descriptor = _tinyDescriptor(files: files, gated: true);
        final installed = _installedPackDirectory(sandbox, descriptor);
        await installed.create(recursive: true);
        await File(
          p.join(installed.path, 'model.onnx'),
        ).writeAsBytes(files['model.onnx']!, flush: true);
        await File(
          p.join(
            installed.path,
            IoDesktopLocalAsrPackRuntime.verifiedManifestName,
          ),
        ).writeAsString(_manifestFor(descriptor), flush: true);
        final runtime = _runtime(sandbox, _Mount(), descriptor);

        await expectLater(
          runtime.resolve(descriptor.coreModelPack),
          _throwsIssue(DesktopLocalAsrPackIssue.legalApprovalRequired),
        );
        await expectLater(
          runtime.resolveForRecognition(descriptor.coreModelPack),
          _throwsIssue(DesktopLocalAsrPackIssue.legalApprovalRequired),
        );
        expect(await runtime.isAvailable(descriptor.coreModelPack), isFalse);
      },
    );

    test('rejects a stale mount before promotion and cleans staging', () async {
      final files = <String, List<int>>{
        'model.onnx': <int>[1, 2, 3, 4],
      };
      final descriptor = _tinyDescriptor(files: files);
      final source = await _sourceDirectory(sandbox, files);
      final mount = _Mount();
      final reached = Completer<void>();
      final release = Completer<void>();
      final runtime = _runtime(
        sandbox,
        mount,
        descriptor,
        observer: (phase) async {
          if (phase == DesktopLocalAsrPackOperationPhase.beforeCommit) {
            if (!reached.isCompleted) reached.complete();
            await release.future;
          }
        },
      );

      final importing = runtime.importUserDirectory(
        modelId: descriptor.id,
        sourceDirectoryPath: source.path,
      );
      await reached.future;
      mount.generation = 2;
      release.complete();

      await expectLater(
        importing,
        _throwsIssue(DesktopLocalAsrPackIssue.staleMount),
      );
      expect(await _stagingPaths(sandbox), isEmpty);
      expect(await runtime.isAvailable(descriptor.coreModelPack), isFalse);
    });

    test('sealAndDrain waits for admitted work and cleans staging', () async {
      final files = <String, List<int>>{
        'model.onnx': <int>[1, 2, 3, 4],
      };
      final descriptor = _tinyDescriptor(files: files);
      final source = await _sourceDirectory(sandbox, files);
      final reached = Completer<void>();
      final release = Completer<void>();
      final runtime = _runtime(
        sandbox,
        _Mount(),
        descriptor,
        observer: (phase) async {
          if (phase == DesktopLocalAsrPackOperationPhase.beforeCommit) {
            if (!reached.isCompleted) reached.complete();
            await release.future;
          }
        },
      );

      final importing = runtime.importUserDirectory(
        modelId: descriptor.id,
        sourceDirectoryPath: source.path,
      );
      await reached.future;
      var drained = false;
      final drain = runtime.sealAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(runtime.state.activeOperationCount, 1);
      release.complete();

      await expectLater(
        importing,
        _throwsIssue(DesktopLocalAsrPackIssue.runtimeRetired),
      );
      await drain;
      expect(drained, isTrue);
      expect(await _stagingPaths(sandbox), isEmpty);
      expect(
        runtime.state.lifecycle,
        DesktopLocalAsrPackRuntimeLifecycle.retired,
      );
      await expectLater(
        runtime.importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: source.path,
        ),
        _throwsIssue(DesktopLocalAsrPackIssue.runtimeRetired),
      );
    });

    test(
      'transient staging cleanup failure allows strict drain retry',
      () async {
        final files = <String, List<int>>{
          'model.onnx': <int>[1, 2, 3, 4],
        };
        final descriptor = _tinyDescriptor(files: files);
        final source = await _sourceDirectory(sandbox, files);
        final mount = _Mount();
        var deleteAttempts = 0;
        final runtime = _runtime(
          sandbox,
          mount,
          descriptor,
          observer: (phase) async {
            if (phase == DesktopLocalAsrPackOperationPhase.beforeCommit) {
              mount.generation = 2;
            }
          },
          stagingDelete: (path) async {
            deleteAttempts++;
            if (deleteAttempts <= 2) {
              throw FileSystemException('transient staging cleanup failure');
            }
            await Directory(path).delete(recursive: true);
          },
        );

        await expectLater(
          runtime.importUserDirectory(
            modelId: descriptor.id,
            sourceDirectoryPath: source.path,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.ioFailure),
        );
        expect(await _stagingPaths(sandbox), isNotEmpty);
        await expectLater(
          runtime.sealAndDrain(),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          runtime.state.lifecycle,
          DesktopLocalAsrPackRuntimeLifecycle.sealing,
        );

        await runtime.sealAndDrain();
        expect(deleteAttempts, 3);
        expect(await _stagingPaths(sandbox), isEmpty);
        expect(
          runtime.state.lifecycle,
          DesktopLocalAsrPackRuntimeLifecycle.retired,
        );
      },
    );

    test('never deletes or overwrites an invalid installed pack', () async {
      final files = <String, List<int>>{
        'model.onnx': <int>[1, 2, 3, 4],
      };
      final descriptor = _tinyDescriptor(files: files);
      final source = await _sourceDirectory(sandbox, files);
      final runtime = _runtime(sandbox, _Mount(), descriptor);
      final imported = await runtime.importUserDirectory(
        modelId: descriptor.id,
        sourceDirectoryPath: source.path,
      );
      final installedFile = File(
        p.join(imported.verifiedPack.directoryPath, 'model.onnx'),
      );
      await installedFile.writeAsBytes(<int>[4, 3, 2, 1], flush: true);

      expect(await runtime.isAvailable(descriptor.coreModelPack), isFalse);
      await expectLater(
        runtime.importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: source.path,
        ),
        _throwsIssue(DesktopLocalAsrPackIssue.installedPackInvalid),
      );
      expect(await installedFile.exists(), isTrue);
      expect(await installedFile.readAsBytes(), <int>[4, 3, 2, 1]);
    });

    test(
      'full hashes once then uses stat and manifest identity cache',
      () async {
        final files = <String, List<int>>{
          'model.onnx': <int>[1, 2, 3, 4],
        };
        final descriptor = _tinyDescriptor(files: files);
        final source = await _sourceDirectory(sandbox, files);
        var digestCount = 0;
        final runtime = _runtime(
          sandbox,
          _Mount(),
          descriptor,
          digestProvider: (path) async {
            digestCount++;
            return sha256.convert(await File(path).readAsBytes()).toString();
          },
        );
        final imported = await runtime.importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: source.path,
        );
        final importDigestCount = digestCount;
        expect(importDigestCount, greaterThan(0));

        expect(await runtime.isAvailable(descriptor.coreModelPack), isTrue);
        expect(await runtime.isAvailable(descriptor.coreModelPack), isTrue);
        expect(digestCount, importDigestCount);
        expect(
          await runtime.resolveForRecognition(descriptor.coreModelPack),
          isNotNull,
        );
        expect(digestCount, importDigestCount);

        await expectLater(
          runtime.importUserDirectory(
            modelId: 'unknown-model',
            sourceDirectoryPath: source.path,
          ),
          _throwsIssue(DesktopLocalAsrPackIssue.unknownModel),
        );
        final beforeRevalidation = digestCount;
        expect(await runtime.isAvailable(descriptor.coreModelPack), isTrue);
        expect(digestCount, greaterThan(beforeRevalidation));
        final revalidatedDigestCount = digestCount;

        await Future<void>.delayed(const Duration(milliseconds: 5));
        await File(
          p.join(imported.verifiedPack.directoryPath, 'model.onnx'),
        ).writeAsBytes(<int>[4, 3, 2, 1], flush: true);
        expect(await runtime.isAvailable(descriptor.coreModelPack), isFalse);
        expect(digestCount, greaterThan(revalidatedDigestCount));
      },
    );

    test(
      'Windows rehashes before worker load but not on each availability check',
      () async {
        final files = <String, List<int>>{
          'model.onnx': <int>[1, 2, 3, 4],
        };
        final descriptor = _tinyDescriptor(files: files);
        final source = await _sourceDirectory(sandbox, files);
        var digestCount = 0;
        final runtime = _runtime(
          sandbox,
          _Mount(),
          descriptor,
          platform: AppHostPlatform.windows,
          digestProvider: (path) async {
            digestCount++;
            return sha256.convert(await File(path).readAsBytes()).toString();
          },
        );
        await runtime.importUserDirectory(
          modelId: descriptor.id,
          sourceDirectoryPath: source.path,
        );
        final afterImport = digestCount;

        expect(await runtime.isAvailable(descriptor.coreModelPack), isTrue);
        expect(await runtime.isAvailable(descriptor.coreModelPack), isTrue);
        expect(digestCount, afterImport);
        expect(
          await runtime.resolveForRecognition(descriptor.coreModelPack),
          isNotNull,
        );
        expect(digestCount, greaterThan(afterImport));
        final afterWorkerGate = digestCount;
        expect(await runtime.isAvailable(descriptor.coreModelPack), isTrue);
        expect(digestCount, afterWorkerGate);
      },
    );

    test('mobile factory is an inert stub and creates no cache', () async {
      final descriptor = _tinyDescriptor(
        files: <String, List<int>>{
          'model.onnx': <int>[1],
        },
      );
      final support = Directory(p.join(sandbox.path, 'mobile-support'));
      final runtime = createDesktopLocalAsrPackRuntime(
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.ios,
        ),
        accountScopeDigest: _scope,
        generation: 1,
        isCurrentMount: ({required accountScopeDigest, required generation}) =>
            true,
        descriptors: <DesktopLocalAsrModelDescriptor>[descriptor],
        supportDirectoryProvider: () async => support.path,
      );

      expect(runtime.supported, isFalse);
      expect(await runtime.isAvailable(descriptor.coreModelPack), isFalse);
      expect(await support.exists(), isFalse);
    });
  });
}

IoDesktopLocalAsrPackRuntime _runtime(
  Directory sandbox,
  _Mount mount,
  DesktopLocalAsrModelDescriptor descriptor, {
  DesktopLocalAsrPackOperationObserver? observer,
  DesktopLocalAsrFileDigestProvider? digestProvider,
  DesktopLocalAsrStagingDelete? stagingDelete,
  AppHostPlatform platform = AppHostPlatform.macos,
}) =>
    createDesktopLocalAsrPackRuntime(
          platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
          accountScopeDigest: _scope,
          generation: 1,
          isCurrentMount:
              ({required accountScopeDigest, required generation}) =>
                  accountScopeDigest == _scope &&
                  generation == mount.generation,
          descriptors: <DesktopLocalAsrModelDescriptor>[descriptor],
          supportDirectoryProvider: () async => p.join(sandbox.path, 'support'),
          fileDigestProvider: digestProvider,
          stagingDelete: stagingDelete,
          operationObserver: observer,
        )
        as IoDesktopLocalAsrPackRuntime;

Future<Directory> _sourceDirectory(
  Directory sandbox,
  Map<String, List<int>> files, {
  String name = 'source',
}) async {
  final directory = await Directory(p.join(sandbox.path, name)).create();
  for (final entry in files.entries) {
    await File(
      p.join(directory.path, entry.key),
    ).writeAsBytes(entry.value, flush: true);
  }
  return directory;
}

DesktopLocalAsrModelDescriptor _tinyDescriptor({
  required Map<String, List<int>> files,
  bool gated = false,
}) => DesktopLocalAsrModelDescriptor(
  id: gated ? 'tiny-gated-model' : 'tiny-test-model',
  displayName: 'Tiny test model',
  engine: DesktopLocalAsrEngine.senseVoice,
  sourceRepository: 'https://example.com/model',
  sourceRevision: 'a' * 40,
  licenseId: 'Test license',
  licenseReference: 'https://example.com/license',
  requiresLicenseAcknowledgement: gated,
  requiresLegalApproval: gated,
  locales: const <String>['en'],
  files: <DesktopLocalAsrModelFileDescriptor>[
    for (final entry in files.entries)
      DesktopLocalAsrModelFileDescriptor(
        name: entry.key,
        byteLength: entry.value.length,
        sha256Digest: sha256.convert(entry.value).toString(),
      ),
  ],
);

Directory _installedPackDirectory(
  Directory sandbox,
  DesktopLocalAsrModelDescriptor descriptor,
) => Directory(
  p.join(
    sandbox.path,
    'support',
    'maaso',
    'desktop_local_asr',
    'v1',
    _scope,
    descriptor.id,
    descriptor.contentDigest,
  ),
);

String _manifestFor(DesktopLocalAsrModelDescriptor descriptor) =>
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

Matcher _throwsIssue(DesktopLocalAsrPackIssue issue) => throwsA(
  isA<DesktopLocalAsrPackException>().having(
    (error) => error.issue,
    'issue',
    issue,
  ),
);

Future<List<String>> _stagingPaths(Directory sandbox) async {
  if (!await sandbox.exists()) return const <String>[];
  return sandbox
      .list(recursive: true, followLinks: false)
      .where((entry) => p.basename(entry.path).startsWith('.staging-'))
      .map((entry) => entry.path)
      .toList();
}

final class _Mount {
  int generation = 1;
}

const String _scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
