import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/persona_package/data/persona_package_importer.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_gates.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_manifest.dart';

Map<String, Object?> portablePersonaManifest({
  String valuesRef = 'package://persona/values',
  List<Object?>? skills,
}) => <String, Object?>{
  'schemaVersion': 1,
  'packageId': 'maaso.companion.default',
  'version': '1.2.0',
  'soul': <String, Object?>{
    'masterProfileRef': 'maaso://profile/master',
    'valuesRef': valuesRef,
  },
  'body': <String, Object?>{
    'avatarRef': 'asset://avatar/default',
    'voiceRef': 'asset://voice/default',
    'deviceCapabilities': <Object?>['status', 'move', 'stop'],
  },
  'faculty': <String, Object?>{'memory': true, 'vision': false, 'voice': true},
  'skills':
      skills ??
      <Object?>[
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
    personaResource('profile.master', 'prompt', 'maaso://profile/master'),
    personaResource('persona.values', 'prompt', valuesRef),
    personaResource('avatar.default', 'avatar', 'asset://avatar/default'),
    personaResource('voice.default', 'voice', 'asset://voice/default'),
    personaResource(
      'skill.companion-chat',
      'skillAsset',
      'package://skills/companion-chat',
    ),
    personaResource(
      'license.notice',
      'licenseNotice',
      'package://legal/notice',
    ),
    personaResource(
      'license.source',
      'sourceArchive',
      'package://legal/source',
    ),
  ],
};

Map<String, Object?> personaResource(String id, String kind, String ref) =>
    <String, Object?>{
      'id': id,
      'kind': kind,
      'ref': ref,
      'sha256': personaResourceDigest(ref),
    };

Uint8List personaResourceBytes(String ref) =>
    Uint8List.fromList(utf8.encode('verified-bytes:$ref'));

String personaResourceDigest(String ref) =>
    sha256.convert(personaResourceBytes(ref)).toString();

final class TestPersonaHostResourceResolver
    implements PersonaHostResourceResolver {
  const TestPersonaHostResourceResolver({this.tamperedRef});

  final String? tamperedRef;

  @override
  Uint8List? resolve(PersonaHostResourceRequest request) =>
      request.ref == tamperedRef
      ? Uint8List.fromList(utf8.encode('tampered'))
      : personaResourceBytes(request.ref);
}

PersonaPackageImportRequest personaArchiveRequest({
  required PersonaPackageScope scope,
  required DateTime importedAt,
  Map<String, Object?>? manifest,
  String? tamperedPackageRef,
  List<ArchiveFile> extraEntries = const <ArchiveFile>[],
}) {
  final portable = manifest ?? portablePersonaManifest();
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        PersonaPackageImporter.manifestEntryPath,
        utf8.encode(jsonEncode(portable)),
      ),
    );
  for (final raw in portable['resources']! as List<Object?>) {
    final resource = raw! as Map<String, Object?>;
    final ref = resource['ref']! as String;
    if (Uri.parse(ref).scheme != 'package') continue;
    archive.addFile(
      ArchiveFile.bytes(
        PersonaPackageImporter.entryPathForRef(ref),
        ref == tamperedPackageRef
            ? utf8.encode('tampered')
            : personaResourceBytes(ref),
      ),
    );
  }
  for (final entry in extraEntries) {
    archive.addFile(entry);
  }
  return PersonaPackageImportRequest(
    archiveBytes: ZipEncoder().encodeBytes(archive),
    scope: scope,
    importedAt: importedAt,
  );
}

PersonaVerifiedPackage verifiedPersonaPackage({
  required PersonaPackageScope scope,
  required DateTime importedAt,
  Map<String, Object?>? manifest,
}) {
  final result =
      const PersonaPackageImporter(
        hostResourceResolver: TestPersonaHostResourceResolver(),
      ).import(
        personaArchiveRequest(
          scope: scope,
          importedAt: importedAt,
          manifest: manifest,
        ),
      );
  if (result.package == null) {
    throw StateError('test fixture import failed: ${result.reason}');
  }
  return result.package!;
}

PersonaInstallContext personaInstallContext(
  PersonaPackageScope scope,
  DateTime now,
) => PersonaInstallContext(
  scope: scope,
  availableDependencies: const <String, String>{'host.avatar': '1.0.0'},
  allowedSpdxIds: const <String>{'MIT'},
  hostGrantedPermissions: const <PersonaPermission>{
    PersonaPermission.voiceUse,
    PersonaPermission.deviceMotion,
  },
  installedAt: now,
);
