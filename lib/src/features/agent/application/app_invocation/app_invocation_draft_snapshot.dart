import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

/// A recoverable description of the user's frozen draft. It has no executable
/// callbacks, native grants, image bytes or permission to invoke a work.
final class AppInvocationDraftSnapshot {
  AppInvocationDraftSnapshot({
    required String scopeKey,
    required String text,
    required List<Map<String, Object?>> imageHandles,
    required String sourceOrigin,
    required String sourceId,
    int? localWidgetId,
    String? clientSurfaceId,
    required String sourceType,
    required String sourceTitle,
    required String revisionId,
    required String sourceDigest,
    required String contractDigest,
    required String adapterId,
    required String adapterVersion,
  }) : this.fromJson({
         'schemaVersion': 1,
         'scopeKey': scopeKey,
         'text': text,
         'imageHandles': imageHandles,
         'sourceOrigin': sourceOrigin,
         'sourceId': sourceId,
         if (localWidgetId != null) 'localWidgetId': localWidgetId,
         if (clientSurfaceId != null) 'clientSurfaceId': clientSurfaceId,
         'sourceType': sourceType,
         'sourceTitle': sourceTitle,
         'revisionId': revisionId,
         'sourceDigest': sourceDigest,
         'contractDigest': contractDigest,
         'adapterId': adapterId,
         'adapterVersion': adapterVersion,
       });

  AppInvocationDraftSnapshot.fromJson(Object? record) {
    final value = _json.parse(_json.canonicalize(record));
    if (value is! Map<String, Object?> ||
        value['schemaVersion'] != 1 ||
        value.keys.any((key) => !_keys.contains(key)))
      throw const FormatException('invocation_draft_invalid');
    String field(String name, int limit, {bool empty = false}) {
      final item = value[name];
      if (item is! String ||
          (!empty && item.trim().isEmpty) ||
          utf8.encode(item).length > limit) {
        throw const FormatException('invocation_draft_invalid');
      }
      return item;
    }

    scopeKey = field('scopeKey', 1024);
    text = field('text', 64 * 1024, empty: true);
    sourceOrigin = field('sourceOrigin', 32);
    sourceId = field('sourceId', 512);
    sourceType = field('sourceType', 16);
    sourceTitle = field('sourceTitle', 1024, empty: true);
    revisionId = field('revisionId', 512);
    sourceDigest = field('sourceDigest', 64);
    contractDigest = field('contractDigest', 64);
    adapterId = field('adapterId', 256);
    adapterVersion = field('adapterVersion', 256);
    if (!const {
          'local',
          'publicCatalog',
          'ownedCatalog',
          'official',
        }.contains(sourceOrigin) ||
        !const {'game', 'applet'}.contains(sourceType) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceDigest) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(contractDigest))
      throw const FormatException('invocation_draft_invalid');
    final local = value['localWidgetId'];
    if (local != null && (local is! int || local < 0))
      throw const FormatException('invocation_draft_invalid');
    localWidgetId = local as int?;
    clientSurfaceId = value['clientSurfaceId'] == null
        ? null
        : field('clientSurfaceId', 512);
    if (sourceOrigin == 'local' && localWidgetId == null)
      throw const FormatException('invocation_draft_invalid');
    final images = value['imageHandles'];
    if (images is! List || images.length > 4)
      throw const FormatException('invocation_draft_images');
    final ids = <String>{};
    imageHandles = List.unmodifiable(
      images.map((image) {
        if (image is! Map<String, Object?> ||
            image.length != 4 ||
            image['id'] is! String ||
            (image['id']! as String).isEmpty ||
            (image['id']! as String).length > 128 ||
            !ids.add(image['id']! as String) ||
            !const {'image/png', 'image/jpeg'}.contains(image['mime']) ||
            image['byteLength'] is! int ||
            (image['byteLength']! as int) < 1 ||
            (image['byteLength']! as int) > 12 * 1024 * 1024 ||
            image['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(image['sha256']! as String)) {
          throw const FormatException('invocation_draft_images');
        }
        return Map<String, Object?>.unmodifiable(image);
      }),
    );
  }
  static const _json = ProjectJsonCanonicalizer(
    maxBytes: 128 * 1024,
    maxDepth: 8,
    maxNodes: 256,
  );
  static const _keys = {
    'schemaVersion',
    'scopeKey',
    'text',
    'imageHandles',
    'sourceOrigin',
    'sourceId',
    'localWidgetId',
    'clientSurfaceId',
    'sourceType',
    'sourceTitle',
    'revisionId',
    'sourceDigest',
    'contractDigest',
    'adapterId',
    'adapterVersion',
  };
  late final String scopeKey,
      text,
      sourceOrigin,
      sourceId,
      sourceType,
      sourceTitle,
      revisionId,
      sourceDigest,
      contractDigest,
      adapterId,
      adapterVersion;
  late final int? localWidgetId;
  late final String? clientSurfaceId;
  late final List<Map<String, Object?>> imageHandles;
  String get inputDigest => sha256
      .convert(
        utf8.encode(_json.canonicalize({'text': text, 'images': imageHandles})),
      )
      .toString();
  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'scopeKey': scopeKey,
    'text': text,
    'imageHandles': imageHandles,
    'sourceOrigin': sourceOrigin,
    'sourceId': sourceId,
    if (localWidgetId != null) 'localWidgetId': localWidgetId,
    if (clientSurfaceId != null) 'clientSurfaceId': clientSurfaceId,
    'sourceType': sourceType,
    'sourceTitle': sourceTitle,
    'revisionId': revisionId,
    'sourceDigest': sourceDigest,
    'contractDigest': contractDigest,
    'adapterId': adapterId,
    'adapterVersion': adapterVersion,
  };
}
