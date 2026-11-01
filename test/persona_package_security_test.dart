import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/persona_package/data/persona_package_importer.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_gates.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_manifest.dart';
import 'package:maaso/src/features/persona_package/domain/persona_package_redacted_export.dart';

import 'persona_package_test_support.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30, 12);

  test('strict schema accepts all four fixed persona sections', () {
    final parsed = PersonaPackageManifestParser.parse(_manifestJson());

    expect(parsed.status, PersonaManifestParseStatus.accepted);
    expect(parsed.manifest!.soul.masterProfileRef, 'maaso://profile/master');
    expect(parsed.manifest!.body.avatarRef, 'asset://avatar/default');
    expect(parsed.manifest!.faculty.memory, isTrue);
    expect(parsed.manifest!.skills.single.id, 'companion.chat');
  });

  test('strict schema rejects unknown missing and wrong-type fields', () {
    final unknown = _manifestJson()..['unexpected'] = true;
    final unknownResult = PersonaPackageManifestParser.parse(unknown);
    expect(unknownResult.issue!.code, 'unknown_field');
    expect(unknownResult.issue!.path, r'$');

    final missing = _manifestJson()..remove('soul');
    final missingResult = PersonaPackageManifestParser.parse(missing);
    expect(missingResult.issue!.code, 'missing_field');
    expect(missingResult.issue!.path, r'$.soul');

    final wrongType = _manifestJson()
      ..['faculty'] = <String, Object?>{
        'memory': 'yes',
        'vision': false,
        'voice': true,
      };
    final wrongTypeResult = PersonaPackageManifestParser.parse(wrongType);
    expect(wrongTypeResult.issue!.code, 'wrong_type');
    expect(wrongTypeResult.issue!.path, r'$.faculty.memory');

    final nestedUnknown = _manifestJson();
    (nestedUnknown['soul']! as Map<String, Object?>)['prompt'] = 'secret';
    final nestedResult = PersonaPackageManifestParser.parse(nestedUnknown);
    expect(nestedResult.issue!.code, 'unknown_field');
    expect(nestedResult.issue!.path, r'$.soul');

    const hostileKey = 'token\nsecret-control';
    final hostile = _manifestJson()..[hostileKey] = 'credential-value';
    final hostileResult = PersonaPackageManifestParser.parse(hostile);
    expect(hostileResult.issue!.path, r'$');
    expect(jsonEncode(hostileResult.issue!.path), isNot(contains(hostileKey)));
  });

  test('validator exceptions collapse to a static redacted failure', () {
    final result = PersonaPackageManifestParser.parse(_ThrowingManifestMap());

    expect(result.issue!.code, 'validation_failed');
    expect(result.issue!.path, r'$');
    expect(result.issue.toString(), isNot(contains('credential-secret')));
  });

  test('resource references reject remote query credentials', () {
    final candidate = _manifestJson();
    (candidate['body']! as Map<String, Object?>)['avatarRef'] =
        'https://example.com/avatar?token=secret';

    final result = PersonaPackageManifestParser.parse(candidate);
    expect(result.status, PersonaManifestParseStatus.rejected);
    expect(result.issue!.code, 'unsafe_resource_ref');
    expect(result.issue!.path, r'$.body.avatarRef');

    final secretPath = _manifestJson();
    (secretPath['soul']! as Map<String, Object?>)['valuesRef'] =
        'package://secrets/device-credential/private';
    final secretPathResult = PersonaPackageManifestParser.parse(secretPath);
    expect(secretPathResult.issue!.code, 'unsafe_resource_ref');
    expect(secretPathResult.issue!.path, r'$.soul.valuesRef');

    for (final unsafe in <String>[
      'package://persona/../secret',
      'package://persona/%2e%2e/secret',
      'package:///absolute/path',
      'package://persona/path%2fsecret',
    ]) {
      final traversal = _manifestJson();
      (traversal['soul']! as Map<String, Object?>)['valuesRef'] = unsafe;
      final traversalResult = PersonaPackageManifestParser.parse(traversal);
      expect(
        traversalResult.issue!.code,
        'unsafe_resource_ref',
        reason: unsafe,
      );
    }
  });

  test('generate gate rejects duplicate and undeclared skill permissions', () {
    final duplicate = _manifestJson();
    duplicate['permissions'] = <Object?>['voice.use', 'voice.use'];
    expect(
      const PersonaPackageGenerateGate().validate(duplicate).reason,
      'duplicate_declaration',
    );

    final undeclared = _manifestJson();
    undeclared['permissions'] = <Object?>['voice.use'];
    expect(
      const PersonaPackageGenerateGate().validate(undeclared).reason,
      'skill_permission_not_declared',
    );

    final missingResource = _manifestJson();
    (missingResource['resources']! as List<Object?>).removeLast();
    expect(
      const PersonaPackageGenerateGate().validate(missingResource).reason,
      'resource_reference_not_declared',
    );

    final wrongResourceKind = _manifestJson();
    ((wrongResourceKind['resources']! as List<Object?>).last!
            as Map<String, Object?>)['kind'] =
        'voice';
    expect(
      const PersonaPackageGenerateGate().validate(wrongResourceKind).reason,
      'resource_reference_not_declared',
    );
  });

  test('manifest collections have a fixed resource-exhaustion bound', () {
    final oversized = _manifestJson();
    oversized['dependencies'] = List<Object?>.generate(
      257,
      (index) => <String, Object?>{
        'id': 'dependency-$index',
        'requiredVersion': '1.0.0',
      },
    );

    final result = PersonaPackageManifestParser.parse(oversized);
    expect(result.issue!.code, 'too_many_items');
    expect(result.issue!.path, r'$.dependencies');
  });

  test('canonical SemVer rejects ambiguous and oversized versions', () {
    for (final invalid in <String>[
      '01.0.0',
      '1.0.0-alpha..1',
      '1.0.0-01',
      '1.0.0-${List<String>.filled(80, 'a').join()}',
    ]) {
      final candidate = _manifestJson()..['version'] = invalid;
      expect(
        PersonaPackageManifestParser.parse(candidate).status,
        PersonaManifestParseStatus.rejected,
        reason: invalid,
      );
    }
  });

  test('install gate checks license dependency permission and scope', () {
    final verifiedPackage = _verifiedPackage(now);
    final manifest = verifiedPackage.manifest;
    final accepted = const PersonaPackageInstallGate().validate(
      verifiedPackage: verifiedPackage,
      context: _installContext(manifest.scope, now),
    );
    expect(accepted.status, PersonaGateStatus.admitted);

    final wrongLicense = const PersonaPackageInstallGate().validate(
      verifiedPackage: verifiedPackage,
      context: _installContext(
        manifest.scope,
        now,
        allowedLicenses: const <String>{'Apache-2.0'},
      ),
    );
    expect(wrongLicense.reason, 'license_not_allowed');

    final missingDependency = const PersonaPackageInstallGate().validate(
      verifiedPackage: verifiedPackage,
      context: _installContext(
        manifest.scope,
        now,
        dependencies: const <String, String>{},
      ),
    );
    expect(missingDependency.reason, 'dependency_unsatisfied:0');

    final missingPermission = const PersonaPackageInstallGate().validate(
      verifiedPackage: verifiedPackage,
      context: PersonaInstallContext(
        scope: manifest.scope,
        availableDependencies: const <String, String>{'host.avatar': '1.0.0'},
        allowedSpdxIds: const <String>{'MIT'},
        hostGrantedPermissions: const <PersonaPermission>{
          PersonaPermission.voiceUse,
        },
        installedAt: now,
      ),
    );
    expect(missingPermission.reason, 'permission_not_granted');

    final staleScope = PersonaPackageScope(
      accountId: 'account-a',
      facadeGeneration: 6,
    );
    expect(
      const PersonaPackageInstallGate()
          .validate(
            verifiedPackage: verifiedPackage,
            context: _installContext(staleScope, now),
          )
          .reason,
      'persona_scope_mismatch',
    );
  });

  test('portable export round-trips only after host scope rebinding', () {
    final manifest = _generatedManifest();
    final exported = PersonaPackagePortableExporter.export(manifest);
    expect(exported, isNot(contains('accountId')));
    expect(exported, isNot(contains('facadeGeneration')));
    final reboundScope = PersonaPackageScope(
      accountId: 'account-b',
      facadeGeneration: 2,
    );
    final reparsed = PersonaPackageManifestParser.parsePortable(
      exported,
      scope: reboundScope,
    );
    expect(reparsed.status, PersonaManifestParseStatus.accepted);
    expect(reparsed.manifest!.scope.matches(reboundScope), isTrue);
    expect(reparsed.manifest!.canonicalDigest, manifest.canonicalDigest);
  });

  test('diagnostic export is non-importable and scrubs account taint', () {
    final tainted = _manifestJson()
      ..['packageId'] = 'account-a'
      ..['accountId'] = 'account-a';
    final manifest = const PersonaPackageGenerateGate()
        .validate(tainted)
        .manifest!;
    expect(
      () => PersonaPackagePortableExporter.export(manifest),
      throwsStateError,
    );
    final exported = PersonaPackageDiagnosticExporter.export(manifest);
    final encoded = jsonEncode(exported).toLowerCase();

    expect((exported['scope']! as Map)['account'], 'redacted');
    expect(encoded, isNot(contains(manifest.scope.accountId)));
    for (final forbidden in <String>[
      'token',
      'cookie',
      'credential',
      'rawmemory',
      'raw_memory',
    ]) {
      expect(encoded, isNot(contains(forbidden)), reason: forbidden);
    }
    expect(exported['exportKind'], 'persona.diagnostic.redacted.v1');
    expect(
      PersonaPackageManifestParser.parsePortable(
        exported,
        scope: manifest.scope,
      ).status,
      PersonaManifestParseStatus.rejected,
    );
  });
}

Map<String, Object?> _manifestJson() => <String, Object?>{
  'schemaVersion': 1,
  'packageId': 'maaso.companion.default',
  'version': '1.2.0',
  'accountId': 'account-a',
  'facadeGeneration': 7,
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
    <String, Object?>{
      'id': 'profile.master',
      'kind': 'prompt',
      'ref': 'maaso://profile/master',
      'sha256': personaResourceDigest('maaso://profile/master'),
    },
    <String, Object?>{
      'id': 'persona.values',
      'kind': 'prompt',
      'ref': 'package://persona/values',
      'sha256': personaResourceDigest('package://persona/values'),
    },
    <String, Object?>{
      'id': 'avatar.default',
      'kind': 'avatar',
      'ref': 'asset://avatar/default',
      'sha256': personaResourceDigest('asset://avatar/default'),
    },
    <String, Object?>{
      'id': 'voice.default',
      'kind': 'voice',
      'ref': 'asset://voice/default',
      'sha256': personaResourceDigest('asset://voice/default'),
    },
    <String, Object?>{
      'id': 'skill.companion-chat',
      'kind': 'skillAsset',
      'ref': 'package://skills/companion-chat',
      'sha256': personaResourceDigest('package://skills/companion-chat'),
    },
    <String, Object?>{
      'id': 'license.notice',
      'kind': 'licenseNotice',
      'ref': 'package://legal/notice',
      'sha256': personaResourceDigest('package://legal/notice'),
    },
    <String, Object?>{
      'id': 'license.source',
      'kind': 'sourceArchive',
      'ref': 'package://legal/source',
      'sha256': personaResourceDigest('package://legal/source'),
    },
  ],
};

PersonaPackageManifest _generatedManifest() =>
    const PersonaPackageGenerateGate().validate(_manifestJson()).manifest!;

PersonaVerifiedPackage _verifiedPackage(DateTime now) {
  final generated = _generatedManifest();
  final imported =
      const PersonaPackageImporter(
        hostResourceResolver: TestPersonaHostResourceResolver(),
      ).import(
        personaArchiveRequest(
          scope: generated.scope,
          importedAt: now,
          manifest: PersonaPackagePortableExporter.export(generated),
        ),
      );
  expect(imported.status, PersonaPackageImportStatus.accepted);
  return imported.package!;
}

PersonaInstallContext _installContext(
  PersonaPackageScope scope,
  DateTime now, {
  Map<String, String> dependencies = const <String, String>{
    'host.avatar': '1.0.0',
  },
  Set<String> allowedLicenses = const <String>{'MIT'},
}) => PersonaInstallContext(
  scope: scope,
  availableDependencies: dependencies,
  allowedSpdxIds: allowedLicenses,
  hostGrantedPermissions: const <PersonaPermission>{
    PersonaPermission.voiceUse,
    PersonaPermission.deviceMotion,
  },
  installedAt: now,
);

final class _ThrowingManifestMap extends MapBase<String, Object?> {
  @override
  Object? operator [](Object? key) => null;

  @override
  void operator []=(String key, Object? value) {}

  @override
  void clear() {}

  @override
  Iterable<String> get keys =>
      throw StateError('credential-secret-from-validator');

  @override
  Object? remove(Object? key) => null;
}
