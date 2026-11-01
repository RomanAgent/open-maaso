import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Structural, byte-level preflight for a local project bundle.
///
/// This profile does not execute source, validate game rules, grant permissions,
/// or certify offline resource usage. The protocol contains an interface
/// inventory only; it cannot activate verified or playable capabilities.
const projectBundlePreflightProfile = 'maaso.project.preflight.v2';

abstract final class ProjectBundleLimits {
  static const maxFiles = 256;
  static const maxFileBytes = 8 * 1024 * 1024;
  static const maxBundleBytes = 32 * 1024 * 1024;
  static const maxDocumentBytes = 256 * 1024;
}

Never _reject(String code) => throw FormatException('project_bundle.$code');

/// Hashes the original bytes, without text decoding or newline normalization.
String projectBundleFileSha256(List<int> bytes) {
  _validateBytes(bytes);
  return sha256.convert(bytes).toString();
}

final class ProjectBundleFile {
  ProjectBundleFile({required this.path, required List<int> bytes})
    : bytes = _snapshotBytes(bytes) {
    _validatePath(path);
  }

  final String path;
  final List<int> bytes;
}

final class ProjectBundleFileEntry {
  const ProjectBundleFileEntry._({
    required this.path,
    required this.byteLength,
    required this.sha256,
  });

  final String path;
  final int byteLength;
  final String sha256;

  Map<String, Object?> toJson() => {
    'byteLength': byteLength,
    'path': path,
    'sha256': sha256,
  };
}

final class ProjectBundleManifest {
  ProjectBundleManifest._({
    required this.projectId,
    required this.revisionId,
    required this.entryPoint,
    required List<ProjectBundleFileEntry> files,
  }) : files = List.unmodifiable(files);

  /// Prefer this entry point for JSON text: duplicate keys are rejected before
  /// decoding can overwrite them. [fromJson] accepts an already decoded object.
  factory ProjectBundleManifest.parse(String source) =>
      ProjectBundleManifest.fromJson(_decodeJson(source));

  factory ProjectBundleManifest.fromJson(Object? value) {
    final raw = _object(value, const {
      'schemaVersion',
      'profile',
      'projectId',
      'revisionId',
      'protocolVersion',
      'entryPoint',
      'files',
    });
    _requireVersion(raw['schemaVersion']);
    _requireVersion(raw['protocolVersion']);
    _requireProfile(raw['profile']);
    final projectId = _id(raw['projectId']);
    final revisionId = _id(raw['revisionId']);
    final entryPoint = _path(raw['entryPoint']);
    if (!entryPoint.endsWith('.html')) _reject('entry_point_not_html');
    final entries = _list(
      raw['files'],
      maximum: ProjectBundleLimits.maxFiles,
      nonEmpty: true,
    );
    final files = <ProjectBundleFileEntry>[];
    final paths = _PathInventory();
    var totalBytes = 0;
    for (final value in entries) {
      final entry = _object(value, const {'path', 'byteLength', 'sha256'});
      final path = _path(entry['path']);
      paths.add(path);
      final length = _boundedInt(
        entry['byteLength'],
        0,
        ProjectBundleLimits.maxFileBytes,
      );
      final digest = entry['sha256'];
      if (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        _reject('invalid_sha256');
      }
      totalBytes += length;
      if (totalBytes > ProjectBundleLimits.maxBundleBytes) {
        _reject('bundle_too_large');
      }
      files.add(
        ProjectBundleFileEntry._(
          path: path,
          byteLength: length,
          sha256: digest,
        ),
      );
    }
    final exactPaths = files.map((file) => file.path).toSet();
    if (!exactPaths.contains(entryPoint) ||
        !exactPaths.contains('agent.md') ||
        !exactPaths.contains('agent.protocol.json')) {
      _reject('required_file_missing');
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return ProjectBundleManifest._(
      projectId: projectId,
      revisionId: revisionId,
      entryPoint: entryPoint,
      files: files,
    );
  }

  final String projectId;
  final String revisionId;
  final String entryPoint;
  final List<ProjectBundleFileEntry> files;

  int get schemaVersion => 2;
  int get protocolVersion => 2;
  String get profile => projectBundlePreflightProfile;

  Map<String, Object?> toJson() => {
    'entryPoint': entryPoint,
    'files': files.map((file) => file.toJson()).toList(growable: false),
    'profile': profile,
    'projectId': projectId,
    'protocolVersion': protocolVersion,
    'revisionId': revisionId,
    'schemaVersion': schemaVersion,
  };

  /// Fixed-schema canonical JSON, not a general RFC 8785/JCS implementation.
  /// Keys are fixed ASCII, strings here are ASCII, lengths are bounded integers,
  /// and file entries are sorted by path. No arbitrary JSON is hashed here.
  String get canonicalJson => jsonEncode(toJson());

  /// This manifest is supplied separately, never included among its own files.
  String get bundleDigest => sha256
      .convert(utf8.encode('$projectBundlePreflightProfile\n$canonicalJson'))
      .toString();
}

/// A structurally valid inventory, not permission to invoke an action.
final class ProjectBundleProtocol {
  ProjectBundleProtocol._(this._json);

  final Map<String, Object?> _json;
  Map<String, Object?> toJson() => _json;
}

final class VerifiedProjectBundle {
  VerifiedProjectBundle._({
    required this.manifest,
    required Map<String, List<int>> files,
    required this.agentMarkdown,
    required this.protocol,
  }) : files = Map.unmodifiable(files);

  final ProjectBundleManifest manifest;
  final Map<String, List<int>> files;
  final String agentMarkdown;
  final ProjectBundleProtocol protocol;
  String get bundleDigest => manifest.bundleDigest;
}

final class ProjectBundleValidator {
  const ProjectBundleValidator();

  /// Verifies the exact file set and bytes before reading either contract.
  /// Files must already be regular file contents; filesystem/ZIP extraction and
  /// symlink checks are responsibilities of the caller, before reading bytes.
  VerifiedProjectBundle verify(
    ProjectBundleManifest manifest,
    Iterable<ProjectBundleFile> files,
  ) {
    final expected = {for (final entry in manifest.files) entry.path: entry};
    final actual = <String, List<int>>{};
    final paths = _PathInventory();
    var totalBytes = 0;
    for (final file in files) {
      if (actual.length >= ProjectBundleLimits.maxFiles) {
        _reject('too_many_files');
      }
      paths.add(file.path);
      final entry = expected[file.path];
      if (entry == null) _reject('unexpected_file');
      final bytes = file.bytes;
      totalBytes += bytes.length;
      if (totalBytes > ProjectBundleLimits.maxBundleBytes) {
        _reject('bundle_too_large');
      }
      if (entry.byteLength != bytes.length) _reject('length_mismatch');
      if (entry.sha256 != projectBundleFileSha256(bytes)) {
        _reject('digest_mismatch');
      }
      actual[file.path] = bytes;
    }
    if (actual.length != expected.length) _reject('file_missing');
    final protocol = _verifyProtocol(
      _decodeJson(_document(actual['agent.protocol.json']!)),
      manifest,
    );
    final markdown = _document(actual['agent.md']!);
    _verifyAgentDocument(
      markdown,
      manifest,
      expected['agent.protocol.json']!.sha256,
    );
    return VerifiedProjectBundle._(
      manifest: manifest,
      files: actual,
      agentMarkdown: markdown,
      protocol: protocol,
    );
  }
}

ProjectBundleProtocol _verifyProtocol(
  Object? value,
  ProjectBundleManifest manifest,
) {
  final raw = _object(value, const {
    'protocolVersion',
    'profile',
    'projectId',
    'revisionId',
    'routes',
    'actions',
  });
  _verifyIdentity(raw, manifest);
  final routeValues = _list(raw['routes'], maximum: 64, nonEmpty: true);
  final routes = <Map<String, Object?>>[];
  final routeParents = <String, String?>{};
  final routePaths = <String>{};
  final files = manifest.files.map((file) => file.path).toSet();
  String? rootId;
  for (final value in routeValues) {
    final route = _object(value, const {'id', 'path', 'parentId'});
    final id = _semanticId(route['id']);
    final path = _path(route['path']);
    final parent = route['parentId'] == null
        ? null
        : _semanticId(route['parentId']);
    if (routeParents.containsKey(id)) _reject('duplicate_route_id');
    if (!routePaths.add(path)) _reject('duplicate_route_path');
    if (!path.endsWith('.html') || !files.contains(path)) {
      _reject('route_file_missing');
    }
    if (parent == null) {
      if (rootId != null || path != manifest.entryPoint) {
        _reject('invalid_route_root');
      }
      rootId = id;
    }
    routeParents[id] = parent;
    routes.add(Map.unmodifiable({'id': id, 'path': path, 'parentId': parent}));
  }
  if (rootId == null) _reject('invalid_route_root');
  for (final id in routeParents.keys) {
    final seen = <String>{};
    String? current = id;
    while (current != null) {
      if (!seen.add(current)) _reject('route_cycle');
      if (!routeParents.containsKey(current)) _reject('route_parent_missing');
      current = routeParents[current];
    }
  }
  final actionValues = _list(raw['actions'], maximum: 128);
  final actions = <Map<String, Object?>>[];
  final actionIds = <String>{};
  for (final value in actionValues) {
    final action = _object(value, const {'id', 'routeId'});
    final id = _semanticId(action['id']);
    final routeId = _semanticId(action['routeId']);
    if (!actionIds.add(id)) _reject('duplicate_action_id');
    if (!routeParents.containsKey(routeId)) _reject('action_route_missing');
    actions.add(Map.unmodifiable({'id': id, 'routeId': routeId}));
  }
  return ProjectBundleProtocol._(
    Map.unmodifiable({
      'protocolVersion': 2,
      'profile': projectBundlePreflightProfile,
      'projectId': manifest.projectId,
      'revisionId': manifest.revisionId,
      'routes': List.unmodifiable(routes),
      'actions': List.unmodifiable(actions),
    }),
  );
}

void _verifyAgentDocument(
  String source,
  ProjectBundleManifest manifest,
  String protocolSha256,
) {
  // JSON is the only supported front matter dialect. No YAML tags, aliases,
  // implicit coercion or executable directives are interpreted.
  final match = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n').firstMatch(source);
  if (match == null) _reject('agent_front_matter_missing');
  final header = match.group(1)!;
  if (utf8.encode(header).length > 4096) {
    _reject('agent_front_matter_too_large');
  }
  final raw = _object(_decodeJson(header), const {
    'docSchemaVersion',
    'profile',
    'projectId',
    'revisionId',
    'protocolVersion',
    'protocolSha256',
  });
  _requireVersion(raw['docSchemaVersion']);
  _verifyIdentity(raw, manifest);
  if (raw['protocolSha256'] != protocolSha256) {
    _reject('protocol_digest_mismatch');
  }
  if (source.substring(match.end).trim().isEmpty) _reject('agent_body_missing');
}

void _verifyIdentity(
  Map<Object?, Object?> raw,
  ProjectBundleManifest manifest,
) {
  _requireVersion(raw['protocolVersion']);
  _requireProfile(raw['profile']);
  if (_id(raw['projectId']) != manifest.projectId ||
      _id(raw['revisionId']) != manifest.revisionId) {
    _reject('identity_mismatch');
  }
}

Map<Object?, Object?> _object(Object? value, Set<String> fields) {
  if (value is! Map ||
      value.length != fields.length ||
      value.keys.any((key) => key is! String || !fields.contains(key))) {
    _reject('invalid_fields');
  }
  return value;
}

List<Object?> _list(
  Object? value, {
  required int maximum,
  bool nonEmpty = false,
}) {
  if (value is! List || value.length > maximum || (nonEmpty && value.isEmpty)) {
    _reject('invalid_collection');
  }
  return value;
}

int _boundedInt(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    _reject('invalid_integer');
  }
  return value;
}

void _requireVersion(Object? value) {
  if (value is! int || value != 2) _reject('unsupported_version');
}

void _requireProfile(Object? value) {
  if (value != projectBundlePreflightProfile) _reject('unsupported_profile');
}

String _id(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$').hasMatch(value)) {
    _reject('invalid_identity');
  }
  return value;
}

String _semanticId(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,95}$').hasMatch(value)) {
    _reject('invalid_semantic_id');
  }
  return value;
}

String _path(Object? value) {
  if (value is! String) _reject('invalid_path');
  _validatePath(value);
  return value;
}

void _validatePath(String path) {
  // A deliberately restricted, already-normalized ASCII portable subset.
  // Reject aliases instead of decoding URLs or normalizing Unicode/separators.
  if (path.isEmpty || path.length > 240) _reject('invalid_path');
  final segments = path.split('/');
  if (segments.length > 12) _reject('invalid_path');
  for (final segment in segments) {
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$').hasMatch(segment) ||
        segment.endsWith('.')) {
      _reject('invalid_path');
    }
    final stem = segment.split('.').first.toLowerCase();
    if (RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$').hasMatch(stem)) {
      _reject('reserved_path');
    }
  }
}

final class _PathInventory {
  final _files = <String>{};
  final _prefixes = <String, String>{};

  void add(String path) {
    final lower = path.toLowerCase();
    if (!_files.add(lower)) _reject('duplicate_path');
    if (_prefixes.containsKey(lower)) _reject('path_conflict');
    final segments = path.split('/');
    for (var count = 1; count < segments.length; count++) {
      final prefix = segments.take(count).join('/');
      final key = prefix.toLowerCase();
      if (_files.contains(key)) _reject('path_conflict');
      final previous = _prefixes[key];
      if (previous != null && previous != prefix) _reject('path_case_alias');
      _prefixes[key] = prefix;
    }
  }
}

void _validateBytes(List<int> bytes) {
  if (bytes.length > ProjectBundleLimits.maxFileBytes) {
    _reject('file_too_large');
  }
  if (bytes.any((byte) => byte < 0 || byte > 255)) _reject('invalid_bytes');
}

List<int> _snapshotBytes(List<int> bytes) {
  _validateBytes(bytes);
  return List.unmodifiable(bytes);
}

String _document(List<int> bytes) {
  if (bytes.length > ProjectBundleLimits.maxDocumentBytes) {
    _reject('document_too_large');
  }
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    _reject('invalid_utf8');
  }
}

Object? _decodeJson(String source) {
  if (utf8.encode(source).length > ProjectBundleLimits.maxDocumentBytes) {
    _reject('document_too_large');
  }
  return _ContractJsonReader(source).read();
}

/// The wire profile needs only strings, bounded integers, null and containers.
/// A small strict reader rejects duplicate keys and bounds nesting before maps
/// are built. It deliberately does not implement arbitrary JSON number forms.
final class _ContractJsonReader {
  _ContractJsonReader(this.source);

  final String source;
  int offset = 0;
  int nodes = 0;

  Object? read() {
    final result = _value(0);
    _space();
    if (offset != source.length) _reject('invalid_json');
    return result;
  }

  void _space() {
    while (offset < source.length &&
        const [0x20, 0x09, 0x0a, 0x0d].contains(source.codeUnitAt(offset))) {
      offset++;
    }
  }

  bool _take(String character) {
    _space();
    if (offset < source.length && source[offset] == character) {
      offset++;
      return true;
    }
    return false;
  }

  void _expect(String character) {
    if (!_take(character)) _reject('invalid_json');
  }

  Object? _value(int depth) {
    if (depth > 16 || ++nodes > 16384) _reject('json_budget_exceeded');
    _space();
    if (offset >= source.length) _reject('invalid_json');
    if (source[offset] == '"') return _string();
    if (_take('{')) {
      final map = <String, Object?>{};
      if (_take('}')) return map;
      do {
        _space();
        final key = _string();
        if (map.containsKey(key)) _reject('duplicate_json_key');
        _expect(':');
        map[key] = _value(depth + 1);
        if (_take('}')) return map;
        _expect(',');
      } while (true);
    }
    if (_take('[')) {
      final list = <Object?>[];
      if (_take(']')) return list;
      do {
        list.add(_value(depth + 1));
        if (_take(']')) return list;
        _expect(',');
      } while (true);
    }
    for (final literal in const ['null', 'true', 'false']) {
      if (source.startsWith(literal, offset)) {
        offset += literal.length;
        return switch (literal) {
          'null' => null,
          'true' => true,
          _ => false,
        };
      }
    }
    final match = RegExp(r'-?(?:0|[1-9][0-9]*)').matchAsPrefix(source, offset);
    if (match == null) _reject('invalid_json');
    offset = match.end;
    final number = int.tryParse(match.group(0)!);
    if (number == null || number.abs() > 0x7fffffff) _reject('invalid_integer');
    return number;
  }

  String _string() {
    if (offset >= source.length || source[offset] != '"') {
      _reject('invalid_json');
    }
    final start = offset++;
    while (offset < source.length) {
      final character = source[offset++];
      if (character == r'\') {
        offset++;
      } else if (character == '"') {
        try {
          return jsonDecode(source.substring(start, offset)) as String;
        } on FormatException {
          _reject('invalid_json');
        }
      }
    }
    _reject('invalid_json');
  }
}
