import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

final class StoreAsset {
  StoreAsset._(this.json);
  final Map<String, Object?> json;
  String get id => json['id'] as String;
  String get type => json['type'] as String;
  String get versionId => json['versionId'] as String;
  String get title => json['title'] as String;
  String get summary => json['summary'] as String;
  String get coverUrl => json['coverUrl'] as String;
  Map<String, Object?> get preview =>
      (json['preview'] as Map).cast<String, Object?>();
  Map<String, Object?> get popularity =>
      (json['popularity'] as Map).cast<String, Object?>();
  Map<String, Object?> get ownership =>
      (json['ownership'] as Map).cast<String, Object?>();
  Map<String, Object?> get sourceRef =>
      (json['sourceRef'] as Map).cast<String, Object?>();
  Map<String, Object?>? get author =>
      (json['author'] as Map?)?.cast<String, Object?>();
  List<String> get examples => (json['examples'] as List).cast<String>();
  String get key => '$type:$id:$versionId';

  factory StoreAsset.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('asset_store_invalid');
    }
    final json = Map<String, Object?>.from(raw);
    final type = json['type'];
    final id = json['id'];
    final version = json['versionId'];
    if (!const {'skill', 'model'}.contains(type) ||
        id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$').hasMatch(id) ||
        version is! String ||
        version.isEmpty ||
        version.length > 128 ||
        json['listed'] is! bool ||
        json['title'] is! String ||
        (json['title'] as String).runes.length > 160 ||
        json['summary'] is! String ||
        (json['summary'] as String).runes.length > 1024 ||
        json['coverUrl'] is! String ||
        (json['coverUrl'] as String).length > 1024 ||
        json['preview'] is! Map ||
        json['popularity'] is! Map ||
        json['ownership'] is! Map ||
        json['sourceRef'] is! Map ||
        json['examples'] is! List) {
      throw const FormatException('asset_store_invalid');
    }
    final popularity = json['popularity'] as Map;
    final expectedMetric = type == 'skill'
        ? 'active_installations'
        : 'current_selections';
    if (popularity['metric'] != expectedMetric ||
        popularity['value'] is! int ||
        (popularity['value'] as int) < 0 ||
        (popularity['value'] as int) > 9000000000000000) {
      throw const FormatException('asset_store_invalid_metric');
    }
    final preview = json['preview'] as Map;
    if (!const {'available', 'unavailable'}.contains(preview['state'])) {
      throw const FormatException('asset_store_invalid_preview');
    }
    if (preview['state'] == 'available') {
      if (preview['source'] != null ||
          preview['assetPath'] != null ||
          preview['packVersion'] != null ||
          !const {'gif', 'video'}.contains(preview['kind']) ||
          !_https(preview['url']) ||
          preview['sha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(preview['sha256'] as String)) {
        throw const FormatException('asset_store_invalid_preview');
      }
    }
    if ((json['examples'] as List).length > 8 ||
        (json['examples'] as List).any(
          (value) => value is! String || value.runes.length > 500,
        )) {
      throw const FormatException('asset_store_invalid');
    }
    final source = json['sourceRef'] as Map;
    if (type == 'model' &&
        (source['modelId'] is! int ||
            '${source['modelId']}' != id ||
            source['expectedAssetVersionDigest'] != version ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(version))) {
      throw const FormatException('asset_store_invalid_model');
    }
    if (type == 'skill' &&
        (source['skillVersionId'] is! int ||
            '${source['skillVersionId']}' != version)) {
      throw const FormatException('asset_store_invalid_skill');
    }
    return StoreAsset._(_freeze(json, 0) as Map<String, Object?>);
  }
}

final class StoreAssetPage {
  const StoreAssetPage(this.items, this.nextCursor);
  final List<StoreAsset> items;
  final String? nextCursor;
  factory StoreAssetPage.fromJson(Object? raw) {
    if (raw is! Map ||
        raw['schemaVersion'] != 1 ||
        raw['items'] is! List ||
        (raw['items'] as List).length > 50 ||
        (raw['nextCursor'] != null &&
            (raw['nextCursor'] is! String ||
                (raw['nextCursor'] as String).length > 512))) {
      throw const FormatException('asset_store_invalid_page');
    }
    return StoreAssetPage(
      List.unmodifiable(
        (raw['items'] as List)
            // A stale catalog may still return retired action products. Ignore
            // only that known type; keep validating all remaining records.
            .where((item) => item is! Map || item['type'] != 'motion')
            .map(StoreAsset.fromJson),
      ),
      raw['nextCursor'] as String?,
    );
  }
}

final class AssetStoreException implements Exception {
  const AssetStoreException(this.code, {this.statusCode});
  final String code;
  final int? statusCode;
  bool get isUnsupported => statusCode == 404;
  bool get isConflict => statusCode == 409;
  @override
  String toString() => code;
}

/// Page-lazy reader for the source-owned store. Current account/environment is
/// checked after every await; it does not own skill/avatar execution.
class AssetStoreService {
  AssetStoreService({
    http.Client? client,
    Uri Function()? baseUri,
    Future<String> Function()? token,
    String Function()? scope,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _baseUri =
           baseUri ?? (() => appServices.find<AppEnvironmentService>().baseUri),
       _token = token ?? _accessToken,
       _scope = scope ?? currentScope;
  final http.Client _client;
  final bool _ownsClient;
  final Uri Function() _baseUri;
  final Future<String> Function() _token;
  final String Function() _scope;
  String get scopeKey => _scope();
  static bool get available =>
      appServices.isRegistered<AppEnvironmentService>() &&
      appServices.isRegistered<AuthSessionService>();
  static String currentScope() {
    final origin =
        appServices.maybeFind<AppEnvironmentService>()?.baseUri.origin ?? '';
    final account =
        appServices
            .maybeFind<AuthSessionService>()
            ?.session
            .value
            ?.accountUuid ??
        '';
    final generation =
        appServices
            .maybeFind<AccountStorageScopeService>()
            ?.activeMount
            ?.generation ??
        0;
    return '$origin|$account|$generation';
  }

  static Future<String> _accessToken() async {
    final auth = appServices.find<AuthSessionService>();
    if (auth.session.value?.isValid != true && !await auth.restoreOrRefresh()) {
      throw const AssetStoreException('asset_store_auth_required');
    }
    final token = auth.session.value?.accessToken ?? '';
    if (token.isEmpty) {
      throw const AssetStoreException('asset_store_auth_required');
    }
    return token;
  }

  Future<StoreAssetPage> list({
    required String type,
    String query = '',
    String sort = 'popular',
    String locale = 'en',
    String platform = '',
    String? cursor,
    bool workshop = false,
  }) async {
    if (!const {'model', 'skill'}.contains(type)) {
      throw const AssetStoreException('asset_store_invalid_type');
    }
    final json = await _request(
      workshop ? 'workshop' : 'assets',
      query: {
        'type': type,
        'query': query,
        'sort': sort,
        'locale': locale,
        'builtinCatalogVersion': '$avatarBuiltinCatalogVersion',
        'limit': '30',
        if (platform.isNotEmpty) 'platform': platform,
        'cursor': ?cursor,
      },
    );
    final page = StoreAssetPage.fromJson(json);
    if (page.items.any((item) => item.type != type)) {
      throw const FormatException('asset_store_wrong_type');
    }
    return page;
  }

  Future<StoreAsset> detail(
    StoreAsset item, {
    String locale = 'en',
    String platform = '',
  }) async {
    final json = await _request(
      'assets/${Uri.encodeComponent(item.type)}/${Uri.encodeComponent(item.id)}',
      query: {
        'versionId': item.versionId,
        'locale': locale,
        'builtinCatalogVersion': '$avatarBuiltinCatalogVersion',
        if (platform.isNotEmpty) 'platform': platform,
      },
    );
    final result = StoreAsset.fromJson(json);
    if (result.key != item.key) {
      throw const AssetStoreException(
        'asset_store_version_changed',
        statusCode: 409,
      );
    }
    return result;
  }

  Future<void> recordPreview(StoreAsset item, String eventId) async {
    await _request(
      'assets/${Uri.encodeComponent(item.type)}/${Uri.encodeComponent(item.id)}/previews',
      body: {
        'versionId': item.versionId,
        'eventId': eventId,
        'completed': true,
      },
    );
  }

  Future<Object?> _request(
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final scope = scopeKey;
    final uri = _baseUri()
        .resolve('v1/asset-store/$path')
        .replace(queryParameters: query);
    final token = await _token();
    if (scope != scopeKey) {
      throw const AssetStoreException('asset_store_scope_changed');
    }
    final response =
        await (body == null
                ? _client.get(uri, headers: {'Authorization': 'Bearer $token'})
                : _client.post(
                    uri,
                    headers: {
                      'Authorization': 'Bearer $token',
                      'Content-Type': 'application/json',
                    },
                    body: jsonEncode(body),
                  ))
            .timeout(const Duration(seconds: 15));
    if (scope != scopeKey) {
      throw const AssetStoreException('asset_store_scope_changed');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AssetStoreException(
        response.statusCode == 409
            ? 'asset_store_version_changed'
            : 'asset_store_unavailable',
        statusCode: response.statusCode,
      );
    }
    if (response.bodyBytes.length > 4 * 1024 * 1024) {
      throw const FormatException('asset_store_response_too_large');
    }
    final envelope = jsonDecode(response.body);
    if (envelope is! Map || envelope['code'] != 'OK') {
      throw const FormatException('asset_store_invalid_response');
    }
    return envelope['data'];
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

bool _https(Object? value) {
  if (value is! String || value.length > 1024) {
    return false;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

Object? _freeze(Object? value, int depth) {
  if (depth > 16) {
    throw const FormatException('asset_store_value_too_deep');
  }
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map(
        (key, value) => MapEntry(key as String, _freeze(value, depth + 1)),
      ),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((value) => _freeze(value, depth + 1)),
    );
  }
  return value;
}
