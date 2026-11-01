import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';

import 'project_json_canonicalizer.dart';
import 'project_bundle_data_contract.dart';

const projectBundleV2Profile = 'maaso.project.bundle.v2';
const projectBundleV2HashAlgorithm = 'jcs-sha256-v1';
const projectBundleV2RuntimeVersion = '2.0.0';
const projectBundleV2ToolchainVersion = 'maaso-web-2.0.0';

abstract final class ProjectBundleV2Limits {
  static const maxFiles = 200;
  static const maxSourceBytes = 2 * 1024 * 1024;
  static const maxAssetBytes = 20 * 1024 * 1024;
  static const maxRuntimeBytes = 2 * 1024 * 1024;
  static const maxTotalBytes = maxSourceBytes + maxAssetBytes + maxRuntimeBytes;
  static const maxFileBytes = 8 * 1024 * 1024;
  static const maxTransportBytes = 36 * 1024 * 1024;
  static const maxRoutes = 12;
  static const maxImageDimension = 4096;
  static const maxImagePixels = 16 * 1024 * 1024;
}

enum ProjectBundleV2FileRole { source, asset, runtime }

String projectBundleV2BytesDigest(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();
String projectBundleV2JsonDigest(Object? value) => projectBundleV2BytesDigest(
  const ProjectJsonCanonicalizer().canonicalBytes(value),
);

final class ProjectBundleV2FileMetadata {
  ProjectBundleV2FileMetadata({
    required this.path,
    required this.mimeType,
    required this.role,
    required this.byteLength,
    required this.sha256,
  }) {
    validateProjectBundleV2Path(path);
    _digest(sha256);
    if (byteLength < 0 || byteLength > ProjectBundleV2Limits.maxFileBytes) {
      _fail('file_size');
    }
    final extension = path.split('.').last.toLowerCase();
    const types = {
      'html': 'text/html',
      'css': 'text/css',
      'js': 'text/javascript',
      'ts': 'text/typescript',
      'json': 'application/json',
      'md': 'text/markdown',
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
    };
    if (types[extension] != mimeType) _fail('mime_type');
    switch (role) {
      case ProjectBundleV2FileRole.source:
        if (!(const {
                  'project.json',
                  'agent.md',
                  'agent.protocol.json',
                  'routes.json',
                }.contains(path) ||
                path.startsWith('src/') ||
                path.startsWith('tests/')) ||
            mimeType.startsWith('image/')) {
          _fail('source_path');
        }
      case ProjectBundleV2FileRole.asset:
        if (!path.startsWith('assets/') ||
            !const {'image/png', 'image/jpeg'}.contains(mimeType)) {
          _fail('asset_type');
        }
      case ProjectBundleV2FileRole.runtime:
        if (path != 'dist/index.html' || mimeType != 'text/html') {
          _fail('runtime_entry');
        }
    }
  }

  final String path;
  final String mimeType;
  final ProjectBundleV2FileRole role;
  final int byteLength;
  final String sha256;

  factory ProjectBundleV2FileMetadata.fromJson(Object? value) {
    final raw = _object(value, const {
      'path',
      'mimeType',
      'role',
      'byteLength',
      'sha256',
    });
    final role = ProjectBundleV2FileRole.values
        .where((item) => item.name == raw['role'])
        .firstOrNull;
    if (role == null) _fail('file_role');
    return ProjectBundleV2FileMetadata(
      path: _text(raw['path']),
      mimeType: _text(raw['mimeType']),
      role: role,
      byteLength: _integer(
        raw['byteLength'],
        maximum: ProjectBundleV2Limits.maxFileBytes,
      ),
      sha256: _text(raw['sha256']),
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'mimeType': mimeType,
    'role': role.name,
    'byteLength': byteLength,
    'sha256': sha256,
  };
}

final class ProjectBundleV2File {
  factory ProjectBundleV2File({
    required String path,
    required String mimeType,
    required ProjectBundleV2FileRole role,
    required List<int> bytes,
  }) {
    if (bytes.length > ProjectBundleV2Limits.maxFileBytes ||
        bytes.any((value) => value < 0 || value > 255)) {
      _fail('file_size');
    }
    final frozen = List<int>.unmodifiable(bytes);
    return ProjectBundleV2File._(
      ProjectBundleV2FileMetadata(
        path: path,
        mimeType: mimeType,
        role: role,
        byteLength: frozen.length,
        sha256: projectBundleV2BytesDigest(frozen),
      ),
      frozen,
    );
  }
  ProjectBundleV2File._(this.metadata, this.bytes);
  final ProjectBundleV2FileMetadata metadata;
  final List<int> bytes;
  Map<String, Object?> toTransportJson() => {
    ...metadata.toJson(),
    'bytesBase64': base64Encode(bytes),
  };
}

final class ProjectBundleV2Manifest {
  ProjectBundleV2Manifest._(this._json, this.files);
  final Map<String, Object?> _json;
  final List<ProjectBundleV2FileMetadata> files;
  String get projectId => _json['projectId']! as String;
  String get revisionId => _json['revisionId']! as String;
  String get contentManifestId => _json['contentManifestId']! as String;
  int get requirementRevision => _json['requirementRevision']! as int;
  String get requirementDigest => _json['requirementDigest']! as String;
  String? get baseRevision => _json['baseRevision'] as String?;
  String get projectKind => _json['projectKind']! as String;
  String get entryPoint => _json['entryPoint']! as String;
  String get contentDigest => _json['contentDigest']! as String;
  String get artifactDigest => _json['artifactDigest']! as String;
  String get candidateDigest => projectBundleV2JsonDigest(_json);
  String get bundleDigest => candidateDigest;
  Map<String, Object?> toJson() => _json;

  factory ProjectBundleV2Manifest.parse(String source) =>
      ProjectBundleV2Manifest.fromJson(
        const ProjectJsonCanonicalizer().parse(source),
      );

  factory ProjectBundleV2Manifest.fromJson(Object? value) {
    final raw = _object(value, const {
      'packageSchema',
      'profile',
      'projectId',
      'revisionId',
      'contentManifestId',
      'requirementRevision',
      'requirementDigest',
      'baseRevision',
      'projectKind',
      'entryPoint',
      'agentProtocolVersion',
      'sdkVersion',
      'runtimeMinVersion',
      'toolchainVersion',
      'hashAlgorithm',
      'contentDigest',
      'artifactDigest',
      'files',
    });
    if (raw['packageSchema'] is! int ||
        raw['packageSchema'] != 2 ||
        raw['profile'] != projectBundleV2Profile ||
        raw['agentProtocolVersion'] is! int ||
        raw['agentProtocolVersion'] != 2 ||
        raw['sdkVersion'] != projectBundleV2RuntimeVersion ||
        raw['runtimeMinVersion'] != projectBundleV2RuntimeVersion ||
        raw['toolchainVersion'] != projectBundleV2ToolchainVersion ||
        raw['hashAlgorithm'] != projectBundleV2HashAlgorithm ||
        !const {'applet', 'game'}.contains(raw['projectKind']) ||
        raw['entryPoint'] != 'dist/index.html') {
      _fail('unsupported_profile');
    }
    _id(raw['projectId'], 'project');
    _id(raw['revisionId'], 'revision');
    _id(raw['contentManifestId'], 'manifest');
    if (raw['baseRevision'] != null) _id(raw['baseRevision'], 'revision');
    _integer(raw['requirementRevision'], minimum: 1);
    for (final key in [
      'requirementDigest',
      'contentDigest',
      'artifactDigest',
    ]) {
      _digest(_text(raw[key]));
    }
    final values = raw['files'];
    if (values is! List ||
        values.isEmpty ||
        values.length > ProjectBundleV2Limits.maxFiles) {
      _fail('file_count');
    }
    final files = values
        .map(ProjectBundleV2FileMetadata.fromJson)
        .toList(growable: false);
    final paths = _ProjectPathInventory();
    String? previous;
    final totals = <ProjectBundleV2FileRole, int>{};
    for (final file in files) {
      if (previous != null && previous.compareTo(file.path) >= 0) {
        _fail('files_not_sorted');
      }
      previous = file.path;
      paths.add(file.path);
      totals[file.role] = (totals[file.role] ?? 0) + file.byteLength;
    }
    if ((totals[ProjectBundleV2FileRole.source] ?? 0) >
            ProjectBundleV2Limits.maxSourceBytes ||
        (totals[ProjectBundleV2FileRole.asset] ?? 0) >
            ProjectBundleV2Limits.maxAssetBytes ||
        (totals[ProjectBundleV2FileRole.runtime] ?? 0) >
            ProjectBundleV2Limits.maxRuntimeBytes) {
      _fail('package_size');
    }
    final names = files.map((file) => file.path).toSet();
    if (!names.containsAll({
          'project.json',
          'agent.md',
          'agent.protocol.json',
          'routes.json',
          'dist/index.html',
        }) ||
        !(names.contains('src/main.js') || names.contains('src/main.ts'))) {
      _fail('required_file_missing');
    }
    if (raw['contentDigest'] !=
            projectBundleV2FileIndexDigest(files, artifact: false) ||
        raw['artifactDigest'] !=
            projectBundleV2FileIndexDigest(files, artifact: true)) {
      _fail('index_digest');
    }
    final frozen =
        const ProjectJsonCanonicalizer().parse(
              const ProjectJsonCanonicalizer().canonicalize(raw),
            )!
            as Map<String, Object?>;
    return ProjectBundleV2Manifest._(frozen, List.unmodifiable(files));
  }

  factory ProjectBundleV2Manifest.create({
    required String projectId,
    required String revisionId,
    required String contentManifestId,
    required int requirementRevision,
    required String requirementDigest,
    required String? baseRevision,
    required String projectKind,
    required Iterable<ProjectBundleV2FileMetadata> files,
  }) {
    final sorted = files.toList()..sort((a, b) => a.path.compareTo(b.path));
    return ProjectBundleV2Manifest.fromJson({
      'packageSchema': 2,
      'profile': projectBundleV2Profile,
      'projectId': projectId,
      'revisionId': revisionId,
      'contentManifestId': contentManifestId,
      'requirementRevision': requirementRevision,
      'requirementDigest': requirementDigest,
      'baseRevision': baseRevision,
      'projectKind': projectKind,
      'entryPoint': 'dist/index.html',
      'agentProtocolVersion': 2,
      'sdkVersion': projectBundleV2RuntimeVersion,
      'runtimeMinVersion': projectBundleV2RuntimeVersion,
      'toolchainVersion': projectBundleV2ToolchainVersion,
      'hashAlgorithm': projectBundleV2HashAlgorithm,
      'contentDigest': projectBundleV2FileIndexDigest(sorted, artifact: false),
      'artifactDigest': projectBundleV2FileIndexDigest(sorted, artifact: true),
      'files': sorted.map((file) => file.toJson()).toList(growable: false),
    });
  }
}

String projectBundleV2FileIndexDigest(
  Iterable<ProjectBundleV2FileMetadata> files, {
  required bool artifact,
}) {
  final selected =
      files
          .where(
            (file) =>
                file.role == ProjectBundleV2FileRole.asset ||
                file.role ==
                    (artifact
                        ? ProjectBundleV2FileRole.runtime
                        : ProjectBundleV2FileRole.source),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return projectBundleV2JsonDigest({
    'schemaVersion': 2,
    'files': selected.map((file) => file.toJson()).toList(growable: false),
  });
}

final class ProjectBundleV2Route {
  ProjectBundleV2Route._(this._json);
  final Map<String, Object?> _json;
  String get routeId => _json['routeId']! as String;
  String? get parentRouteId => _json['parentRouteId'] as String?;
  String get title => _json['title']! as String;
  String? get backTarget => _json['backTarget'] as String?;
  bool get retainState => _json['retainState']! as bool;
  Map<String, Object?> toJson() => _json;
  bool acceptsParameters(Object? value) => const ActionSchemaValidator()
      .validate(schema: _json['parametersSchema'], value: value)
      .isValid;
}

/// Verified package structure and raw file digests, not an execution grant or a
/// signed verification report. Installing this value never opens or runs it.
final class ValidatedProjectBundleV2 {
  ValidatedProjectBundleV2._({
    required this.manifest,
    required this.files,
    required this.project,
    required this.protocol,
    required this.routes,
    required this.entryRouteId,
    required this.agentMarkdown,
  });
  final ProjectBundleV2Manifest manifest;
  final Map<String, List<int>> files;
  final Map<String, Object?> project;
  final SurfacePlayProtocol protocol;
  final List<ProjectBundleV2Route> routes;
  final String entryRouteId;
  final String agentMarkdown;
  String get title => project['title']! as String;
  String get summary => project['summary']! as String;
  String get candidateDigest => manifest.candidateDigest;
  String get bundleDigest => candidateDigest;
  String get runtimeHtml => utf8.decode(files[manifest.entryPoint]!);
}

final class ProjectBundleV2Codec {
  const ProjectBundleV2Codec();
  static const _transportJson = ProjectJsonCanonicalizer(
    maxBytes: ProjectBundleV2Limits.maxTransportBytes,
  );

  ValidatedProjectBundleV2 decodeBytes(List<int> bytes) =>
      decode(_transportJson.parseBytes(bytes));
  ValidatedProjectBundleV2 decodeString(String source) =>
      decode(_transportJson.parse(source));
  ValidatedProjectBundleV2 decode(Object? value) {
    final raw = _object(value, const {'manifest', 'files'});
    final manifest = ProjectBundleV2Manifest.fromJson(raw['manifest']);
    final entries = raw['files'];
    if (entries is! List || entries.length != manifest.files.length) {
      _fail('file_count');
    }
    final files = <ProjectBundleV2File>[];
    for (final value in entries) {
      final entry = _object(value, const {
        'path',
        'mimeType',
        'role',
        'byteLength',
        'sha256',
        'bytesBase64',
      });
      final metadata = ProjectBundleV2FileMetadata.fromJson(
        {...entry}..remove('bytesBase64'),
      );
      final encoded = _text(entry['bytesBase64']);
      if (encoded.length != ((metadata.byteLength + 2) ~/ 3) * 4) {
        _fail('base64_size');
      }
      final bytes = base64Decode(encoded);
      if (base64Encode(bytes) != encoded ||
          bytes.length != metadata.byteLength ||
          projectBundleV2BytesDigest(bytes) != metadata.sha256) {
        _fail('file_digest');
      }
      files.add(ProjectBundleV2File._(metadata, List.unmodifiable(bytes)));
    }
    return verify(manifest, files);
  }

  String encode(ValidatedProjectBundleV2 bundle) =>
      _transportJson.canonicalize(toJson(bundle));
  Map<String, Object?> toJson(ValidatedProjectBundleV2 bundle) => {
    'manifest': bundle.manifest.toJson(),
    'files': [
      for (final metadata in bundle.manifest.files)
        {
          ...metadata.toJson(),
          'bytesBase64': base64Encode(bundle.files[metadata.path]!),
        },
    ],
  };

  ValidatedProjectBundleV2 verify(
    ProjectBundleV2Manifest manifest,
    Iterable<ProjectBundleV2File> files,
  ) {
    final expected = {
      for (final metadata in manifest.files) metadata.path: metadata,
    };
    final actual = <String, List<int>>{};
    for (final file in files) {
      if (actual.length >= ProjectBundleV2Limits.maxFiles) _fail('file_count');
      final metadata = file.metadata;
      final wanted = expected[metadata.path];
      if (wanted == null || actual.containsKey(metadata.path)) {
        _fail('file_set');
      }
      if (const ProjectJsonCanonicalizer().canonicalize(wanted.toJson()) !=
              const ProjectJsonCanonicalizer().canonicalize(
                metadata.toJson(),
              ) ||
          file.bytes.length != wanted.byteLength ||
          projectBundleV2BytesDigest(file.bytes) != wanted.sha256) {
        _fail('file_digest');
      }
      if (metadata.role == ProjectBundleV2FileRole.asset) {
        _validateImage(file);
      } else {
        final text = utf8.decode(file.bytes, allowMalformed: false);
        if (text.contains('\u0000')) _fail('text_nul');
        if (metadata.mimeType == 'application/json') {
          const ProjectJsonCanonicalizer(
            maxBytes: ProjectBundleV2Limits.maxSourceBytes,
          ).parse(text);
        }
      }
      actual[metadata.path] = file.bytes;
    }
    if (actual.length != expected.length) _fail('file_set');
    Object? readJson(String path) =>
        const ProjectJsonCanonicalizer().parseBytes(actual[path]!);
    final rawProject = _map(readJson('project.json'));
    const dataKeys = {'dataSchemaVersion', 'dataSchema', 'dataMigration'};
    final project = _object(rawProject, {
      'packageSchema',
      'profile',
      'projectId',
      'revisionId',
      'contentManifestId',
      'projectKind',
      'entryPoint',
      'agentProtocolVersion',
      'sdkVersion',
      'runtimeMinVersion',
      'toolchainVersion',
      'title',
      'summary',
      ...rawProject.keys.where(dataKeys.contains),
    });
    ProjectBundleDataContract.fromProject(project);
    for (final key in project.keys.where(
      (key) => key != 'title' && key != 'summary' && !dataKeys.contains(key),
    )) {
      if (project[key] != manifest.toJson()[key]) _fail('project_identity');
    }
    _boundedText(project['title'], minimum: 1, maximum: 80);
    _boundedText(project['summary'], minimum: 0, maximum: 400);
    final protocolRaw = _map(readJson('agent.protocol.json'));
    final protocol = validateAgentProtocol(
      protocolRaw,
      projectId: manifest.projectId,
      revisionId: manifest.revisionId,
    );
    if (protocol.projectKind != manifest.projectKind) _fail('protocol_kind');
    final routeData = _object(readJson('routes.json'), const {
      'schemaVersion',
      'projectId',
      'revisionId',
      'entryRouteId',
      'routes',
    });
    if (routeData['schemaVersion'] is! int ||
        routeData['schemaVersion'] != 2 ||
        routeData['projectId'] != manifest.projectId ||
        routeData['revisionId'] != manifest.revisionId) {
      _fail('routes_identity');
    }
    final entryRouteId = _semanticId(routeData['entryRouteId']);
    final rawRoutes = routeData['routes'];
    if (rawRoutes is! List ||
        rawRoutes.isEmpty ||
        rawRoutes.length > ProjectBundleV2Limits.maxRoutes) {
      _fail('routes_count');
    }
    final routes = <ProjectBundleV2Route>[];
    final byId = <String, ProjectBundleV2Route>{};
    for (final value in rawRoutes) {
      final route = _object(value, const {
        'routeId',
        'parentRouteId',
        'title',
        'parametersSchema',
        'backTarget',
        'retainState',
      });
      final id = _semanticId(route['routeId']);
      if (byId.containsKey(id)) _fail('route_duplicate');
      if (route['parentRouteId'] != null) _semanticId(route['parentRouteId']);
      if (route['backTarget'] != null) _semanticId(route['backTarget']);
      _boundedText(route['title'], minimum: 1, maximum: 80);
      if (route['retainState'] is! bool) _fail('route_state_policy');
      validateBoundedAgentSchema(_map(route['parametersSchema']));
      final result = ProjectBundleV2Route._(Map.unmodifiable(route));
      routes.add(result);
      byId[id] = result;
    }
    final root = byId[entryRouteId];
    if (root == null || root.parentRouteId != null || root.backTarget != null) {
      _fail('route_root');
    }
    for (final route in routes) {
      if (route.routeId != entryRouteId &&
          (route.parentRouteId == null || route.backTarget == null)) {
        _fail('route_parent');
      }
      if (route.backTarget != null && !byId.containsKey(route.backTarget)) {
        _fail('route_back_target');
      }
      final seen = <String>{};
      String? next = route.routeId;
      while (next != null) {
        if (!seen.add(next)) _fail('route_cycle');
        final current = byId[next];
        if (current == null) _fail('route_parent');
        next = current.parentRouteId;
      }
    }
    for (final action in protocol.actions.where(
      (action) => action['id'] == 'app.navigate',
    )) {
      final schema = _map(action['argsSchema']);
      final properties = _map(schema['properties']);
      final routeRule = _map(properties['routeId']);
      final declared = routeRule['enum'];
      if (declared is! List ||
          declared.any((id) => id is! String || !byId.containsKey(id))) {
        _fail('navigation_route');
      }
    }
    if (actual['agent.md']!.length > 64 * 1024) {
      throw const FormatException('agent_document_too_large');
    }
    final markdown = utf8.decode(actual['agent.md']!);
    _validateAgentDocument(
      markdown,
      manifest,
      expected['agent.protocol.json']!.sha256,
    );
    if (utf8.decode(actual[manifest.entryPoint]!).trim().isEmpty) {
      _fail('empty_runtime');
    }
    return ValidatedProjectBundleV2._(
      manifest: manifest,
      files: Map.unmodifiable(actual),
      project: Map.unmodifiable(project),
      protocol: protocol,
      routes: List.unmodifiable(routes),
      entryRouteId: entryRouteId,
      agentMarkdown: markdown,
    );
  }
}

void _validateAgentDocument(
  String markdown,
  ProjectBundleV2Manifest manifest,
  String protocolSha256,
) {
  final match = RegExp(
    r'^---\r?\n([^\r\n]+)\r?\n---\r?\n',
  ).firstMatch(markdown);
  if (match == null ||
      match.group(1)!.length > 4096 ||
      markdown.substring(match.end).trim().isEmpty) {
    _fail('agent_document');
  }
  final front = _object(
    const ProjectJsonCanonicalizer(maxBytes: 4096).parse(match.group(1)!),
    const {
      'docSchemaVersion',
      'profile',
      'projectId',
      'revisionId',
      'contentManifestId',
      'agentProtocolVersion',
      'protocolSha256',
    },
  );
  if (front['docSchemaVersion'] is! int ||
      front['docSchemaVersion'] != 2 ||
      front['profile'] != 'maaso.agent.document.v2' ||
      front['projectId'] != manifest.projectId ||
      front['revisionId'] != manifest.revisionId ||
      front['contentManifestId'] != manifest.contentManifestId ||
      front['agentProtocolVersion'] is! int ||
      front['agentProtocolVersion'] != 2 ||
      front['protocolSha256'] != protocolSha256) {
    _fail('agent_document_identity');
  }
}

void _validateImage(ProjectBundleV2File file) {
  final bytes = Uint8List.fromList(file.bytes);
  final png =
      bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10;
  final jpeg =
      bytes.length >= 4 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255 &&
      bytes[bytes.length - 2] == 255 &&
      bytes.last == 217;
  if ((file.metadata.mimeType == 'image/png' && !png) ||
      (file.metadata.mimeType == 'image/jpeg' && !jpeg)) {
    _fail('image_signature');
  }
  final decoder = image.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width < 1 ||
      info.height < 1 ||
      info.width > ProjectBundleV2Limits.maxImageDimension ||
      info.height > ProjectBundleV2Limits.maxImageDimension ||
      info.width * info.height > ProjectBundleV2Limits.maxImagePixels) {
    _fail('image_dimensions');
  }
}

/// First production profile is an ASCII POSIX subset (therefore NFC), not a
/// promise that arbitrary Unicode filenames or platform-specific aliases work.
void validateProjectBundleV2Path(String path) {
  if (path.isEmpty || path.length > 240) _fail('path');
  final parts = path.split('/');
  if (parts.length > 12) _fail('path');
  for (final part in parts) {
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$').hasMatch(part) ||
        part.endsWith('.')) {
      _fail('path');
    }
    if (RegExp(
      r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
      caseSensitive: false,
    ).hasMatch(part.split('.').first)) {
      _fail('path_reserved');
    }
  }
}

final class _ProjectPathInventory {
  final _files = <String>{};
  final _directories = <String, String>{};
  void add(String path) {
    final lower = path.toLowerCase();
    if (!_files.add(lower) || _directories.containsKey(lower)) {
      _fail('path_collision');
    }
    final parts = path.split('/');
    for (var length = 1; length < parts.length; length++) {
      final directory = parts.take(length).join('/');
      final key = directory.toLowerCase();
      if (_files.contains(key) ||
          (_directories.containsKey(key) && _directories[key] != directory)) {
        _fail('path_collision');
      }
      _directories[key] = directory;
    }
  }
}

Never _fail(String code) => throw FormatException('project_bundle_v2.$code');
Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _fail('object');
  return Map<String, Object?>.from(value);
}

Map<String, Object?> _object(Object? value, Set<String> fields) {
  final result = _map(value);
  if (result.length != fields.length ||
      result.keys.any((key) => !fields.contains(key))) {
    _fail('fields');
  }
  return result;
}

String _text(Object? value) {
  if (value is! String) _fail('string');
  return value;
}

String _semanticId(Object? value) {
  final text = _text(value);
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$').hasMatch(text)) {
    _fail('semantic_id');
  }
  return text;
}

void _boundedText(Object? value, {required int minimum, required int maximum}) {
  final text = _text(value);
  if (text.runes.length < minimum ||
      text.runes.length > maximum ||
      (minimum > 0 && text.trim().isEmpty) ||
      text.runes.any((rune) => rune < 32 || rune == 127)) {
    _fail('text');
  }
}

int _integer(Object? value, {int minimum = 0, int maximum = 9007199254740991}) {
  if (value is! int || value < minimum || value > maximum) _fail('integer');
  return value;
}

void _digest(String value) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) _fail('digest');
}

void _id(Object? value, String kind) {
  if (!RegExp(
    '^pb_${kind}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$',
  ).hasMatch(_text(value))) {
    _fail('identity');
  }
}
