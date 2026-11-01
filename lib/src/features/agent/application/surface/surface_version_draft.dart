import 'surface_version_history.dart';

/// Host-issued candidate source. It has no successful version number until a
/// human applies it against both the original source and this exact draft id.
final class SurfaceVersionDraft {
  SurfaceVersionDraft._({
    required this.id,
    required this.baseFingerprint,
    required this.title,
    required Map<String, Object?> source,
    required this.createdAtMillis,
  }) : source = _freeze(source) as Map<String, Object?>,
       sourceSha256 = surfaceSourceSha256(source);

  factory SurfaceVersionDraft.create({
    required Map<String, Object?> source,
    required String title,
    required String baseFingerprint,
  }) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final normalized = surfaceVersionSource(source, title: title);
    return SurfaceVersionDraft._(
      id: 'draft_${now}_${surfaceSourceSha256(normalized).substring(0, 12)}',
      baseFingerprint: baseFingerprint,
      title: title,
      source: normalized,
      createdAtMillis: now ~/ 1000,
    );
  }

  final String id;
  final String baseFingerprint;
  final String title;
  final Map<String, Object?> source;
  final String sourceSha256;
  final int createdAtMillis;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'baseFingerprint': baseFingerprint,
    'title': title,
    'source': source,
    'sourceSha256': sourceSha256,
    'createdAtMillis': createdAtMillis,
  };

  static SurfaceVersionDraft? tryParse(Object? raw) {
    if (raw is! Map || raw['schemaVersion'] != 1) return null;
    try {
      final id = raw['id'] as String;
      final baseline = raw['baseFingerprint'] as String;
      final title = raw['title'] as String;
      if (!RegExp(r'^draft_[0-9]+_[a-f0-9]{12}$').hasMatch(id) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(baseline) ||
          title.length > 240) {
        return null;
      }
      final draft = SurfaceVersionDraft._(
        id: id,
        baseFingerprint: baseline,
        title: title,
        source: Map<String, Object?>.from(raw['source'] as Map),
        createdAtMillis: raw['createdAtMillis'] as int,
      );
      if (draft.sourceSha256 != raw['sourceSha256'] ||
          draft.createdAtMillis < 0) {
        return null;
      }
      return draft;
    } catch (_) {
      return null;
    }
  }
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, value) => MapEntry(key.toString(), _freeze(value))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
