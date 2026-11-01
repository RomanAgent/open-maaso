import 'dart:async';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/server_request_failure_log.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';

enum AppletCatalogSort {
  recommended('recommended'),
  hot('hot'),
  rating('rating');

  const AppletCatalogSort(this.wireValue);

  final String wireValue;
}

abstract interface class AppletCatalogGateway {
  String get requestContextKey;

  Future<AppletCatalogPage> search({
    required String query,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  });

  Future<AppletCatalogPage> browse({
    required AppletCatalogType type,
    AppletCatalogSort sort = AppletCatalogSort.recommended,
    String? cursor,
    int limit = 12,
  });

  Future<AppletEngagementSnapshot> setLiked(
    String appletId,
    bool liked, {
    required String expectedContextKey,
  });

  Future<AppletCommentPage> listComments(
    String appletId, {
    String? cursor,
    int limit = 30,
    required String expectedContextKey,
  });

  Future<AppletComment> postComment(
    String appletId,
    String text, {
    required String expectedContextKey,
  });

  Future<AppletEngagementSnapshot> recordView(
    String appletId, {
    required String eventId,
    required String expectedContextKey,
  });

  Future<AppletEngagementSnapshot> recordShare(
    String appletId, {
    required String eventId,
    required String expectedContextKey,
  });
}

abstract interface class AppletDiscoveryGateway {
  Future<AppletCatalogPage> searchRanked({
    required String query,
    String? category,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  });

  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  });
}

class AppletCatalogRequestException extends StateError {
  AppletCatalogRequestException(
    this.statusCode,
    this.code, {
    this.routeMissing = false,
  }) : super(code.isEmpty ? 'applet_catalog_request_failed' : code);

  final int statusCode;
  final String code;
  final bool routeMissing;
}

final class AppletInventoryUnavailableException implements Exception {
  const AppletInventoryUnavailableException();

  @override
  String toString() => 'applet_inventory_unavailable';
}

class AppletCatalogService extends AppService
    implements AppletCatalogGateway, AppletDiscoveryGateway {
  AppletCatalogService({
    http.Client? httpClient,
    AppEnvironmentService? environment,
    AuthSessionService? auth,
    LocaleConfigService? locale,
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _environment = environment ?? appServices.find<AppEnvironmentService>(),
       _auth = auth ?? appServices.find<AuthSessionService>(),
       _locale = locale ?? appServices.find<LocaleConfigService>();

  final http.Client _http;
  final bool _ownsClient;
  final AppEnvironmentService _environment;
  final AuthSessionService _auth;
  final LocaleConfigService _locale;
  String? _missingMineContextKey;
  String? _successfulMineContextKey;
  String? _mineInFlightContextKey;
  Future<AppletInventoryPage>? _mineInFlight;

  final Rxn<AppletCatalogPage> latestPage = Rxn<AppletCatalogPage>();
  final RxString latestQuery = ''.obs;
  final Rxn<AppletCatalogType> latestType = Rxn<AppletCatalogType>();
  final RxString latestContextKey = ''.obs;

  @override
  String get requestContextKey {
    final account = _auth.session.value?.accountUuid.trim() ?? '';
    return '${_environment.environment.value.key}|$account|$_localeTag';
  }

  @override
  Future<AppletCatalogPage> search({
    required String query,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  }) async {
    final normalizedQuery = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalizedQuery.isEmpty || normalizedQuery.runes.length > 80) {
      throw const FormatException('invalid_applet_query');
    }
    final normalizedCursor = cursor?.trim() ?? '';
    if (normalizedCursor.length > 512) {
      throw const FormatException('invalid_applet_cursor');
    }
    final expectedContext = requestContextKey;
    final uri = _environment.baseUri
        .resolve('v1/applets')
        .replace(
          queryParameters: <String, String>{
            'query': normalizedQuery,
            'include_skill': 'true',
            'limit': '${limit.clamp(1, 30)}',
            'locale': _localeTag,
            if (type != null) 'type': type.wireValue,
            if (normalizedCursor.isNotEmpty) 'cursor': normalizedCursor,
          },
        );
    final data = await _get(uri, expectedContext: expectedContext);
    if (expectedContext != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    final page = AppletCatalogPage.fromJson(
      data,
      trustedOrigin: _environment.baseUri,
    );
    latestQuery.value = normalizedQuery;
    latestType.value = type;
    latestContextKey.value = expectedContext;
    latestPage.value = page;
    return page;
  }

  @override
  Future<AppletCatalogPage> browse({
    required AppletCatalogType type,
    AppletCatalogSort sort = AppletCatalogSort.recommended,
    String? cursor,
    int limit = 12,
  }) async {
    final normalizedCursor = cursor?.trim() ?? '';
    if (normalizedCursor.length > 512) {
      throw const FormatException('invalid_applet_cursor');
    }
    final expectedContext = requestContextKey;
    final uri = _environment.baseUri
        .resolve('v1/applets')
        .replace(
          queryParameters: <String, String>{
            'query': '',
            'include_skill': 'true',
            'limit': '${limit.clamp(1, 30)}',
            'locale': _localeTag,
            'type': type.wireValue,
            'sort': sort.wireValue,
            if (normalizedCursor.isNotEmpty) 'cursor': normalizedCursor,
          },
        );
    final data = await _get(uri, expectedContext: expectedContext);
    if (expectedContext != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    return AppletCatalogPage.fromJson(
      data,
      trustedOrigin: _environment.baseUri,
    );
  }

  @override
  Future<AppletCatalogPage> searchRanked({
    required String query,
    String? category,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  }) async {
    final normalized = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.runes.length > 80 ||
        (category != null &&
            !const {'game', 'travel', 'tools'}.contains(category)) ||
        (cursor?.length ?? 0) > 512) {
      throw const FormatException('invalid_applet_query');
    }
    final context = requestContextKey;
    final uri = _environment.baseUri
        .resolve('v1/applets')
        .replace(
          queryParameters: {
            'query': normalized,
            'include_skill': 'true',
            'sort': 'rating',
            'limit': '${limit.clamp(1, 30)}',
            'locale': _localeTag,
            'category': ?category,
            if (type != null) 'type': type.wireValue,
            if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          },
        );
    return AppletCatalogPage.fromJson(
      await _get(uri, expectedContext: context),
      trustedOrigin: _environment.baseUri,
    );
  }

  @override
  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  }) async {
    final validated = _appletUri(id, 'source');
    final uri = owned
        ? _environment.baseUri.resolve(
            'v1/agent-games/${Uri.encodeComponent(id)}/source',
          )
        : validated;
    final result = AppletSourceDocument.fromJson(
      await _get(uri, expectedContext: expectedContextKey),
    );
    if (result.id != id || requestContextKey != expectedContextKey) {
      throw StateError('applet_source_context_changed');
    }
    return result;
  }

  Future<AppletEngagementSnapshot> getEngagement(
    String id, {
    required String expectedContextKey,
  }) async => AppletEngagementSnapshot.fromJson(
    await _get(
      _appletUri(id, 'engagement'),
      expectedContext: expectedContextKey,
    ),
  );

  Future<AppletEngagementSnapshot> officialEngagement(
    String id, {
    required String expectedContextKey,
  }) async => AppletEngagementSnapshot.fromJson(
    await _get(
      _officialAppletUri(id, 'engagement'),
      expectedContext: expectedContextKey,
    ),
  );

  Future<AppletEngagementSnapshot> setOfficialLiked(
    String id,
    bool liked, {
    required String expectedContextKey,
  }) async => AppletEngagementSnapshot.fromJson(
    await _request(
      'POST',
      _officialAppletUri(id, 'likes/status'),
      body: {'liked': liked},
      expectedContext: expectedContextKey,
    ),
  );

  Uri _officialAppletUri(String id, String suffix) {
    if (id != 'ble_yoturetoys_projector') {
      throw const FormatException('invalid_official_applet_id');
    }
    return _environment.baseUri.resolve('v1/official-applets/$id/$suffix');
  }

  @override
  Future<AppletEngagementSnapshot> setLiked(
    String appletId,
    bool liked, {
    required String expectedContextKey,
  }) async => AppletEngagementSnapshot.fromJson(
    await _postApplet(
      appletId,
      'likes/status',
      body: <String, Object?>{'liked': liked},
      expectedContext: expectedContextKey,
    ),
  );

  @override
  Future<AppletCommentPage> listComments(
    String appletId, {
    String? cursor,
    int limit = 30,
    required String expectedContextKey,
  }) async {
    final normalizedCursor = cursor?.trim() ?? '';
    if (normalizedCursor.length > 512) {
      throw const FormatException('invalid_applet_cursor');
    }
    final uri = _appletUri(appletId, 'comments').replace(
      queryParameters: <String, String>{
        'limit': '${limit.clamp(1, 50)}',
        if (normalizedCursor.isNotEmpty) 'cursor': normalizedCursor,
      },
    );
    return AppletCommentPage.fromJson(
      await _get(uri, expectedContext: expectedContextKey),
    );
  }

  @override
  Future<AppletComment> postComment(
    String appletId,
    String text, {
    required String expectedContextKey,
  }) async {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty || normalized.runes.length > 180) {
      throw const FormatException('invalid_applet_comment');
    }
    await _requireCommentIdentity(expectedContextKey);
    return AppletComment.fromJson(
      await _postApplet(
        appletId,
        'comments',
        body: <String, Object?>{'text': normalized},
        expectedContext: expectedContextKey,
      ),
    );
  }

  @override
  Future<AppletEngagementSnapshot> recordView(
    String appletId, {
    required String eventId,
    required String expectedContextKey,
  }) async => AppletEngagementSnapshot.fromJson(
    await _postApplet(
      appletId,
      'views',
      body: <String, Object?>{'eventId': _eventId(eventId)},
      expectedContext: expectedContextKey,
    ),
  );

  Future<AppletComment> postCommentWithInput(
    String appletId,
    String text, {
    required String requestId,
    String? parentCommentId,
    required String expectedContextKey,
  }) async {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty ||
        normalized.runes.length > 180 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,35}$').hasMatch(requestId) ||
        (parentCommentId != null &&
            !RegExp(
              r'^agc_[A-Za-z0-9._:-]{1,36}$',
            ).hasMatch(parentCommentId))) {
      throw const FormatException('invalid_applet_comment');
    }
    await _requireCommentIdentity(expectedContextKey);
    final payload = await _postApplet(
      appletId,
      'comments',
      body: {
        'text': normalized,
        'requestId': requestId,
        'parentCommentId': ?parentCommentId,
      },
      expectedContext: expectedContextKey,
    );
    if (expectedContextKey != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    final comment = AppletComment.fromJson(payload);
    if (comment.parentCommentId != parentCommentId) {
      throw const FormatException('invalid_applet_reply_target');
    }
    return comment;
  }

  Future<void> _requireCommentIdentity(String expectedContextKey) async {
    if (expectedContextKey != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    final identity = appServices.maybeFind<IdentityService>();
    if (identity == null) return;
    // A restored name opens the app, but public writes still need the current
    // server identity. Resolve it here because this client owns its auth path.
    if (!identity.completed) await identity.load();
    if (expectedContextKey != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    if (!identity.isCurrent ||
        !identical(identity, appServices.maybeFind<IdentityService>())) {
      throw const IdentityException(IdentityFailure.contextChanged);
    }
    if (!identity.completed) {
      throw const IdentityException(IdentityFailure.rejected);
    }
  }

  @override
  Future<AppletEngagementSnapshot> recordShare(
    String appletId, {
    required String eventId,
    required String expectedContextKey,
  }) async => AppletEngagementSnapshot.fromJson(
    await _postApplet(
      appletId,
      'shares',
      body: <String, Object?>{'eventId': _eventId(eventId)},
      expectedContext: expectedContextKey,
    ),
  );

  Uri _appletUri(String appletId, String action) {
    final id = appletId.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,39}$').hasMatch(id)) {
      throw const FormatException('invalid_applet_catalog_id');
    }
    return _environment.baseUri.resolve(
      'v1/applets/${Uri.encodeComponent(id)}/$action',
    );
  }

  String _eventId(String raw) {
    final value = raw.trim();
    if (value.isEmpty ||
        value.length > 96 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value)) {
      throw const FormatException('invalid_applet_event_id');
    }
    return value;
  }

  Future<Object?> _postApplet(
    String appletId,
    String action, {
    required Map<String, Object?> body,
    required String expectedContext,
  }) => _request(
    'POST',
    _appletUri(appletId, action),
    body: body,
    expectedContext: expectedContext,
  );

  Future<AppletQuotaSnapshot> quota() async {
    final expectedContext = requestContextKey;
    final uri = _environment.baseUri.resolve('v1/applets/quota');
    final data = await _get(uri, expectedContext: expectedContext);
    if (expectedContext != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    return AppletQuotaSnapshot.fromJson(data);
  }

  Future<AppletInventoryPage> mine() async {
    final expectedContext = requestContextKey;
    if (_missingMineContextKey != null &&
        _missingMineContextKey != expectedContext) {
      _missingMineContextKey = null;
    }
    if (_successfulMineContextKey != null &&
        _successfulMineContextKey != expectedContext) {
      _successfulMineContextKey = null;
    }
    if (_missingMineContextKey == expectedContext) {
      throw const AppletInventoryUnavailableException();
    }
    final inFlight = _mineInFlight;
    if (_mineInFlightContextKey == expectedContext && inFlight != null) {
      return inFlight;
    }
    final request = _loadMine(expectedContext);
    _mineInFlightContextKey = expectedContext;
    _mineInFlight = request;
    try {
      return await request;
    } finally {
      if (identical(_mineInFlight, request)) {
        _mineInFlight = null;
        _mineInFlightContextKey = null;
      }
    }
  }

  Future<AppletInventoryPage> _loadMine(String expectedContext) async {
    final uri = _environment.baseUri
        .resolve('v1/applets/mine')
        .replace(queryParameters: {'include_skill': 'true'});
    late final Object? data;
    try {
      data = await _get(
        uri,
        expectedContext: expectedContext,
        suppressNotFoundResponseLog:
            _successfulMineContextKey != expectedContext,
      );
    } on AppletCatalogRequestException catch (error) {
      if (!error.routeMissing) rethrow;
      if (expectedContext != requestContextKey) {
        throw StateError('applet_request_context_changed');
      }
      if (_successfulMineContextKey == expectedContext) rethrow;
      _missingMineContextKey = expectedContext;
      throw const AppletInventoryUnavailableException();
    }
    if (expectedContext != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    final page = AppletInventoryPage.fromJson(
      data,
      trustedOrigin: _environment.baseUri,
    );
    _successfulMineContextKey = expectedContext;
    _missingMineContextKey = null;
    return page;
  }

  Future<Object?> _get(
    Uri uri, {
    required String expectedContext,
    bool suppressNotFoundResponseLog = false,
  }) async {
    return _request(
      'GET',
      uri,
      expectedContext: expectedContext,
      suppressNotFoundResponseLog: suppressNotFoundResponseLog,
    );
  }

  Future<Object?> _request(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    required String expectedContext,
    bool suppressNotFoundResponseLog = false,
  }) async {
    if (expectedContext != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    final token = await _accessToken(expectedContext);
    if (expectedContext != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    late final http.Response response;
    try {
      final headers = <String, String>{
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        if (body != null) 'Content-Type': 'application/json',
      };
      final request = switch (method) {
        'GET' => _http.get(uri, headers: headers),
        'POST' => _http.post(uri, headers: headers, body: jsonEncode(body)),
        _ => throw StateError('unsupported_applet_method'),
      };
      response = await request.timeout(const Duration(seconds: 12));
    } catch (error, stackTrace) {
      ServerRequestFailureLog.transport(
        source: 'AppletCatalog',
        method: method,
        uri: uri,
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    try {
      final httpSucceeded =
          response.statusCode >= 200 && response.statusCode < 300;
      late final Object? decoded;
      try {
        decoded = response.body.trim().isEmpty
            ? const <String, Object?>{}
            : jsonDecode(response.body);
      } on FormatException {
        if (!httpSucceeded) {
          throw AppletCatalogRequestException(
            response.statusCode,
            '',
            routeMissing: _isPlainRouteMissingResponse(response),
          );
        }
        rethrow;
      }
      if (decoded is! Map) {
        if (!httpSucceeded) {
          throw AppletCatalogRequestException(response.statusCode, '');
        }
        throw const FormatException('invalid_applet_envelope');
      }
      final envelope = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final code = envelope['code'] is String
          ? (envelope['code'] as String).trim()
          : '';
      if (!httpSucceeded || (code.isNotEmpty && code != 'OK')) {
        throw AppletCatalogRequestException(response.statusCode, code);
      }
      return envelope['data'];
    } catch (error, stackTrace) {
      if (!(suppressNotFoundResponseLog &&
          _isPlainRouteMissingResponse(response))) {
        ServerRequestFailureLog.response(
          source: 'AppletCatalog',
          method: method,
          uri: uri,
          statusCode: response.statusCode,
          responseBody: response.body,
          error: error,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }
  }

  Future<String> _accessToken(String expectedContext) async {
    final current = _auth.session.value;
    if (current != null && current.isValid) return current.accessToken;
    final restored = await _auth.restoreOrRefresh();
    final refreshed = _auth.session.value;
    if (!restored || refreshed == null || !refreshed.isValid) {
      throw StateError('applet_sign_in_required');
    }
    if (expectedContext != requestContextKey) {
      throw StateError('applet_request_context_changed');
    }
    return refreshed.accessToken;
  }

  String get _localeTag => switch (_locale.resolvedAppLocale) {
    AppLocale.zh => 'zh-CN',
    AppLocale.en || AppLocale.system => 'en-US',
  };

  @override
  void onClose() {
    if (_ownsClient) _http.close();
    super.onClose();
  }
}

bool _isPlainRouteMissingResponse(http.Response response) =>
    response.statusCode == 404 &&
    response.body.trim().toLowerCase() == '404 page not found';
