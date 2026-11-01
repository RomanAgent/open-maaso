import 'dart:convert';

import 'package:crypto/crypto.dart';

enum PersonaDeviceCapability {
  status,
  health,
  sense,
  face,
  move,
  nod,
  shake,
  home,
  stop,
}

enum PersonaFacultyKind { memory, vision, voice }

enum PersonaResourceKind {
  avatar,
  voice,
  prompt,
  skillAsset,
  licenseNotice,
  sourceArchive,
}

enum PersonaPermission {
  soulRead('soul.read'),
  avatarUse('avatar.use'),
  voiceUse('voice.use'),
  memoryRead('memory.read'),
  memoryWrite('memory.write'),
  visionUse('vision.use'),
  skillInvoke('skill.invoke'),
  deviceStatus('device.status'),
  deviceMotion('device.motion');

  const PersonaPermission(this.wireName);

  final String wireName;

  bool get requiresOnceApproval => switch (this) {
    PersonaPermission.memoryWrite || PersonaPermission.deviceMotion => true,
    _ => false,
  };

  static PersonaPermission parse(String value) {
    for (final permission in PersonaPermission.values) {
      if (permission.wireName == value) return permission;
    }
    throw _ManifestFailure('invalid_value', r'$.permissions');
  }
}

enum PersonaBoundaryValidationCode {
  invalidFacadeGeneration,
  invalidIdentifier,
  invalidIssuer,
  invalidOperationType,
  invalidSha256,
  invalidTarget,
  invalidVersion,
  invalidApprovalReceiptBounds,
  invalidAdmissionLifetime,
  operationStructureBudgetExceeded,
  operationNumberOutOfBounds,
  operationStringOutOfBounds,
  operationStringBudgetExceeded,
  operationListOutOfBounds,
  operationObjectOutOfBounds,
  invalidOperationArgumentKey,
  unsupportedOperationArgumentValue,
}

/// Static, typed boundary failure that never retains or renders caller input.
final class PersonaBoundaryValidationException implements Exception {
  const PersonaBoundaryValidationException(this.code);

  final PersonaBoundaryValidationCode code;

  @override
  String toString() => 'PersonaBoundaryValidationException: ${code.name}';
}

final class PersonaPackageScope {
  PersonaPackageScope({
    required String accountId,
    required this.facadeGeneration,
  }) : accountId = _identifier(accountId, r'$.accountId') {
    if (facadeGeneration < 1 || facadeGeneration > 0x7fffffff) {
      throw const PersonaBoundaryValidationException(
        PersonaBoundaryValidationCode.invalidFacadeGeneration,
      );
    }
  }

  final String accountId;
  final int facadeGeneration;

  bool matches(PersonaPackageScope other) =>
      accountId == other.accountId &&
      facadeGeneration == other.facadeGeneration;
}

final class PersonaSoulManifest {
  const PersonaSoulManifest({
    required this.masterProfileRef,
    required this.valuesRef,
  });

  final String masterProfileRef;
  final String valuesRef;
}

final class PersonaBodyManifest {
  PersonaBodyManifest({
    required this.avatarRef,
    required this.voiceRef,
    required List<PersonaDeviceCapability> deviceCapabilities,
  }) : deviceCapabilities = List<PersonaDeviceCapability>.unmodifiable(
         deviceCapabilities,
       );

  final String avatarRef;
  final String voiceRef;
  final List<PersonaDeviceCapability> deviceCapabilities;
}

final class PersonaFacultyManifest {
  const PersonaFacultyManifest({
    required this.memory,
    required this.vision,
    required this.voice,
  });

  final bool memory;
  final bool vision;
  final bool voice;

  bool enables(PersonaFacultyKind faculty) => switch (faculty) {
    PersonaFacultyKind.memory => memory,
    PersonaFacultyKind.vision => vision,
    PersonaFacultyKind.voice => voice,
  };
}

final class PersonaSkillManifest {
  PersonaSkillManifest({
    required this.id,
    required this.version,
    required this.entryRef,
    required List<PersonaPermission> permissions,
  }) : permissions = List<PersonaPermission>.unmodifiable(permissions);

  final String id;
  final String version;
  final String entryRef;
  final List<PersonaPermission> permissions;
}

final class PersonaDependencyManifest {
  const PersonaDependencyManifest({
    required this.id,
    required this.requiredVersion,
  });

  final String id;
  final String requiredVersion;
}

final class PersonaLicenseManifest {
  const PersonaLicenseManifest({
    required this.spdxId,
    required this.noticeRef,
    required this.sourceRef,
  });

  final String spdxId;
  final String noticeRef;
  final String sourceRef;
}

final class PersonaResourceManifest {
  const PersonaResourceManifest({
    required this.id,
    required this.kind,
    required this.ref,
    required this.sha256,
  });

  final String id;
  final PersonaResourceKind kind;
  final String ref;
  final String sha256;
}

/// Strict declarative package. It deliberately contains references and
/// capability declarations only, never runtime state or credential material.
final class PersonaPackageManifest {
  PersonaPackageManifest._({
    required this.schemaVersion,
    required this.packageId,
    required this.version,
    required this.scope,
    required this.soul,
    required this.body,
    required this.faculty,
    required List<PersonaSkillManifest> skills,
    required List<PersonaDependencyManifest> dependencies,
    required List<PersonaPermission> permissions,
    required this.license,
    required List<PersonaResourceManifest> resources,
  }) : skills = List<PersonaSkillManifest>.unmodifiable(skills),
       dependencies = List<PersonaDependencyManifest>.unmodifiable(
         dependencies,
       ),
       permissions = List<PersonaPermission>.unmodifiable(permissions),
       resources = List<PersonaResourceManifest>.unmodifiable(resources);

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String packageId;
  final String version;
  final PersonaPackageScope scope;
  final PersonaSoulManifest soul;
  final PersonaBodyManifest body;
  final PersonaFacultyManifest faculty;
  final List<PersonaSkillManifest> skills;
  final List<PersonaDependencyManifest> dependencies;
  final List<PersonaPermission> permissions;
  final PersonaLicenseManifest license;
  final List<PersonaResourceManifest> resources;

  /// Content identity for authorization and installation. Account runtime
  /// scope is deliberately excluded so a portable package can be rebound by
  /// the host without changing its declarative identity.
  late final String canonicalDigest = sha256
      .convert(utf8.encode(jsonEncode(toPortableJson(canonical: true))))
      .toString();

  Map<String, Object?> toPortableJson({bool canonical = false}) {
    List<T> ordered<T>(List<T> values, String Function(T) key) {
      if (!canonical) return List<T>.of(values);
      return List<T>.of(values)
        ..sort((left, right) => key(left).compareTo(key(right)));
    }

    final capabilities = ordered<PersonaDeviceCapability>(
      body.deviceCapabilities,
      (value) => value.name,
    );
    final orderedSkills = ordered<PersonaSkillManifest>(
      skills,
      (value) => '${value.id}\u0000${value.version}\u0000${value.entryRef}',
    );
    final orderedDependencies = ordered<PersonaDependencyManifest>(
      dependencies,
      (value) => '${value.id}\u0000${value.requiredVersion}',
    );
    final orderedPermissions = ordered<PersonaPermission>(
      permissions,
      (value) => value.wireName,
    );
    final orderedResources = ordered<PersonaResourceManifest>(
      resources,
      (value) => '${value.id}\u0000${value.ref}',
    );

    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'packageId': packageId,
      'version': version,
      'soul': <String, Object?>{
        'masterProfileRef': soul.masterProfileRef,
        'valuesRef': soul.valuesRef,
      },
      'body': <String, Object?>{
        'avatarRef': body.avatarRef,
        'voiceRef': body.voiceRef,
        'deviceCapabilities': capabilities
            .map((value) => value.name)
            .toList(growable: false),
      },
      'faculty': <String, Object?>{
        'memory': faculty.memory,
        'vision': faculty.vision,
        'voice': faculty.voice,
      },
      'skills': orderedSkills
          .map(
            (skill) => <String, Object?>{
              'id': skill.id,
              'version': skill.version,
              'entryRef': skill.entryRef,
              'permissions': ordered<PersonaPermission>(
                skill.permissions,
                (value) => value.wireName,
              ).map((value) => value.wireName).toList(growable: false),
            },
          )
          .toList(growable: false),
      'dependencies': orderedDependencies
          .map(
            (dependency) => <String, Object?>{
              'id': dependency.id,
              'requiredVersion': dependency.requiredVersion,
            },
          )
          .toList(growable: false),
      'permissions': orderedPermissions
          .map((value) => value.wireName)
          .toList(growable: false),
      'license': <String, Object?>{
        'spdxId': license.spdxId,
        'noticeRef': license.noticeRef,
        'sourceRef': license.sourceRef,
      },
      'resources': orderedResources
          .map(
            (resource) => <String, Object?>{
              'id': resource.id,
              'kind': resource.kind.name,
              'ref': resource.ref,
              'sha256': resource.sha256,
            },
          )
          .toList(growable: false),
    };
  }
}

enum PersonaManifestParseStatus { accepted, rejected }

final class PersonaManifestIssue {
  const PersonaManifestIssue({required this.code, required this.path});

  final String code;
  final String path;
}

final class PersonaManifestParseResult {
  const PersonaManifestParseResult._({
    required this.status,
    this.manifest,
    this.issue,
  });

  const PersonaManifestParseResult.accepted(PersonaPackageManifest manifest)
    : this._(status: PersonaManifestParseStatus.accepted, manifest: manifest);

  const PersonaManifestParseResult.rejected(PersonaManifestIssue issue)
    : this._(status: PersonaManifestParseStatus.rejected, issue: issue);

  final PersonaManifestParseStatus status;
  final PersonaPackageManifest? manifest;
  final PersonaManifestIssue? issue;
}

abstract final class PersonaPackageManifestParser {
  static const Set<String> _topLevelKeys = <String>{
    'schemaVersion',
    'packageId',
    'version',
    'accountId',
    'facadeGeneration',
    'soul',
    'body',
    'faculty',
    'skills',
    'dependencies',
    'permissions',
    'license',
    'resources',
  };

  static const Set<String> _portableTopLevelKeys = <String>{
    'schemaVersion',
    'packageId',
    'version',
    'soul',
    'body',
    'faculty',
    'skills',
    'dependencies',
    'permissions',
    'license',
    'resources',
  };

  static PersonaManifestParseResult parse(Object? raw) {
    try {
      final root = _strictObject(raw, r'$', _topLevelKeys);
      final accountId = _identifier(
        _string(root, 'accountId', r'$'),
        r'$.accountId',
      );
      final facadeGeneration = _boundedGeneration(
        _integer(root, 'facadeGeneration', r'$'),
        r'$.facadeGeneration',
      );
      return _parseRoot(
        root,
        PersonaPackageScope(
          accountId: accountId,
          facadeGeneration: facadeGeneration,
        ),
      );
    } on _ManifestFailure catch (error) {
      return PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: error.code, path: error.path),
      );
    } on ArgumentError {
      return const PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: 'invalid_value', path: r'$'),
      );
    } on Object {
      return const PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: 'validation_failed', path: r'$'),
      );
    }
  }

  /// Parses the account-free export shape and binds it to host-owned scope.
  static PersonaManifestParseResult parsePortable(
    Object? raw, {
    required PersonaPackageScope scope,
  }) {
    try {
      final root = _strictObject(raw, r'$', _portableTopLevelKeys);
      return _parseRoot(root, scope);
    } on _ManifestFailure catch (error) {
      return PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: error.code, path: error.path),
      );
    } on ArgumentError {
      return const PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: 'invalid_value', path: r'$'),
      );
    } on Object {
      return const PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: 'validation_failed', path: r'$'),
      );
    }
  }

  static PersonaManifestParseResult _parseRoot(
    Map<String, Object?> root,
    PersonaPackageScope scope,
  ) {
    try {
      final schemaVersion = _integer(root, 'schemaVersion', r'$');
      if (schemaVersion != PersonaPackageManifest.currentSchemaVersion) {
        throw _ManifestFailure(
          'unsupported_schema_version',
          r'$.schemaVersion',
        );
      }
      final packageId = _manifestId(_string(root, 'packageId', r'$'));
      final version = _version(_string(root, 'version', r'$'), r'$.version');
      final soul = _parseSoul(root['soul']);
      final body = _parseBody(root['body']);
      final faculty = _parseFaculty(root['faculty']);
      final skills = _parseSkills(root['skills']);
      final dependencies = _parseDependencies(root['dependencies']);
      final permissions = _parsePermissions(
        root['permissions'],
        r'$.permissions',
      );
      final license = _parseLicense(root['license']);
      final resources = _parseResources(root['resources']);
      return PersonaManifestParseResult.accepted(
        PersonaPackageManifest._(
          schemaVersion: schemaVersion,
          packageId: packageId,
          version: version,
          scope: scope,
          soul: soul,
          body: body,
          faculty: faculty,
          skills: skills,
          dependencies: dependencies,
          permissions: permissions,
          license: license,
          resources: resources,
        ),
      );
    } on _ManifestFailure catch (error) {
      return PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: error.code, path: error.path),
      );
    } on ArgumentError {
      return const PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: 'invalid_value', path: r'$'),
      );
    } on Object {
      return const PersonaManifestParseResult.rejected(
        PersonaManifestIssue(code: 'validation_failed', path: r'$'),
      );
    }
  }

  static PersonaSoulManifest _parseSoul(Object? raw) {
    final value = _strictObject(raw, r'$.soul', const <String>{
      'masterProfileRef',
      'valuesRef',
    });
    return PersonaSoulManifest(
      masterProfileRef: _resourceRef(
        _string(value, 'masterProfileRef', r'$.soul'),
        r'$.soul.masterProfileRef',
      ),
      valuesRef: _resourceRef(
        _string(value, 'valuesRef', r'$.soul'),
        r'$.soul.valuesRef',
      ),
    );
  }

  static PersonaBodyManifest _parseBody(Object? raw) {
    final value = _strictObject(raw, r'$.body', const <String>{
      'avatarRef',
      'voiceRef',
      'deviceCapabilities',
    });
    return PersonaBodyManifest(
      avatarRef: _resourceRef(
        _string(value, 'avatarRef', r'$.body'),
        r'$.body.avatarRef',
      ),
      voiceRef: _resourceRef(
        _string(value, 'voiceRef', r'$.body'),
        r'$.body.voiceRef',
      ),
      deviceCapabilities: _enumList<PersonaDeviceCapability>(
        value['deviceCapabilities'],
        r'$.body.deviceCapabilities',
        PersonaDeviceCapability.values,
        (item) => item.name,
      ),
    );
  }

  static PersonaFacultyManifest _parseFaculty(Object? raw) {
    final value = _strictObject(raw, r'$.faculty', const <String>{
      'memory',
      'vision',
      'voice',
    });
    return PersonaFacultyManifest(
      memory: _boolean(value, 'memory', r'$.faculty'),
      vision: _boolean(value, 'vision', r'$.faculty'),
      voice: _boolean(value, 'voice', r'$.faculty'),
    );
  }

  static List<PersonaSkillManifest> _parseSkills(Object? raw) {
    final items = _list(raw, r'$.skills');
    return <PersonaSkillManifest>[
      for (var index = 0; index < items.length; index += 1)
        _parseSkill(items[index], index),
    ];
  }

  static PersonaSkillManifest _parseSkill(Object? raw, int index) {
    final path = '\$.skills[$index]';
    final value = _strictObject(raw, path, const <String>{
      'id',
      'version',
      'entryRef',
      'permissions',
    });
    return PersonaSkillManifest(
      id: _identifier(_string(value, 'id', path), '$path.id'),
      version: _version(_string(value, 'version', path), '$path.version'),
      entryRef: _resourceRef(
        _string(value, 'entryRef', path),
        '$path.entryRef',
      ),
      permissions: _parsePermissions(value['permissions'], '$path.permissions'),
    );
  }

  static List<PersonaDependencyManifest> _parseDependencies(Object? raw) {
    final items = _list(raw, r'$.dependencies');
    return <PersonaDependencyManifest>[
      for (var index = 0; index < items.length; index += 1)
        _parseDependency(items[index], index),
    ];
  }

  static PersonaDependencyManifest _parseDependency(Object? raw, int index) {
    final path = '\$.dependencies[$index]';
    final value = _strictObject(raw, path, const <String>{
      'id',
      'requiredVersion',
    });
    return PersonaDependencyManifest(
      id: _identifier(_string(value, 'id', path), '$path.id'),
      requiredVersion: _version(
        _string(value, 'requiredVersion', path),
        '$path.requiredVersion',
      ),
    );
  }

  static PersonaLicenseManifest _parseLicense(Object? raw) {
    final value = _strictObject(raw, r'$.license', const <String>{
      'spdxId',
      'noticeRef',
      'sourceRef',
    });
    final spdxId = _string(value, 'spdxId', r'$.license');
    if (!RegExp(r'^[A-Za-z0-9.-]{2,64}$').hasMatch(spdxId)) {
      throw _ManifestFailure('invalid_value', r'$.license.spdxId');
    }
    return PersonaLicenseManifest(
      spdxId: spdxId,
      noticeRef: _resourceRef(
        _string(value, 'noticeRef', r'$.license'),
        r'$.license.noticeRef',
      ),
      sourceRef: _resourceRef(
        _string(value, 'sourceRef', r'$.license'),
        r'$.license.sourceRef',
      ),
    );
  }

  static List<PersonaResourceManifest> _parseResources(Object? raw) {
    final items = _list(raw, r'$.resources');
    return <PersonaResourceManifest>[
      for (var index = 0; index < items.length; index += 1)
        _parseResource(items[index], index),
    ];
  }

  static PersonaResourceManifest _parseResource(Object? raw, int index) {
    final path = '\$.resources[$index]';
    final value = _strictObject(raw, path, const <String>{
      'id',
      'kind',
      'ref',
      'sha256',
    });
    return PersonaResourceManifest(
      id: _identifier(_string(value, 'id', path), '$path.id'),
      kind: _enumValue<PersonaResourceKind>(
        _string(value, 'kind', path),
        '$path.kind',
        PersonaResourceKind.values,
        (item) => item.name,
      ),
      ref: _resourceRef(_string(value, 'ref', path), '$path.ref'),
      sha256: _sha256(_string(value, 'sha256', path), '$path.sha256'),
    );
  }

  static List<PersonaPermission> _parsePermissions(Object? raw, String path) =>
      _enumList<PersonaPermission>(
        raw,
        path,
        PersonaPermission.values,
        (item) => item.wireName,
      );
}

Map<String, Object?> _strictObject(
  Object? raw,
  String path,
  Set<String> requiredKeys,
) {
  if (raw is! Map) throw _ManifestFailure('wrong_type', path);
  final result = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is! String) {
      throw _ManifestFailure('wrong_type', path);
    }
    final key = entry.key as String;
    if (key.length > 64) {
      throw _ManifestFailure('field_name_too_long', path);
    }
    if (!requiredKeys.contains(key)) {
      // Never reflect an untrusted field name. It may contain credentials,
      // control characters, or an intentionally huge diagnostic payload.
      throw _ManifestFailure('unknown_field', path);
    }
    result[key] = entry.value;
  }
  for (final key in requiredKeys) {
    if (!result.containsKey(key)) {
      throw _ManifestFailure('missing_field', '$path.$key');
    }
  }
  return result;
}

String _string(Map<String, Object?> map, String key, String path) {
  final value = map[key];
  if (value is! String) throw _ManifestFailure('wrong_type', '$path.$key');
  return value;
}

int _integer(Map<String, Object?> map, String key, String path) {
  final value = map[key];
  if (value is! int) throw _ManifestFailure('wrong_type', '$path.$key');
  return value;
}

bool _boolean(Map<String, Object?> map, String key, String path) {
  final value = map[key];
  if (value is! bool) throw _ManifestFailure('wrong_type', '$path.$key');
  return value;
}

List<Object?> _list(Object? raw, String path) {
  if (raw is! List) throw _ManifestFailure('wrong_type', path);
  if (raw.length > 256) {
    throw _ManifestFailure('too_many_items', path);
  }
  return List<Object?>.from(raw);
}

T _enumValue<T>(
  String raw,
  String path,
  List<T> values,
  String Function(T) name,
) {
  for (final value in values) {
    if (name(value) == raw) return value;
  }
  throw _ManifestFailure('invalid_value', path);
}

List<T> _enumList<T>(
  Object? raw,
  String path,
  List<T> values,
  String Function(T) name,
) {
  final items = _list(raw, path);
  return <T>[
    for (var index = 0; index < items.length; index += 1)
      items[index] is String
          ? _enumValue<T>(
              items[index]! as String,
              '$path[$index]',
              values,
              name,
            )
          : throw _ManifestFailure('wrong_type', '$path[$index]'),
  ];
}

String _manifestId(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[a-z0-9]+(?:[._-][a-z0-9]+)*$').hasMatch(normalized) ||
      normalized.length > 128) {
    throw _ManifestFailure('invalid_value', r'$.packageId');
  }
  return normalized;
}

String _identifier(String value, String path) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 256 ||
      !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(normalized)) {
    throw _ManifestFailure('invalid_value', path);
  }
  return normalized;
}

String _version(String value, String path) {
  final normalized = value.trim();
  final semVer = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
    r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );
  final match = semVer.firstMatch(normalized);
  final prerelease = match?.group(4);
  final invalidPrerelease =
      prerelease != null &&
      prerelease
          .split('.')
          .any(
            (identifier) =>
                !RegExp(r'[0-9A-Za-z]').hasMatch(identifier) ||
                (RegExp(r'^\d+$').hasMatch(identifier) &&
                    identifier.length > 1 &&
                    identifier.startsWith('0')),
          );
  if (normalized.length > 64 || match == null || invalidPrerelease) {
    throw _ManifestFailure('invalid_value', path);
  }
  return normalized;
}

int _boundedGeneration(int value, String path) {
  if (value < 1 || value > 0x7fffffff) {
    throw _ManifestFailure('invalid_value', path);
  }
  return value;
}

String _resourceRef(String value, String path) {
  final normalized = value.trim();
  final secretPath = RegExp(
    r'(^|[/_.-])(token|cookie|credential|device-?credential|raw-?memory)([/_.-]|$)',
    caseSensitive: false,
  ).hasMatch(normalized);
  if (normalized.length > 512 ||
      !RegExp(
        r'^(asset|maaso|package)://[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$',
      ).hasMatch(normalized) ||
      secretPath ||
      normalized
          .split('/')
          .any((segment) => segment == '.' || segment == '..')) {
    throw _ManifestFailure('unsafe_resource_ref', path);
  }
  return normalized;
}

String _sha256(String value, String path) {
  final normalized = value.trim().toLowerCase();
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
    throw _ManifestFailure('invalid_value', path);
  }
  return normalized;
}

final class _ManifestFailure implements Exception {
  const _ManifestFailure(this.code, this.path);

  final String code;
  final String path;
}

/// Semantic validation shared by generation and byte import. Keeping this
/// outside either gate prevents the importer from bypassing cross-reference
/// and capability invariants after strict parsing.
String? validatePersonaManifestSemantics(PersonaPackageManifest manifest) {
  bool hasDuplicates(Iterable<Object> values) {
    final seen = <Object>{};
    for (final value in values) {
      if (!seen.add(value)) return true;
    }
    return false;
  }

  if (hasDuplicates(manifest.skills.map((skill) => skill.id)) ||
      hasDuplicates(manifest.body.deviceCapabilities) ||
      hasDuplicates(manifest.dependencies.map((dependency) => dependency.id)) ||
      hasDuplicates(manifest.resources.map((resource) => resource.id)) ||
      hasDuplicates(manifest.resources.map((resource) => resource.ref)) ||
      hasDuplicates(manifest.permissions)) {
    return 'duplicate_declaration';
  }

  final declaredPermissions = manifest.permissions.toSet();
  for (final skill in manifest.skills) {
    if (hasDuplicates(skill.permissions) ||
        !declaredPermissions.containsAll(skill.permissions)) {
      return 'skill_permission_not_declared';
    }
  }

  bool declared(String ref, PersonaResourceKind kind) => manifest.resources.any(
    (resource) => resource.ref == ref && resource.kind == kind,
  );
  if (!declared(manifest.soul.masterProfileRef, PersonaResourceKind.prompt) ||
      !declared(manifest.soul.valuesRef, PersonaResourceKind.prompt) ||
      !declared(manifest.body.avatarRef, PersonaResourceKind.avatar) ||
      !declared(manifest.body.voiceRef, PersonaResourceKind.voice) ||
      !declared(
        manifest.license.noticeRef,
        PersonaResourceKind.licenseNotice,
      ) ||
      !declared(
        manifest.license.sourceRef,
        PersonaResourceKind.sourceArchive,
      ) ||
      !manifest.skills.every(
        (skill) => declared(skill.entryRef, PersonaResourceKind.skillAsset),
      )) {
    return 'resource_reference_not_declared';
  }

  if (declaredPermissions.contains(PersonaPermission.voiceUse) &&
      !manifest.faculty.voice) {
    return 'faculty_permission_mismatch:voice';
  }
  if ((declaredPermissions.contains(PersonaPermission.memoryRead) ||
          declaredPermissions.contains(PersonaPermission.memoryWrite)) &&
      !manifest.faculty.memory) {
    return 'faculty_permission_mismatch:memory';
  }
  if (declaredPermissions.contains(PersonaPermission.visionUse) &&
      !manifest.faculty.vision) {
    return 'faculty_permission_mismatch:vision';
  }
  if (declaredPermissions.contains(PersonaPermission.deviceMotion)) {
    final capabilities = manifest.body.deviceCapabilities.toSet();
    if (!capabilities.contains(PersonaDeviceCapability.move) ||
        !capabilities.contains(PersonaDeviceCapability.stop)) {
      return 'device_motion_capability_mismatch';
    }
  }
  return null;
}
