import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:sembast/sembast.dart';

/// The original Applet Hub's catalog, publication and feedback records on the
/// currently mounted account database. No transport or socket is involved.
class OriginalUiLocalCatalog {
  OriginalUiLocalCatalog({
    required this.database,
    required this.scopeKey,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DBService database;
  final String Function() scopeKey;
  final DateTime Function() _now;
  static final _works = stringMapStoreFactory.store('local_applet_catalog');
  static final _feedback = stringMapStoreFactory.store('local_applet_feedback');
  static final _comments = stringMapStoreFactory.store('local_applet_comments');

  String _key(String scope, String id) => '$scope|$id';

  void _requireScope(String expected) {
    if (scopeKey() != expected) {
      throw StateError('applet_request_context_changed');
    }
  }

  Future<List<AgentWidget>> _widgets(String scope) async {
    final rows = await database.getAllWidgets();
    _requireScope(scope);
    return rows
        .where(
          (row) =>
              row.isSurface &&
              AppletLocalOwnership.storedScopeKey(row) == scope &&
              row.spec['cloudDelete'] == null,
        )
        .toList();
  }

  Future<AppletQuotaSnapshot> quota() async {
    final rows = await _widgets(scopeKey());
    // The old hosted catalog's five-item limit does not apply to local files.
    return AppletQuotaSnapshot(used: rows.length, limit: 1000000);
  }

  Future<AppletInventoryPage> mine() async {
    final scope = scopeKey();
    final rows = await _widgets(scope);
    final items = <AppletInventoryItem>[];
    for (final row in rows) {
      final id = idFor(row);
      final record = await _works.record(_key(scope, id)).get(database.raw);
      final feedback = await _engagement(scope, id);
      items.add(
        AppletInventoryItem(
          id: id,
          clientSurfaceId: surfaceIdFor(row),
          title: row.title,
          type: row.spec['experienceType'] == 'game'
              ? AppletCatalogType.game
              : AppletCatalogType.applet,
          summary: row.subtitle ?? '',
          published: record?['published'] == true,
          updatedAt: row.createdAt,
          category: row.spec['category']?.toString() ?? '',
          skillInstructions: row.spec['skillInstructions']?.toString() ?? '',
          viewCount: feedback['viewCount'] as int,
          likeCount: feedback['likeCount'] as int,
          shareCount: feedback['shareCount'] as int,
          commentCount: feedback['commentCount'] as int,
        ),
      );
    }
    _requireScope(scope);
    return AppletInventoryPage(
      items: items,
      quota: AppletQuotaSnapshot(used: rows.length, limit: 1000000),
    );
  }

  Future<AppletCatalogPage> browse({
    String query = '',
    AppletCatalogType? type,
    String? category,
    String? cursor,
    int limit = 12,
    String sort = 'recommended',
  }) async {
    final scope = scopeKey();
    final rows = await _widgets(scope);
    final needle = query.trim().toLowerCase();
    final items = <AppletCatalogItem>[];
    for (final row in rows) {
      final rowType = row.spec['experienceType'] == 'game'
          ? AppletCatalogType.game
          : AppletCatalogType.applet;
      final rowCategory = row.spec['category']?.toString() ?? '';
      if ((type != null && type != rowType) ||
          (category != null && category != rowCategory) ||
          (needle.isNotEmpty &&
              !'${row.title} ${row.subtitle ?? ''}'.toLowerCase().contains(
                needle,
              ))) {
        continue;
      }
      final id = idFor(row);
      final feedback = await _engagement(scope, id);
      items.add(
        AppletCatalogItem(
          id: id,
          title: row.title,
          type: rowType,
          summary: row.subtitle ?? '',
          author: const AppletCatalogAuthor(
            agentId: 'local-agent',
            displayName: 'Agent',
            verified: false,
          ),
          // This identifier is handled locally by source(); it is never fetched
          // as a URL or presented as a public hosted link.
          shareUrl: Uri(scheme: 'maaso-local', host: 'applet', path: '/$id'),
          updatedAt: row.createdAt,
          category: rowCategory,
          skillInstructions: row.spec['skillInstructions']?.toString() ?? '',
          viewCount: feedback['viewCount'] as int,
          likeCount: feedback['likeCount'] as int,
          shareCount: feedback['shareCount'] as int,
          commentCount: feedback['commentCount'] as int,
          likedByMe: feedback['likedByMe'] as bool,
        ),
      );
    }
    items.sort(
      (a, b) => sort == 'rating'
          ? b.likeCount.compareTo(a.likeCount)
          : sort == 'hot'
          ? b.viewCount.compareTo(a.viewCount)
          : b.updatedAt.compareTo(a.updatedAt),
    );
    final offset = cursor == null || cursor.isEmpty ? 0 : int.tryParse(cursor);
    if (offset == null || offset < 0 || offset > items.length) {
      throw const FormatException('invalid_applet_cursor');
    }
    final end = (offset + limit.clamp(1, 30)).clamp(0, items.length);
    _requireScope(scope);
    return AppletCatalogPage(
      items: items.sublist(offset, end),
      quota: AppletQuotaSnapshot(used: rows.length, limit: 1000000),
      nextCursor: end < items.length ? '$end' : null,
    );
  }

  static String surfaceIdFor(AgentWidget row) =>
      (row.spec['surfaceId'] ?? row.spec['id'] ?? 'local-${row.id}').toString();

  static String idFor(AgentWidget row) =>
      'local_${sha256.convert(utf8.encode(surfaceIdFor(row))).toString().substring(0, 24)}';

  static bool isLocalUrl(Uri uri) =>
      uri.scheme == 'maaso-local' &&
      uri.host == 'applet' &&
      uri.userInfo.isEmpty &&
      uri.query.isEmpty &&
      uri.fragment.isEmpty &&
      uri.pathSegments.length == 1 &&
      RegExp(r'^local_[a-f0-9]{24}$').hasMatch(uri.pathSegments.single);

  Future<AgentWidget?> findWidget(String id) async {
    final scope = scopeKey();
    final rows = await _widgets(scope);
    return rows.where((row) => idFor(row) == id).firstOrNull;
  }

  Future<Map<String, Object?>> mutateGame(
    Uri uri,
    Map<String, Object?> body, {
    required String expectedScope,
  }) async {
    _requireScope(expectedScope);
    final parts = uri.pathSegments;
    if (parts.length < 3 || parts[1] != 'agent-games') {
      throw StateError('unsupported_local_applet_operation');
    }
    if (parts[2] == 'by-client') {
      if (parts.length < 4) throw const FormatException('invalid_applet_id');
      final clientId = parts[3];
      final id =
          'local_${sha256.convert(utf8.encode(clientId)).toString().substring(0, 24)}';
      if (parts.last == 'delete') {
        await _works.record(_key(expectedScope, id)).delete(database.raw);
        _requireScope(expectedScope);
        return {'deleted': true, 'clientSurfaceId': clientId};
      }
      final surface = Map<String, Object?>.from(body['surface'] as Map);
      final hash = canonicalSourceHash(surface);
      final key = _works.record(_key(expectedScope, id));
      return database.raw.transaction((txn) async {
        _requireScope(expectedScope);
        final previous = await key.get(txn);
        final previousRevision = previous?['revisionNo'] as int? ?? 0;
        final unchanged = previous?['sourceSha256'] == hash;
        final revision = unchanged ? previousRevision : previousRevision + 1;
        final versions = Map<String, Object?>.from(
          previous?['versions'] as Map? ?? const {},
        );
        final record = <String, Object?>{
          ...?previous,
          'gameId': id,
          'id': id,
          'clientSurfaceId': clientId,
          'title': body['title'],
          'experienceType': body['experienceType'],
          'surface': surface,
          'sourceSha256': hash,
          'revisionNo': revision,
          'published': previous?['published'] == true && unchanged,
          'hasPublished':
              previous?['hasPublished'] == true ||
              previous?['published'] == true,
          'updatedAt': _now().toUtc().toIso8601String(),
          'versions': versions,
        };
        versions['$revision'] = {
          'revisionNo': revision,
          'sourceSha256': hash,
          'surface': surface,
          'createdAt': record['updatedAt'],
        };
        _requireScope(expectedScope);
        await key.put(txn, record);
        _requireScope(expectedScope);
        return record;
      });
    }
    final id = parts[2];
    final key = _works.record(_key(expectedScope, id));
    return database.raw.transaction((txn) async {
      _requireScope(expectedScope);
      final previous = await key.get(txn);
      if (previous == null) throw StateError('local_applet_not_found');
      final published = parts.last == 'publish';
      if (!published && parts.last != 'unpublish') {
        throw StateError('unsupported_local_applet_operation');
      }
      final updated = <String, Object?>{
        ...previous,
        'published': published,
        'hasPublished': published,
        'publishedRevisionNo': published ? previous['revisionNo'] : 0,
        'publishedSourceSha256': published ? previous['sourceSha256'] : '',
      };
      _requireScope(expectedScope);
      await key.put(txn, updated);
      _requireScope(expectedScope);
      return updated;
    });
  }

  Future<Map<String, Object?>> readGame(Uri uri, String expectedScope) async {
    _requireScope(expectedScope);
    final parts = uri.pathSegments;
    final id = parts[2];
    final record = await _works
        .record(_key(expectedScope, id))
        .get(database.raw);
    _requireScope(expectedScope);
    if (record == null) throw StateError('local_applet_not_found');
    final versions = Map<String, Object?>.from(
      record['versions'] as Map? ?? const {},
    );
    if (parts.last == 'revisions') {
      final before =
          int.tryParse(uri.queryParameters['beforeRevision'] ?? '') ?? 1000001;
      final limit = (int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50)
          .clamp(1, 100);
      final rows =
          versions.values
              .cast<Map>()
              .where((row) => (row['revisionNo'] as int) < before)
              .toList()
            ..sort(
              (a, b) =>
                  (b['revisionNo'] as int).compareTo(a['revisionNo'] as int),
            );
      final selected = rows.take(limit).toList();
      return {
        'gameId': id,
        'clientSurfaceId': record['clientSurfaceId'],
        'currentRevisionNo': record['revisionNo'],
        'publishedRevisionNo': record['published'] == true
            ? record['publishedRevisionNo']
            : null,
        'items': [
          for (final row in selected)
            {
              'revisionNo': row['revisionNo'],
              'sourceSha256': row['sourceSha256'],
              'createdAt': row['createdAt'],
            },
        ],
        if (rows.length > selected.length)
          'nextBeforeRevision': selected.last['revisionNo'],
      };
    }
    final revision = parts.length >= 6 ? int.tryParse(parts[4]) : null;
    final version = revision == null ? record : versions['$revision'] as Map?;
    if (version == null) throw StateError('local_applet_version_not_found');
    return _document(record, version);
  }

  Future<Map<String, Object?>> source(String id) async {
    final scope = scopeKey();
    final record = await _works.record(_key(scope, id)).get(database.raw);
    _requireScope(scope);
    if (record != null) return _document(record, record);
    // Existing locally generated works predate the local catalog index.
    final rows = await _widgets(scope);
    final row = rows.where((row) => idFor(row) == id).firstOrNull;
    if (row == null) throw StateError('local_applet_not_found');
    final project = SurfaceProject.fromJson({
      ...row.spec,
      'id': surfaceIdFor(row),
      'title': row.title,
      'kind': row.spec['surfaceKind'] ?? row.spec['kind'] ?? 'fullscreen',
    });
    final surface = <String, Object?>{
      'title': project.title,
      'rendering': project.rendering.name,
      'html': project.html,
      'css': project.css,
      'js': project.js,
      'manifest': project.manifest.toJson(),
      if (project.category.isNotEmpty) 'category': project.category,
      if (project.skillInstructions.isNotEmpty)
        'skillInstructions': project.skillInstructions,
    };
    return _document(
      {
        'id': id,
        'clientSurfaceId': surfaceIdFor(row),
        'experienceType': project.experienceType.name,
      },
      {
        'revisionNo': SurfaceVersionHistory.read(
          row.spec,
          title: row.title,
        ).current.number,
        'sourceSha256': canonicalSourceHash(surface),
        'surface': surface,
      },
    );
  }

  Map<String, Object?> _document(Map record, Map version) {
    final surface = Map<String, Object?>.from(version['surface'] as Map);
    final manifest = surface['manifest'];
    return {
      'id': record['id'] ?? record['gameId'],
      'clientSurfaceId': record['clientSurfaceId'],
      'revisionNo': version['revisionNo'],
      'sourceSha256': version['sourceSha256'],
      'experienceType': record['experienceType'],
      'category': surface['category'] ?? '',
      'skillInstructions':
          surface['skillInstructions'] ??
          (manifest is Map ? manifest['instructions'] : null) ??
          '',
      'surface': surface,
      'cloud': const <String, Object?>{},
    };
  }

  Future<Map<String, Object?>> _engagement(String scope, String id) async => {
    'id': id,
    'viewCount': 0,
    'likeCount': 0,
    'shareCount': 0,
    'commentCount': 0,
    'likedByMe': false,
    ...?await _feedback.record(_key(scope, id)).get(database.raw),
  };

  Future<Object?> request(
    String method,
    Uri uri,
    Map<String, Object?>? body,
  ) async {
    final scope = scopeKey();
    final parts = uri.pathSegments;
    if (parts.length < 3) {
      throw StateError('unsupported_local_applet_operation');
    }
    final id = parts[2];
    if (parts.last == 'source') return source(id);
    if (parts.contains('comments')) {
      final key = _comments.record(_key(scope, id));
      return database.raw.transaction((txn) async {
        _requireScope(scope);
        final record = await key.get(txn) ?? const <String, Object?>{};
        final items = (record['items'] as List? ?? const [])
            .cast<Map>()
            .map((e) => Map<String, Object?>.from(e))
            .toList();
        if (method == 'POST') {
          final sequence = (record['sequence'] as int? ?? 0) + 1;
          final comment = <String, Object?>{
            'id': 'agc_${_now().microsecondsSinceEpoch}_$sequence',
            'displayName': 'Test User',
            'text': body!['text'],
            'createdAt': _now().toUtc().toIso8601String(),
            if (body['parentCommentId'] != null)
              'parentCommentId': body['parentCommentId'],
          };
          items.insert(0, comment);
          final retained = items.take(500).toList();
          await key.put(txn, {'items': retained, 'sequence': sequence});
          final feedbackKey = _feedback.record(_key(scope, id));
          final feedback =
              await feedbackKey.get(txn) ?? const <String, Object?>{};
          await feedbackKey.put(txn, {
            ...feedback,
            'commentCount': retained.length,
          });
          _requireScope(scope);
          return comment;
        }
        final offset = int.tryParse(uri.queryParameters['cursor'] ?? '') ?? 0;
        final limit = (int.tryParse(uri.queryParameters['limit'] ?? '') ?? 30)
            .clamp(1, 50);
        if (offset < 0 || offset > items.length) {
          throw const FormatException('invalid_applet_cursor');
        }
        final end = (offset + limit).clamp(0, items.length);
        return {
          'items': items.sublist(offset, end),
          if (end < items.length) 'nextCursor': '$end',
        };
      });
    }
    return database.raw.transaction((txn) async {
      _requireScope(scope);
      final key = _feedback.record(_key(scope, id));
      final previous = await key.get(txn);
      final data = <String, Object?>{
        'id': id,
        'viewCount': 0,
        'likeCount': 0,
        'shareCount': 0,
        'commentCount': 0,
        'likedByMe': false,
        ...?previous,
      };
      if (method == 'POST') {
        if (parts.contains('likes')) {
          data['likedByMe'] = body?['liked'] == true;
          data['likeCount'] = body?['liked'] == true ? 1 : 0;
        } else if (parts.last == 'views' || parts.last == 'shares') {
          final event = body?['eventId']?.toString() ?? '';
          final events = (previous?['events'] as List? ?? const [])
              .cast<String>()
              .toSet();
          if (event.isNotEmpty && events.add('${parts.last}:$event')) {
            final counter = parts.last == 'views' ? 'viewCount' : 'shareCount';
            data[counter] = (data[counter] as int) + 1;
          }
          data['events'] = events.toList().reversed.take(500).toList();
        } else {
          throw StateError('unsupported_local_applet_operation');
        }
        _requireScope(scope);
        await key.put(txn, data);
        _requireScope(scope);
      }
      return Map<String, Object?>.from(data)..remove('events');
    });
  }

  static String canonicalSourceHash(Map<String, Object?> value) => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            _canonical(value),
          ).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029'),
        ),
      )
      .toString();

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
