import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/agent/application/surface/surface_agent_document.dart';

enum AppletCatalogType {
  applet('applet'),
  game('game');

  const AppletCatalogType(this.wireValue);

  final String wireValue;

  static AppletCatalogType fromWire(Object? raw) {
    final value = raw is String ? raw.trim() : '';
    for (final type in values) {
      if (type.wireValue == value) return type;
    }
    throw const FormatException('invalid_applet_type');
  }
}

bool isTrustedAppletShareUrl(Uri candidate, {required Uri trustedOrigin}) {
  return candidate.scheme == 'https' &&
      candidate.userInfo.isEmpty &&
      candidate.fragment.isEmpty &&
      candidate.query.isEmpty &&
      candidate.origin == trustedOrigin.origin &&
      candidate.pathSegments.length == 2 &&
      candidate.pathSegments.first == 'g' &&
      candidate.pathSegments.last.trim().isNotEmpty;
}

class AppletCatalogAuthor {
  const AppletCatalogAuthor({
    required this.agentId,
    required this.displayName,
    required this.verified,
  });

  final String agentId;
  final String displayName;
  final bool verified;

  factory AppletCatalogAuthor.fromJson(Object? raw) {
    final json = _exactMap(raw, const {'agentId', 'displayName', 'verified'});
    final verified = json['verified'];
    if (verified is! bool || verified) {
      throw const FormatException('invalid_applet_author_verification');
    }
    final agentId = _boundedString(json['agentId'], 1, 96);
    if (json['displayName'] is! String ||
        IdentityNames.validate(json['displayName'] as String) != null) {
      throw const FormatException('invalid_applet_author_identity');
    }
    final displayName = IdentityNames.require(json['displayName'] as String);
    if (!_publicAppletAuthorPattern.hasMatch(agentId) ||
        IdentityNames.validate(displayName) != null) {
      throw const FormatException('invalid_applet_author_identity');
    }
    return AppletCatalogAuthor(
      agentId: agentId,
      displayName: displayName,
      verified: verified,
    );
  }
}

class AppletCatalogItem {
  const AppletCatalogItem({
    required this.id,
    required this.title,
    required this.type,
    required this.summary,
    required this.author,
    required this.shareUrl,
    required this.updatedAt,
    this.category = '',
    this.skillInstructions = '',
    this.viewCount = 0,
    this.likeCount = 0,
    this.shareCount = 0,
    this.commentCount = 0,
    this.likedByMe = false,
  });

  final String id;
  final String title;
  final AppletCatalogType type;
  final String summary;
  final AppletCatalogAuthor author;
  final Uri shareUrl;
  final DateTime updatedAt;
  final String category;
  final String skillInstructions;
  int get ratingScore => likeCount;

  final int viewCount;
  final int likeCount;
  final int shareCount;
  final int commentCount;
  final bool likedByMe;

  AppletCatalogItem copyWith({
    int? viewCount,
    int? likeCount,
    int? shareCount,
    int? commentCount,
    bool? likedByMe,
  }) => AppletCatalogItem(
    id: id,
    title: title,
    type: type,
    summary: summary,
    author: author,
    shareUrl: shareUrl,
    updatedAt: updatedAt,
    category: category,
    skillInstructions: skillInstructions,
    viewCount: viewCount ?? this.viewCount,
    likeCount: likeCount ?? this.likeCount,
    shareCount: shareCount ?? this.shareCount,
    commentCount: commentCount ?? this.commentCount,
    likedByMe: likedByMe ?? this.likedByMe,
  );

  factory AppletCatalogItem.fromJson(
    Object? raw, {
    required Uri trustedOrigin,
  }) {
    final json = _exactMap(
      raw,
      const {
        'id',
        'title',
        'type',
        'summary',
        'author',
        'shareUrl',
        'updatedAt',
        'category',
        'skillInstructions',
        'ratingScore',
        'viewCount',
        'likeCount',
        'shareCount',
        'commentCount',
        'likedByMe',
      },
      optional: const {
        'category',
        'skillInstructions',
        'ratingScore',
        'viewCount',
        'likeCount',
        'shareCount',
        'commentCount',
        'likedByMe',
      },
    );
    final shareUrl = Uri.tryParse(_boundedString(json['shareUrl'], 1, 2048));
    if (shareUrl == null ||
        !isTrustedAppletShareUrl(shareUrl, trustedOrigin: trustedOrigin)) {
      throw const FormatException('invalid_applet_share_url');
    }
    final updatedAt = DateTime.tryParse(
      _boundedString(json['updatedAt'], 1, 64),
    )?.toUtc();
    if (updatedAt == null) {
      throw const FormatException('invalid_applet_updated_at');
    }
    final id = _boundedString(json['id'], 1, 40);
    if (!_appletIdentifierPattern.hasMatch(id)) {
      throw const FormatException('invalid_applet_catalog_id');
    }
    return AppletCatalogItem(
      id: id,
      title: _boundedString(json['title'], 1, 160),
      type: AppletCatalogType.fromWire(json['type']),
      summary: _boundedString(json['summary'], 0, 300),
      author: AppletCatalogAuthor.fromJson(json['author']),
      shareUrl: shareUrl,
      updatedAt: updatedAt,
      category: _appletCategory(json['category']),
      skillInstructions: _appletSkillInstructions(json['skillInstructions']),
      viewCount: _optionalBoundedInt(json['viewCount'], min: 0, max: 1 << 31),
      likeCount: _optionalBoundedInt(json['likeCount'], min: 0, max: 1 << 31),
      shareCount: _optionalBoundedInt(json['shareCount'], min: 0, max: 1 << 31),
      commentCount: _optionalBoundedInt(
        json['commentCount'],
        min: 0,
        max: 1 << 31,
      ),
      likedByMe: _optionalBool(json['likedByMe']),
    );
  }
}

class AppletEngagementSnapshot {
  const AppletEngagementSnapshot({
    required this.id,
    required this.viewCount,
    required this.likeCount,
    required this.shareCount,
    required this.commentCount,
    required this.likedByMe,
  });

  final String id;
  final int viewCount;
  final int likeCount;
  final int shareCount;
  final int commentCount;
  final bool likedByMe;

  factory AppletEngagementSnapshot.fromJson(Object? raw) {
    final json = _exactMap(raw, const {
      'id',
      'viewCount',
      'likeCount',
      'shareCount',
      'commentCount',
      'likedByMe',
    });
    final id = _boundedString(json['id'], 1, 40);
    if (!_appletIdentifierPattern.hasMatch(id)) {
      throw const FormatException('invalid_applet_catalog_id');
    }
    return AppletEngagementSnapshot(
      id: id,
      viewCount: _boundedInt(json['viewCount'], min: 0, max: 1 << 31),
      likeCount: _boundedInt(json['likeCount'], min: 0, max: 1 << 31),
      shareCount: _boundedInt(json['shareCount'], min: 0, max: 1 << 31),
      commentCount: _boundedInt(json['commentCount'], min: 0, max: 1 << 31),
      likedByMe: _requiredBool(json['likedByMe']),
    );
  }
}

class AppletComment {
  const AppletComment({
    required this.id,
    required this.displayName,
    required this.text,
    required this.createdAt,
    this.actorId,
    this.actorKind = IdentityActorKind.player,
    this.parentCommentId,
  });

  final String id;
  final String displayName;
  final String text;
  final DateTime createdAt;
  final String? actorId;
  final IdentityActorKind actorKind;
  final String? parentCommentId;

  factory AppletComment.fromJson(Object? raw) {
    final json = _exactMap(
      raw,
      const {
        'id',
        'displayName',
        'text',
        'createdAt',
        'actorId',
        'actorKind',
        'parentCommentId',
      },
      optional: const {'actorId', 'actorKind', 'parentCommentId'},
    );
    final actorId = json['actorId'];
    final actorKind = json['actorKind'];
    final parentCommentId = json['parentCommentId'];
    if (json.containsKey('parentCommentId') &&
        (parentCommentId is! String ||
            !RegExp(
              r'^agc_[A-Za-z0-9._:-]{1,36}$',
            ).hasMatch(parentCommentId))) {
      throw const FormatException('invalid_applet_reply_target');
    }
    if (json.containsKey('actorId') != json.containsKey('actorKind') ||
        (json.containsKey('actorId') &&
            (actorId is! String ||
                !RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(actorId) ||
                (actorKind != 'user' && actorKind != 'agent')))) {
      throw const FormatException('invalid_applet_comment_actor');
    }
    final rawName = json['displayName'];
    final displayName = actorId == null
        ? _boundedString(rawName, 1, 120)
        : rawName is String
        ? IdentityNames.require(rawName)
        : throw const FormatException('invalid_applet_comment_name');
    final createdAt = DateTime.tryParse(
      _boundedString(json['createdAt'], 1, 64),
    )?.toUtc();
    if (createdAt == null) {
      throw const FormatException('invalid_applet_comment_created_at');
    }
    return AppletComment(
      id: _boundedString(json['id'], 1, 40),
      displayName: displayName,
      text: _boundedString(json['text'], 1, 180),
      createdAt: createdAt,
      actorId: actorId as String?,
      parentCommentId: json.containsKey('parentCommentId')
          ? _boundedString(json['parentCommentId'], 1, 40)
          : null,
      actorKind: actorKind == 'agent'
          ? IdentityActorKind.agent
          : IdentityActorKind.player,
    );
  }
}

class AppletCommentPage {
  const AppletCommentPage({required this.items, this.nextCursor});

  final List<AppletComment> items;
  final String? nextCursor;

  factory AppletCommentPage.fromJson(Object? raw) {
    final json = _exactMap(
      raw,
      const {'items', 'nextCursor'},
      optional: const {'nextCursor'},
    );
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 50) {
      throw const FormatException('invalid_applet_comments');
    }
    final cursor = json['nextCursor'];
    if (cursor != null && (cursor is! String || cursor.length > 512)) {
      throw const FormatException('invalid_applet_cursor');
    }
    final normalizedCursor = cursor is String ? cursor.trim() : '';
    return AppletCommentPage(
      items: rawItems.map(AppletComment.fromJson).toList(growable: false),
      nextCursor: normalizedCursor.isEmpty ? null : normalizedCursor,
    );
  }
}

class AppletQuotaSnapshot {
  const AppletQuotaSnapshot({required this.used, required this.limit});

  final int used;
  final int limit;

  int get remaining => limit - used;
  bool get isFull => remaining <= 0;

  factory AppletQuotaSnapshot.fromJson(Object? raw) {
    final json = _exactMap(raw, const {'used', 'limit'});
    final used = _boundedInt(json['used'], min: 0, max: 5);
    final limit = _boundedInt(json['limit'], min: 5, max: 5);
    if (used > limit) throw const FormatException('invalid_applet_quota');
    return AppletQuotaSnapshot(used: used, limit: limit);
  }
}

class AppletInventoryItem {
  const AppletInventoryItem({
    required this.id,
    required this.clientSurfaceId,
    required this.title,
    required this.type,
    required this.summary,
    required this.published,
    required this.updatedAt,
    this.shareUrl,
    this.category = '',
    this.skillInstructions = '',
    this.viewCount = 0,
    this.likeCount = 0,
    this.shareCount = 0,
    this.commentCount = 0,
  });

  final String id;
  final String clientSurfaceId;
  final String title;
  final AppletCatalogType type;
  final String summary;
  final bool published;
  final Uri? shareUrl;
  final DateTime updatedAt;
  final String category;
  final String skillInstructions;
  int get ratingScore => likeCount;

  final int viewCount;
  final int likeCount;
  final int shareCount;
  final int commentCount;

  factory AppletInventoryItem.fromJson(
    Object? raw, {
    required Uri trustedOrigin,
  }) {
    final json = _exactMap(
      raw,
      const {
        'id',
        'clientSurfaceId',
        'title',
        'type',
        'summary',
        'published',
        'shareUrl',
        'updatedAt',
        'category',
        'skillInstructions',
        'ratingScore',
        'viewCount',
        'likeCount',
        'shareCount',
        'commentCount',
      },
      optional: const {
        'category',
        'skillInstructions',
        'ratingScore',
        'viewCount',
        'likeCount',
        'shareCount',
        'commentCount',
      },
    );
    final id = _boundedString(json['id'], 1, 40);
    final clientSurfaceId = _boundedString(json['clientSurfaceId'], 1, 160);
    if (!_appletIdentifierPattern.hasMatch(id) ||
        !_appletIdentifierPattern.hasMatch(clientSurfaceId)) {
      throw const FormatException('invalid_applet_inventory_id');
    }
    final published = json['published'];
    if (published is! bool) {
      throw const FormatException('invalid_applet_inventory_publication');
    }
    final rawShareUrl = _boundedString(json['shareUrl'], 0, 2048);
    Uri? shareUrl;
    if (rawShareUrl.isNotEmpty) {
      final parsed = Uri.tryParse(rawShareUrl);
      if (!published ||
          parsed == null ||
          !isTrustedAppletShareUrl(parsed, trustedOrigin: trustedOrigin)) {
        throw const FormatException('invalid_applet_share_url');
      }
      shareUrl = parsed;
    }
    final updatedAt = DateTime.tryParse(
      _boundedString(json['updatedAt'], 1, 64),
    )?.toUtc();
    if (updatedAt == null) {
      throw const FormatException('invalid_applet_updated_at');
    }
    return AppletInventoryItem(
      id: id,
      clientSurfaceId: clientSurfaceId,
      title: _boundedString(json['title'], 1, 160),
      type: AppletCatalogType.fromWire(json['type']),
      summary: _boundedString(json['summary'], 0, 300),
      published: published,
      shareUrl: shareUrl,
      updatedAt: updatedAt,
      category: _appletCategory(json['category']),
      skillInstructions: _appletSkillInstructions(json['skillInstructions']),
      viewCount: _optionalBoundedInt(json['viewCount'], min: 0, max: 1 << 31),
      likeCount: _optionalBoundedInt(json['likeCount'], min: 0, max: 1 << 31),
      shareCount: _optionalBoundedInt(json['shareCount'], min: 0, max: 1 << 31),
      commentCount: _optionalBoundedInt(
        json['commentCount'],
        min: 0,
        max: 1 << 31,
      ),
    );
  }
}

class AppletInventoryPage {
  const AppletInventoryPage({required this.items, required this.quota});

  final List<AppletInventoryItem> items;
  final AppletQuotaSnapshot quota;

  factory AppletInventoryPage.fromJson(
    Object? raw, {
    required Uri trustedOrigin,
  }) {
    final json = _exactMap(raw, const {'schemaVersion', 'items', 'quota'});
    if (_boundedInt(json['schemaVersion'], min: 1, max: 1) != 1) {
      throw const FormatException('unsupported_applet_schema');
    }
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 5) {
      throw const FormatException('invalid_applet_inventory');
    }
    final items = rawItems
        .map(
          (item) =>
              AppletInventoryItem.fromJson(item, trustedOrigin: trustedOrigin),
        )
        .toList(growable: false);
    if (items.map((item) => item.id).toSet().length != items.length ||
        items.map((item) => item.clientSurfaceId).toSet().length !=
            items.length) {
      throw const FormatException('duplicate_applet_inventory');
    }
    final quota = AppletQuotaSnapshot.fromJson(json['quota']);
    if (quota.used != items.length) {
      throw const FormatException('inconsistent_applet_inventory');
    }
    return AppletInventoryPage(items: items, quota: quota);
  }
}

class AppletCatalogPage {
  const AppletCatalogPage({
    required this.items,
    required this.quota,
    this.nextCursor,
  });

  final List<AppletCatalogItem> items;
  final AppletQuotaSnapshot quota;
  final String? nextCursor;

  factory AppletCatalogPage.fromJson(
    Object? raw, {
    required Uri trustedOrigin,
  }) {
    final json = _exactMap(
      raw,
      const {'schemaVersion', 'items', 'quota', 'nextCursor'},
      optional: const {'nextCursor'},
    );
    if (_boundedInt(json['schemaVersion'], min: 1, max: 1) != 1) {
      throw const FormatException('unsupported_applet_schema');
    }
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.length > 30) {
      throw const FormatException('invalid_applet_items');
    }
    final items = rawItems
        .map(
          (item) =>
              AppletCatalogItem.fromJson(item, trustedOrigin: trustedOrigin),
        )
        .toList(growable: false);
    if (items.map((item) => item.id).toSet().length != items.length) {
      throw const FormatException('duplicate_applet_items');
    }
    final cursor = json['nextCursor'];
    if (cursor != null && (cursor is! String || cursor.length > 512)) {
      throw const FormatException('invalid_applet_cursor');
    }
    final normalizedCursor = cursor is String ? cursor.trim() : '';
    return AppletCatalogPage(
      items: items,
      quota: AppletQuotaSnapshot.fromJson(json['quota']),
      nextCursor: normalizedCursor.isEmpty ? null : normalizedCursor,
    );
  }
}

Map<String, Object?> _exactMap(
  Object? raw,
  Set<String> allowed, {
  Set<String> optional = const {},
}) {
  if (raw is! Map) throw const FormatException('expected_applet_object');
  final json = raw.map((key, value) => MapEntry(key.toString(), value));
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('unexpected_applet_field');
  }
  final required = allowed.difference(optional);
  if (required.any((key) => !json.containsKey(key))) {
    throw const FormatException('missing_applet_field');
  }
  return json;
}

String _boundedString(Object? raw, int min, int max) {
  if (raw is! String) throw const FormatException('invalid_applet_string');
  final value = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  final length = value.runes.length;
  if (length < min || length > max) {
    throw const FormatException('invalid_applet_string');
  }
  return value;
}

int _boundedInt(Object? raw, {required int min, required int max}) {
  if (raw is! int || raw < min || raw > max) {
    throw const FormatException('invalid_applet_integer');
  }
  return raw;
}

int _optionalBoundedInt(Object? raw, {required int min, required int max}) =>
    raw == null ? min : _boundedInt(raw, min: min, max: max);

bool _optionalBool(Object? raw) => raw == null ? false : _requiredBool(raw);

bool _requiredBool(Object? raw) {
  if (raw is! bool) throw const FormatException('invalid_applet_boolean');
  return raw;
}

final RegExp _appletIdentifierPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$',
);
final RegExp _publicAppletAuthorPattern = RegExp(r'^aa_[a-f0-9]{32}$');

String _appletCategory(Object? raw) {
  if (raw == null || raw == '') return '';
  if (raw != 'game' && raw != 'travel' && raw != 'tools') {
    throw const FormatException('invalid_applet_category');
  }
  return raw as String;
}

String _appletSkillInstructions(Object? raw) {
  return readSurfaceAgentDocument(
    raw,
    errorCode: 'invalid_applet_skill_instructions',
  );
}

/// Immutable, authenticated revision data. Instructions remain untrusted content.
class AppletSourceDocument {
  const AppletSourceDocument({
    required this.id,
    required this.clientSurfaceId,
    required this.revisionNo,
    required this.sourceSha256,
    required this.experienceType,
    required this.category,
    required this.skillInstructions,
    required this.surface,
    this.cloud = const {},
  });

  final String id;
  final String clientSurfaceId;
  final int revisionNo;
  final String sourceSha256;
  final String experienceType;
  final String category;
  final String skillInstructions;
  final Map<String, Object?> surface;
  final Map<String, Object?> cloud;

  factory AppletSourceDocument.fromJson(Object? raw) {
    final json = _exactMap(
      raw,
      const {
        'id',
        'clientSurfaceId',
        'revisionNo',
        'sourceSha256',
        'experienceType',
        'category',
        'skillInstructions',
        'surface',
        'cloud',
      },
      optional: const {'cloud'},
    );
    final id = _boundedString(json['id'], 1, 40);
    final clientId = _boundedString(json['clientSurfaceId'], 1, 160);
    final hash = _boundedString(json['sourceSha256'], 64, 64);
    final experienceType = json['experienceType'];
    if (!_appletIdentifierPattern.hasMatch(id) ||
        !_appletIdentifierPattern.hasMatch(clientId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        (experienceType != 'game' && experienceType != 'utility')) {
      throw const FormatException('invalid_applet_source');
    }
    final surface = _exactMap(
      json['surface'],
      const {
        'title',
        'rendering',
        'html',
        'css',
        'js',
        'manifest',
        'category',
        'skillInstructions',
      },
      optional: const {'category', 'skillInstructions'},
    );
    final canonical = jsonEncode(
      _canonicalAppletValue(surface),
    ).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');
    final canonicalBytes = utf8.encode(canonical);
    final webApp = surface['rendering'] == 'webApp';
    final sourceFields = [surface['html'], surface['css'], surface['js']];
    final validWebSource =
        sourceFields.every((value) => value is String) &&
        sourceFields.cast<String>().fold<int>(
              0,
              (sum, value) => sum + utf8.encode(value).length,
            ) <=
            SurfaceProjectValidator.maximumPublicSourceBytes;
    final canonicalLimit = webApp
        ? 6 * SurfaceProjectValidator.maximumPublicSourceBytes + 96 * 1024
        : 2 * 1024 * 1024;
    if ((webApp && !validWebSource) ||
        canonicalBytes.length > canonicalLimit ||
        sha256.convert(canonicalBytes).toString() != hash) {
      throw const FormatException('invalid_applet_source_digest');
    }
    final category = _appletCategory(json['category']);
    final instructions = _appletSkillInstructions(json['skillInstructions']);
    final sourceCategory = _appletCategory(surface['category']);
    final manifest = surface['manifest'];
    final declaredInstructions = _appletSkillInstructions(
      surface['skillInstructions'],
    );
    final effectiveInstructions = declaredInstructions.isNotEmpty
        ? declaredInstructions
        : _appletSkillInstructions(
            manifest is Map ? manifest['instructions'] : null,
          );
    if ((sourceCategory.isNotEmpty && category != sourceCategory) ||
        instructions != effectiveInstructions) {
      throw const FormatException('invalid_applet_source_metadata');
    }
    return AppletSourceDocument(
      id: id,
      clientSurfaceId: clientId,
      revisionNo: _boundedInt(json['revisionNo'], min: 1, max: 1000),
      sourceSha256: hash,
      experienceType: experienceType as String,
      category: category,
      skillInstructions: instructions,
      surface: _canonicalAppletValue(surface) as Map<String, Object?>,
      cloud: json['cloud'] is Map
          ? Map<String, Object?>.unmodifiable(
              (json['cloud'] as Map).cast<String, Object?>(),
            )
          : const {},
    );
  }

  Map<String, Object?> toProjectJson({String? instanceId}) => {
    ...surface,
    'id': instanceId ?? clientSurfaceId,
    'kind': 'fullscreen',
    'surfaceKind': 'fullscreen',
    'surfaceId': instanceId ?? clientSurfaceId,
    'experienceType': experienceType,
    'category': category,
    'skillInstructions': skillInstructions,
  };
}

Object? _canonicalAppletValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return Map<String, Object?>.unmodifiable({
      for (final key in keys) key: _canonicalAppletValue(value[key]),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_canonicalAppletValue));
  }
  return value;
}
