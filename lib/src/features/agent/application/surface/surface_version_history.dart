import 'dart:convert';

import 'package:crypto/crypto.dart';

/// An immutable, offline-readable version. Cloud revision numbers are separate:
/// one local version need not correspond to one server sync.
final class SurfaceVersionSnapshot {
  SurfaceVersionSnapshot({
    required this.id,
    required this.number,
    required Map<String, Object?> source,
    required this.createdAtMillis,
    this.parentId,
    this.restoredFromId,
    this.restoredFromCloudRevisionNo,
    this.note = '',
    this.taskId,
    this.taskAttempt,
    this.cloudRevisionNo,
  }) : source = _freeze(source) as Map<String, Object?>,
       sourceSha256 = surfaceSourceSha256(source);

  final String id;
  final int number;
  final Map<String, Object?> source;
  final String sourceSha256;
  final int createdAtMillis;
  final String? parentId;
  final String? restoredFromId;
  final int? restoredFromCloudRevisionNo;
  final String note;
  final String? taskId;
  final int? taskAttempt;
  final int? cloudRevisionNo;

  factory SurfaceVersionSnapshot.fromJson(Map raw) {
    final source = _map(raw['source']);
    final version = SurfaceVersionSnapshot(
      id: raw['id'] as String,
      number: raw['number'] as int,
      source: source,
      createdAtMillis: raw['createdAtMillis'] as int? ?? 0,
      parentId: raw['parentId'] as String?,
      restoredFromId: raw['restoredFromId'] as String?,
      restoredFromCloudRevisionNo: raw['restoredFromCloudRevisionNo'] as int?,
      note: raw['note'] as String? ?? '',
      taskId: raw['taskId'] as String?,
      taskAttempt: raw['taskAttempt'] as int?,
      cloudRevisionNo: raw['cloudRevisionNo'] as int?,
    );
    if (version.id.isEmpty ||
        version.number < 1 ||
        raw['sourceSha256'] != version.sourceSha256) {
      throw const FormatException('surface_version_history_invalid');
    }
    return version;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'number': number,
    'source': source,
    'sourceSha256': sourceSha256,
    'createdAtMillis': createdAtMillis,
    if (parentId != null) 'parentId': parentId,
    if (restoredFromId != null) 'restoredFromId': restoredFromId,
    if (restoredFromCloudRevisionNo != null)
      'restoredFromCloudRevisionNo': restoredFromCloudRevisionNo,
    if (note.isNotEmpty) 'note': note,
    if (taskId != null) 'taskId': taskId,
    if (taskAttempt != null) 'taskAttempt': taskAttempt,
    if (cloudRevisionNo != null) 'cloudRevisionNo': cloudRevisionNo,
  };
}

/// Append-only local history. Migration is lazy and preserves the legacy
/// `revisions` field verbatim; missing historical content is never invented.
final class SurfaceVersionHistory {
  SurfaceVersionHistory._(Iterable<SurfaceVersionSnapshot> versions)
    : versions = List.unmodifiable(versions);

  final List<SurfaceVersionSnapshot> versions;
  SurfaceVersionSnapshot get current => versions.last;

  factory SurfaceVersionHistory.create(
    Map<String, Object?> spec, {
    required String title,
  }) {
    final source = surfaceVersionSource(spec, title: title);
    return SurfaceVersionHistory._([
      SurfaceVersionSnapshot(
        id: _id(1, source),
        number: 1,
        source: source,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
  }

  factory SurfaceVersionHistory.read(
    Map<String, Object?> spec, {
    required String title,
  }) {
    final raw = spec['versionHistory'];
    if (raw != null) {
      if (raw is! Map ||
          raw['schemaVersion'] != 1 ||
          raw['versions'] is! List) {
        throw const FormatException('surface_version_history_invalid');
      }
      final entries = (raw['versions'] as List)
          .map((value) => SurfaceVersionSnapshot.fromJson(value as Map))
          .toList();
      if (entries.isEmpty || raw['currentVersionId'] != entries.last.id) {
        throw const FormatException('surface_version_history_invalid');
      }
      final ids = <String>{};
      var previous = 0;
      for (final entry in entries) {
        if (!ids.add(entry.id) || entry.number <= previous) {
          throw const FormatException('surface_version_history_invalid');
        }
        if ((entry.parentId != null && !ids.contains(entry.parentId)) ||
            (entry.restoredFromId != null &&
                !ids.contains(entry.restoredFromId)) ||
            entry.parentId == entry.id ||
            entry.restoredFromId == entry.id) {
          throw const FormatException('surface_version_history_invalid');
        }
        previous = entry.number;
      }
      return SurfaceVersionHistory._(entries);
    }
    final entries = <SurfaceVersionSnapshot>[];
    final legacy = spec['revisions'];
    if (legacy is List) {
      for (final rawRevision in legacy) {
        if (rawRevision is! Map ||
            rawRevision['html'] is! String ||
            rawRevision['css'] is! String ||
            rawRevision['js'] is! String) {
          continue;
        }
        final revision = _map(rawRevision);
        final source = surfaceVersionSource(
          revision,
          title: revision['title']?.toString() ?? title,
        );
        final number = entries.length + 1;
        final originalId = revision['id']?.toString() ?? '';
        final id =
            originalId.isNotEmpty && !entries.any((v) => v.id == originalId)
            ? originalId
            : _id(number, source);
        entries.add(
          SurfaceVersionSnapshot(
            id: id,
            number: number,
            source: source,
            createdAtMillis:
                (revision['createdAtMillis'] as num?)?.toInt() ??
                DateTime.tryParse(
                  revision['createdAt']?.toString() ?? '',
                )?.millisecondsSinceEpoch ??
                0,
            parentId: entries.isEmpty ? null : entries.last.id,
            note: revision['note']?.toString() ?? '',
          ),
        );
      }
    }
    final source = surfaceVersionSource(spec, title: title);
    entries.add(
      SurfaceVersionSnapshot(
        id: _id(entries.length + 1, source),
        number: entries.length + 1,
        source: source,
        createdAtMillis: 0,
        parentId: entries.isEmpty ? null : entries.last.id,
      ),
    );
    return SurfaceVersionHistory._(entries);
  }

  SurfaceVersionSnapshot? find(String id) {
    for (final version in versions) {
      if (version.id == id) return version;
    }
    return null;
  }

  SurfaceVersionHistory append(
    Map<String, Object?> spec, {
    required String title,
    String? restoredFromId,
    int? restoredFromCloudRevisionNo,
    String note = '',
    String? taskId,
    int? taskAttempt,
  }) {
    final source = surfaceVersionSource(spec, title: title);
    final number = current.number + 1;
    return SurfaceVersionHistory._([
      ...versions,
      SurfaceVersionSnapshot(
        id: _id(number, source),
        number: number,
        source: source,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
        parentId: current.id,
        restoredFromId: restoredFromId,
        restoredFromCloudRevisionNo: restoredFromCloudRevisionNo,
        note: note,
        taskId: taskId,
        taskAttempt: taskAttempt,
      ),
    ]);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'currentVersionId': current.id,
    'versions': versions.map((entry) => entry.toJson()).toList(growable: false),
  };

  static String _id(int number, Map<String, Object?> source) =>
      'version_${number}_${surfaceSourceSha256(source).substring(0, 16)}';
}

/// Only executable source/presentation fields participate. Sync, ownership,
/// history and publication metadata never become executable source.
Map<String, Object?> surfaceVersionSource(
  Map spec, {
  required String title,
}) => {
  'title': title,
  'surfaceKind':
      spec['surfaceKind'] ?? spec['surface'] ?? spec['kind'] ?? 'card',
  'rendering': spec['rendering'] ?? 'dom',
  'html': spec['html'] ?? '',
  'css': spec['css'] ?? '',
  'js': spec['js'] ?? '',
  'transparent': spec['transparent'] == true,
  'placement':
      spec['placement'] ?? const {'x': 0, 'y': 0, 'width': 1, 'height': 1},
  'manifest': spec['manifest'] ?? const {},
  'backend': spec['backend'] ?? const {},
  'experienceType': spec['experienceType'] ?? 'utility',
  'category':
      spec['category'] ?? (spec['experienceType'] == 'game' ? 'game' : 'tools'),
  'skillInstructions': spec['skillInstructions'] ?? '',
};

String surfaceSourceSha256(Map<String, Object?> source) =>
    sha256.convert(utf8.encode(jsonEncode(_freeze(source)))).toString();

/// Includes the version reference to reject ABA (edit, restore, stale edit).
String surfaceVersionFingerprint(Map spec, {required String title}) =>
    surfaceSourceSha256({
      'source': surfaceVersionSource(spec, title: title),
      'currentVersionId': spec['versionHistory'] is Map
          ? (spec['versionHistory'] as Map)['currentVersionId']
          : null,
    });

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : {};

Object? _freeze(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return Map<String, Object?>.unmodifiable({
      for (final key in keys) key: _freeze(value[key]),
    });
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
