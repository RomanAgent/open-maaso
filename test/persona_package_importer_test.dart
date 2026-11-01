import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/persona_package/data/persona_package_importer.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_gates.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_manifest.dart';

import 'persona_package_test_support.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30, 12);
  final scope = PersonaPackageScope(
    accountId: 'account-a',
    facadeGeneration: 9,
  );

  test(
    'imports portable bytes and verifies every resource including legal',
    () {
      final result = _importer().import(
        _request(scope: scope, importedAt: now),
      );

      expect(result.status, PersonaPackageImportStatus.accepted);
      final package = result.package!;
      expect(
        package.resourceReceipts.length,
        package.manifest.resources.length,
      );
      expect(
        package.resourceReceipts[package.manifest.license.noticeRef]!.kind,
        PersonaResourceKind.licenseNotice,
      );
      expect(
        package.resourceReceipts[package.manifest.license.sourceRef]!.kind,
        PersonaResourceKind.sourceArchive,
      );
    },
  );

  test('rejects changed bytes instead of trusting declared sha256', () {
    final result = _importer().import(
      personaArchiveRequest(
        scope: scope,
        importedAt: now,
        tamperedPackageRef: 'package://persona/values',
      ),
    );

    expect(result.reason, 'resource_digest_mismatch:1');
  });

  test('archive entries cannot impersonate host-owned resources', () {
    const ref = 'asset://avatar/default';
    final result = _importer().import(
      personaArchiveRequest(
        scope: scope,
        importedAt: now,
        extraEntries: <ArchiveFile>[
          ArchiveFile.bytes(
            PersonaPackageImporter.entryPathForRef(ref),
            personaResourceBytes(ref),
          ),
        ],
      ),
    );

    expect(result.reason, 'host_resource_in_archive:2');
  });

  test('rejects traversal, symlink, and non-regular entries from ZIP', () {
    final symbolicLink = ArchiveFile.string('package/persona/link', '../secret')
      ..mode = 0xa000;
    final nonRegular = ArchiveFile.bytes('package/persona/device', <int>[1])
      ..mode = 0x6000;
    for (final candidate in <({ArchiveFile entry, String reason})>[
      (
        entry: ArchiveFile.bytes('../escape', <int>[1]),
        reason: 'unsafe_entry_path',
      ),
      (entry: symbolicLink, reason: 'symbolic_link_forbidden'),
      (entry: nonRegular, reason: 'non_regular_entry_forbidden'),
    ]) {
      final result = _importer().import(
        personaArchiveRequest(
          scope: scope,
          importedAt: now,
          extraEntries: <ArchiveFile>[candidate.entry],
        ),
      );
      expect(result.reason, candidate.reason);
    }
  });

  test('enforces archive, expansion, entry, depth, and string budgets', () {
    final request = _request(scope: scope, importedAt: now);
    expect(
      _importer(
        limits: PersonaPackageImportLimits(maxArchiveBytes: 4),
      ).import(request).reason,
      'archive_too_large',
    );
    expect(
      _importer(
        limits: PersonaPackageImportLimits(maxEntryCount: 1),
      ).import(request).reason,
      'too_many_entries',
    );
    expect(
      _importer(
        limits: PersonaPackageImportLimits(maxJsonDepth: 2),
      ).import(request).reason,
      'json_depth_exceeded',
    );
    expect(
      _importer(
        limits: PersonaPackageImportLimits(maxJsonStringLength: 8),
      ).import(request).reason,
      'json_string_too_long',
    );
    expect(
      _importer()
          .import(
            personaArchiveRequest(
              scope: scope,
              importedAt: now,
              extraEntries: <ArchiveFile>[
                ArchiveFile.bytes(
                  'package/bomb/repeated',
                  List<int>.filled(10000, 1),
                ),
              ],
            ),
          )
          .reason,
      'compression_ratio_exceeded',
    );
  });

  test('streaming expansion limit ignores forged declared size', () {
    const bombPath = 'package/bomb/repeated';
    final original = personaArchiveRequest(
      scope: scope,
      importedAt: now,
      extraEntries: <ArchiveFile>[
        ArchiveFile.bytes(bombPath, List<int>.filled(64 * 1024, 7)),
      ],
    );
    final forged = _rewriteZipUncompressedSize(
      original.archiveBytes,
      path: bombPath,
      uncompressedSize: 1,
    );

    final result =
        _importer(
          limits: const PersonaPackageImportLimits(maxEntryBytes: 4096),
        ).import(
          PersonaPackageImportRequest(
            archiveBytes: forged,
            scope: scope,
            importedAt: now,
          ),
        );

    expect(result.reason, 'archive_expansion_limit_exceeded');
  });

  test('rejects local and central ZIP metadata mismatch before decode', () {
    final request = _request(scope: scope, importedAt: now);
    final directory = ZipDirectory()
      ..read(InputMemoryStream(request.archiveBytes));
    final header = directory.fileHeaders.firstWhere(
      (candidate) =>
          candidate.filename == PersonaPackageImporter.manifestEntryPath,
    );
    final forged = Uint8List.fromList(request.archiveBytes);
    final data = ByteData.sublistView(forged);
    data.setUint32(
      header.localHeaderOffset + 14,
      header.crc32 ^ 0x1,
      Endian.little,
    );

    final result = _importer().import(
      PersonaPackageImportRequest(
        archiveBytes: forged,
        scope: scope,
        importedAt: now,
      ),
    );

    expect(result.reason, 'archive_header_mismatch');
  });

  test('checks actual streamed bytes against the declared CRC', () {
    final request = _request(scope: scope, importedAt: now);
    final forged = _rewriteZipCrc(
      request.archiveBytes,
      path: PersonaPackageImporter.manifestEntryPath,
      crc32: 0,
    );

    final result = _importer().import(
      PersonaPackageImportRequest(
        archiveBytes: forged,
        scope: scope,
        importedAt: now,
      ),
    );

    expect(result.reason, 'archive_crc_mismatch');
  });

  test('host resolver exceptions return only a static redacted code', () {
    final result = PersonaPackageImporter(
      hostResourceResolver: const _ThrowingResolver(),
    ).import(_request(scope: scope, importedAt: now));

    expect(result.reason, 'resource_resolver_failed:0');
    expect(result.reason, isNot(contains('credential-secret')));
  });

  test(
    'same package version with changed content gets a new installation id',
    () async {
      final first = _importer()
          .import(_request(scope: scope, importedAt: now))
          .package!;
      final changedManifest = _portableManifest();
      (changedManifest['soul']! as Map<String, Object?>)['valuesRef'] =
          'package://persona/values-v2';
      final resources = changedManifest['resources']! as List<Object?>;
      final values = resources[1]! as Map<String, Object?>;
      values['ref'] = 'package://persona/values-v2';
      values['sha256'] = _resourceDigest('package://persona/values-v2');
      final second = _importer()
          .import(
            _request(scope: scope, importedAt: now, manifest: changedManifest),
          )
          .package!;

      final context = PersonaInstallContext(
        scope: scope,
        availableDependencies: const <String, String>{'host.avatar': '1.0.0'},
        allowedSpdxIds: const <String>{'MIT'},
        hostGrantedPermissions: const <PersonaPermission>{
          PersonaPermission.voiceUse,
          PersonaPermission.deviceMotion,
        },
        installedAt: now,
      );
      final firstInstall = const PersonaPackageInstallGate()
          .validate(verifiedPackage: first, context: context)
          .installation!;
      final secondInstall = const PersonaPackageInstallGate()
          .validate(verifiedPackage: second, context: context)
          .installation!;

      expect(first.manifestDigest, isNot(second.manifestDigest));
      expect(firstInstall.id, isNot(secondInstall.id));
      expect(
        firstInstall.resourceDigests,
        isNot(secondInstall.resourceDigests),
      );

      expect(firstInstall.manifestDigest, first.manifestDigest);
      expect(secondInstall.manifestDigest, second.manifestDigest);
    },
  );
}

PersonaPackageImportRequest _request({
  required PersonaPackageScope scope,
  required DateTime importedAt,
  Map<String, Object?>? manifest,
}) => personaArchiveRequest(
  scope: scope,
  importedAt: importedAt,
  manifest: manifest ?? _portableManifest(),
);

PersonaPackageImporter _importer({
  PersonaPackageImportLimits limits = const PersonaPackageImportLimits(),
}) => PersonaPackageImporter(
  hostResourceResolver: const TestPersonaHostResourceResolver(),
  limits: limits,
);

Map<String, Object?> _portableManifest() => <String, Object?>{
  'schemaVersion': 1,
  'packageId': 'maaso.companion.default',
  'version': '1.2.0',
  'soul': <String, Object?>{
    'masterProfileRef': 'maaso://profile/master',
    'valuesRef': 'package://persona/values',
  },
  'body': <String, Object?>{
    'avatarRef': 'asset://avatar/default',
    'voiceRef': 'asset://voice/default',
    'deviceCapabilities': <Object?>['status', 'move', 'stop'],
  },
  'faculty': <String, Object?>{'memory': true, 'vision': false, 'voice': true},
  'skills': <Object?>[
    <String, Object?>{
      'id': 'companion.chat',
      'version': '1.0.0',
      'entryRef': 'package://skills/companion-chat',
      'permissions': <Object?>['voice.use', 'device.motion'],
    },
  ],
  'dependencies': <Object?>[
    <String, Object?>{'id': 'host.avatar', 'requiredVersion': '1.0.0'},
  ],
  'permissions': <Object?>['voice.use', 'device.motion'],
  'license': <String, Object?>{
    'spdxId': 'MIT',
    'noticeRef': 'package://legal/notice',
    'sourceRef': 'package://legal/source',
  },
  'resources': <Object?>[
    _resource('profile.master', 'prompt', 'maaso://profile/master'),
    _resource('persona.values', 'prompt', 'package://persona/values'),
    _resource('avatar.default', 'avatar', 'asset://avatar/default'),
    _resource('voice.default', 'voice', 'asset://voice/default'),
    _resource(
      'skill.companion-chat',
      'skillAsset',
      'package://skills/companion-chat',
    ),
    _resource('license.notice', 'licenseNotice', 'package://legal/notice'),
    _resource('license.source', 'sourceArchive', 'package://legal/source'),
  ],
};

Map<String, Object?> _resource(String id, String kind, String ref) =>
    <String, Object?>{
      'id': id,
      'kind': kind,
      'ref': ref,
      'sha256': _resourceDigest(ref),
    };

List<int> _resourceBytes(String ref) => utf8.encode('verified-bytes:$ref');

String _resourceDigest(String ref) =>
    sha256.convert(_resourceBytes(ref)).toString();

Uint8List _rewriteZipUncompressedSize(
  Uint8List archiveBytes, {
  required String path,
  required int uncompressedSize,
}) {
  final bytes = Uint8List.fromList(archiveBytes);
  final data = ByteData.sublistView(bytes);
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  final header = directory.fileHeaders.firstWhere(
    (candidate) => candidate.filename == path,
  );
  data.setUint32(
    header.localHeaderOffset + 22,
    uncompressedSize,
    Endian.little,
  );

  final centralOffset = _centralHeaderOffset(bytes, directory, path);
  data.setUint32(centralOffset + 24, uncompressedSize, Endian.little);
  return bytes;
}

Uint8List _rewriteZipCrc(
  Uint8List archiveBytes, {
  required String path,
  required int crc32,
}) {
  final bytes = Uint8List.fromList(archiveBytes);
  final data = ByteData.sublistView(bytes);
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  final header = directory.fileHeaders.firstWhere(
    (candidate) => candidate.filename == path,
  );
  data.setUint32(header.localHeaderOffset + 14, crc32, Endian.little);
  final centralOffset = _centralHeaderOffset(bytes, directory, path);
  data.setUint32(centralOffset + 16, crc32, Endian.little);
  return bytes;
}

int _centralHeaderOffset(Uint8List bytes, ZipDirectory directory, String path) {
  final data = ByteData.sublistView(bytes);
  var offset = directory.centralDirectoryOffset;
  while (offset < directory.filePosition) {
    if (data.getUint32(offset, Endian.little) != ZipFileHeader.signature) break;
    final filenameLength = data.getUint16(offset + 28, Endian.little);
    final extraLength = data.getUint16(offset + 30, Endian.little);
    final commentLength = data.getUint16(offset + 32, Endian.little);
    final filename = utf8.decode(
      bytes.sublist(offset + 46, offset + 46 + filenameLength),
    );
    if (filename == path) return offset;
    offset += 46 + filenameLength + extraLength + commentLength;
  }
  throw StateError('fixture_central_header_missing');
}

final class _ThrowingResolver implements PersonaHostResourceResolver {
  const _ThrowingResolver();

  @override
  Uint8List? resolve(PersonaHostResourceRequest request) {
    throw StateError('credential-secret-from-resolver');
  }
}
