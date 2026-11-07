import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_version_models.dart';
export 'package:maaso/src/features/agent_games/data/agent_game_version_models.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/server_request_failure_log.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/offline/original_ui_local_catalog.dart';

final RegExp _clientSurfaceIdPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$',
);

enum AgentGameSyncState { pending, synced, failed, published, conflict }

/// Actual automatic source-validation and publication request phases.
enum AgentGamePublicationPhase { reviewing, publishing }

/// Whether an unpresented Applet is fully gone or only durably scheduled for
/// deletion. A pending tombstone is safe for cancellation, but a generation
/// repair must not create a replacement until the remote quota is released.
enum AgentGameCompensationStatus { complete, pending }

/// The private Applet is safely synced, but this environment does not allow
/// publishing it to the public catalog yet.
final class AppletPublicationUnavailableException implements Exception {
  const AppletPublicationUnavailableException();

  @override
  String toString() => 'applet_publication_unavailable';
}

class AgentGameCloudMetadata {
  const AgentGameCloudMetadata({
    required this.gameId,
    required this.revisionNo,
    required this.sourceSha256,
    required this.syncState,
    this.scopeKey = '',
    this.hasPublished = false,
    this.publishedRevisionNo = 0,
    this.publishedSourceSha256 = '',
    this.shareUrl = '',
    this.syncedAt,
    this.error = '',
    this.localVersionId = '',
    this.publishedLocalVersionId = '',
  });

  final String gameId;
  final int revisionNo;
  final String sourceSha256;
  final AgentGameSyncState syncState;
  final String scopeKey;
  final bool hasPublished;
  final int publishedRevisionNo;
  final String publishedSourceSha256;
  final String shareUrl;
  final DateTime? syncedAt;
  final String error;
  final String localVersionId;
  final String publishedLocalVersionId;

  bool get isCurrentInCloud =>
      gameId.isNotEmpty &&
      scopeKey.isNotEmpty &&
      revisionNo > 0 &&
      sourceSha256.isNotEmpty &&
      (syncState == AgentGameSyncState.synced ||
          syncState == AgentGameSyncState.published);

  bool get isCurrentPublished =>
      syncState == AgentGameSyncState.published &&
      hasPublished &&
      revisionNo > 0 &&
      revisionNo == publishedRevisionNo &&
      sourceSha256.isNotEmpty &&
      sourceSha256 == publishedSourceSha256 &&
      (localVersionId.isEmpty ||
          publishedLocalVersionId.isEmpty ||
          localVersionId == publishedLocalVersionId);

  Map<String, Object?> toJson() => <String, Object?>{
    if (gameId.isNotEmpty) 'gameId': gameId,
    if (revisionNo > 0) 'revisionNo': revisionNo,
    'sourceSha256': sourceSha256,
    'syncState': syncState.name,
    if (scopeKey.isNotEmpty) 'scopeKey': scopeKey,
    if (hasPublished) 'hasPublished': true,
    if (publishedRevisionNo > 0) 'publishedRevisionNo': publishedRevisionNo,
    if (publishedSourceSha256.isNotEmpty)
      'publishedSourceSha256': publishedSourceSha256,
    if (shareUrl.isNotEmpty) 'shareUrl': shareUrl,
    if (syncedAt != null) 'syncedAt': syncedAt!.toUtc().toIso8601String(),
    if (error.isNotEmpty) 'error': error,
    if (localVersionId.isNotEmpty) 'localVersionId': localVersionId,
    if (publishedLocalVersionId.isNotEmpty)
      'publishedLocalVersionId': publishedLocalVersionId,
  };

  factory AgentGameCloudMetadata.fromSpec(Object? raw) {
    final json = raw is Map
        ? raw.map((key, value) => MapEntry(key.toString(), value))
        : const <String, Object?>{};
    final syncState = _syncState(json['syncState']);
    final revisionNo = _asInt(json['revisionNo']);
    final sourceSha256 = json['sourceSha256']?.toString().trim() ?? '';
    final shareUrl = json['shareUrl']?.toString().trim() ?? '';
    final hasPublished =
        json['hasPublished'] == true ||
        syncState == AgentGameSyncState.published ||
        shareUrl.isNotEmpty;
    return AgentGameCloudMetadata(
      gameId: json['gameId']?.toString().trim() ?? '',
      revisionNo: revisionNo,
      sourceSha256: sourceSha256,
      syncState: syncState,
      scopeKey: json['scopeKey']?.toString().trim() ?? '',
      hasPublished: hasPublished,
      publishedRevisionNo: _asInt(json['publishedRevisionNo']) > 0
          ? _asInt(json['publishedRevisionNo'])
          : (syncState == AgentGameSyncState.published ? revisionNo : 0),
      publishedSourceSha256:
          json['publishedSourceSha256']?.toString().trim().isNotEmpty == true
          ? json['publishedSourceSha256'].toString().trim()
          : (syncState == AgentGameSyncState.published ? sourceSha256 : ''),
      shareUrl: shareUrl,
      syncedAt: DateTime.tryParse(json['syncedAt']?.toString() ?? ''),
      error: json['error']?.toString().trim() ?? '',
      localVersionId: json['localVersionId']?.toString() ?? '',
      publishedLocalVersionId:
          json['publishedLocalVersionId']?.toString() ?? '',
    );
  }

  static int _asInt(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  static AgentGameSyncState _syncState(Object? raw) {
    final value = raw?.toString().trim();
    for (final state in AgentGameSyncState.values) {
      if (state.name == value) return state;
    }
    return AgentGameSyncState.pending;
  }
}

abstract interface class AgentGameShareGateway {
  Future<bool> share({
    required String title,
    required String text,
    Rect? origin,
  });
}

class PlatformAgentGameShareGateway implements AgentGameShareGateway {
  const PlatformAgentGameShareGateway({
    MethodChannel channel = const MethodChannel('maaso/share'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<bool> share({
    required String title,
    required String text,
    Rect? origin,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('share', <String, Object?>{
            'title': title,
            'text': text,
            if (origin != null)
              'origin': <String, double>{
                'left': origin.left,
                'top': origin.top,
                'width': origin.width,
                'height': origin.height,
              },
          }) ==
          true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

class AgentGameCloudService extends AppService {
  AgentGameCloudService({
    DBService? database,
    http.Client? httpClient,
    Uri Function()? baseUri,
    Future<String> Function()? accessToken,
    String Function()? accountScope,
    String Function()? catalogLocale,
    AgentGameShareGateway? shareGateway,
    DateTime Function()? now,
    Duration requestTimeout = const Duration(seconds: 15),
    this.localEdition = false,
  }) : _database = database ?? appServices.find<DBService>(),
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _baseUri =
           baseUri ?? (() => appServices.find<AppEnvironmentService>().baseUri),
       _accessTokenOverride = accessToken,
       _accountScopeOverride =
           accountScope ?? (accessToken == null ? null : (() => 'test-scope')),
       _catalogLocaleOverride = catalogLocale,
       _shareGateway = shareGateway ?? const PlatformAgentGameShareGateway(),
       _now = now ?? DateTime.now,
       _requestTimeout = requestTimeout;

  final DBService _database;
  final http.Client _http;
  final bool _ownsClient;
  final Uri Function() _baseUri;
  final Future<String> Function()? _accessTokenOverride;
  final String Function()? _accountScopeOverride;
  final String Function()? _catalogLocaleOverride;
  final AgentGameShareGateway _shareGateway;
  final DateTime Function() _now;
  final Duration _requestTimeout;
  final bool localEdition;
  OriginalUiLocalCatalog? _localCatalog;
  OriginalUiLocalCatalog get _local => _localCatalog ??= OriginalUiLocalCatalog(
    database: _database,
    scopeKey: _currentScopeKey,
    now: _now,
  );
  final Map<String, Future<void>> _mutationTails = <String, Future<void>>{};
  final Set<String> _deletingMutationKeys = <String>{};
  Worker? _authSessionWorker;
  Worker? _environmentWorker;
  Timer? _retryTimer;

  @override
  void onInit() {
    super.onInit();
    if (_accountScopeOverride == null &&
        appServices.isRegistered<AuthSessionService>()) {
      _authSessionWorker = ever<MaasoAuthSession?>(
        appServices.find<AuthSessionService>().session,
        (session) {
          if (session != null) unawaited(retryPendingOrFailed());
        },
      );
    }
    if (_accountScopeOverride == null &&
        appServices.isRegistered<AppEnvironmentService>()) {
      _environmentWorker = ever<MaasoEnvironment>(
        appServices.find<AppEnvironmentService>().environment,
        (_) => unawaited(retryPendingOrFailed()),
      );
    }
  }

  /// Restores an existing owner's immutable draft without creating a cloud item.
  Future<AgentWidget> restoreOwned(
    AppletInventoryItem item, {
    required String expectedScopeKey,
  }) async {
    return _enqueueMutation(item.clientSurfaceId, () async {
      if (_currentScopeKey() != expectedScopeKey) {
        throw StateError('applet_request_context_changed');
      }
      for (final saved in await _database.getAllWidgets()) {
        if (AppletLocalOwnership.storedScopeKey(saved) == expectedScopeKey &&
            (saved.spec['surfaceId'] ?? saved.spec['id']) ==
                item.clientSurfaceId) {
          if (_currentScopeKey() != expectedScopeKey ||
              saved.spec['cloudDelete'] != null) {
            throw StateError('applet_restore_context_changed');
          }
          return saved;
        }
      }
      final catalog = appServices.find<AppletCatalogService>();
      final context = catalog.requestContextKey;
      final document = await catalog.source(
        item.id,
        owned: true,
        expectedContextKey: context,
      );
      if (_currentScopeKey() != expectedScopeKey ||
          document.clientSurfaceId != item.clientSurfaceId) {
        throw StateError('applet_request_context_changed');
      }
      final project = SurfaceProject.fromJson(document.toProjectJson());
      SurfaceProjectValidator.validateForPublicApplet(project);
      final remote = document.cloud;
      final history = SurfaceVersionHistory.create(
        project.toJson(),
        title: project.title,
      );
      final metadata = AgentGameCloudMetadata(
        gameId: item.id,
        localVersionId: history.current.id,
        publishedLocalVersionId: remote['published'] == true
            ? history.current.id
            : '',
        revisionNo: document.revisionNo,
        sourceSha256: document.sourceSha256,
        syncState: remote['published'] == true
            ? AgentGameSyncState.published
            : AgentGameSyncState.synced,
        scopeKey: expectedScopeKey,
        hasPublished: remote['hasPublished'] == true,
        publishedRevisionNo:
            (remote['publishedRevisionNo'] as num?)?.toInt() ?? 0,
        publishedSourceSha256: remote['publishedSourceSha256'] as String? ?? '',
        shareUrl: remote['shareUrl'] as String? ?? '',
      );
      final restored = AgentWidget(
        agentId: 'self',
        title: item.title,
        subtitle: item.summary,
        kind: 'surface',
        createdAt: item.updatedAt,
        seen: true,
        spec: {
          ...project.toJson(),
          'versionHistory': history.toJson(),
          'versionCloudBindings': {
            history.current.id: {
              'gameId': document.id,
              'revisionNo': document.revisionNo,
              'sourceSha256': document.sourceSha256,
            },
          },
          'surfaceId': document.clientSurfaceId,
          'surfaceKind': project.kind.name,
          'cloud': metadata.toJson(),
        },
      );
      AppletLocalOwnership.stamp(restored, scopeKey: expectedScopeKey);
      await _database.saveAgentWidgetValidated(
        restored,
        validate: (current) {
          if (_currentScopeKey() != expectedScopeKey ||
              current.any(
                (saved) =>
                    AppletLocalOwnership.storedScopeKey(saved) ==
                        expectedScopeKey &&
                    (saved.spec['surfaceId'] ?? saved.spec['id']) ==
                        item.clientSurfaceId,
              )) {
            throw StateError('applet_restore_context_changed');
          }
        },
      );
      return restored;
    });
  }

  Future<AgentGameRevisionPage> listVersions(
    AgentWidget widget, {
    int? beforeRevision,
    int limit = 50,
  }) async {
    final scope = _currentScopeKey();
    _requireOwnedVersionTarget(widget, scope);
    final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    if (limit < 1 ||
        limit > 100 ||
        (beforeRevision != null &&
            (beforeRevision < 1 || beforeRevision > 1001))) {
      throw const FormatException('invalid_applet_version_query');
    }
    final uri = _baseUri()
        .resolve(
          'v1/agent-games/${Uri.encodeComponent(cloud.gameId)}/revisions',
        )
        .replace(
          queryParameters: {
            'limit': '$limit',
            if (beforeRevision != null) 'beforeRevision': '$beforeRevision',
          },
        );
    final raw = await _readOwnedVersion(uri, scope);
    final page = AgentGameRevisionPage.fromJson(raw);
    if (page.gameId != cloud.gameId ||
        page.clientSurfaceId != _clientSurfaceId(widget) ||
        (beforeRevision != null &&
            page.items.any((entry) => entry.revisionNo >= beforeRevision))) {
      throw const FormatException('applet_version_history_invalid');
    }
    final updated = await _database.updateGeneratedSurfaceMetadata(
      widget.id!,
      expectedScopeKey: scope,
      validate: (current) => _versionTargetCurrent(current, widget, scope),
      update: (current) {
        final cached = _stringMap(current.spec['versionCloudIndex']);
        final entries = _stringMap(cached['items']);
        for (final row in (raw['items'] as List)) {
          entries['${(row as Map)['revisionNo']}'] = row;
        }
        return {
          'versionCloudIndex': {...raw, 'items': entries},
        };
      },
    );
    widget.spec = {
      ...widget.spec,
      'versionCloudIndex': updated.spec['versionCloudIndex'],
    };
    return page;
  }

  List<AgentGameRevisionSummary> cachedVersions(AgentWidget widget) {
    final scope = _currentScopeKey();
    _requireOwnedVersionTarget(widget, scope);
    final cache = _stringMap(widget.spec['versionCloudIndex']);
    final entries = _stringMap(cache['items']);
    final result = <AgentGameRevisionSummary>[];
    for (final raw in entries.values) {
      try {
        result.add(AgentGameRevisionSummary.fromJson(raw as Map));
      } catch (_) {
        /* Keep readable cache entries. */
      }
    }
    result.sort((a, b) => b.revisionNo.compareTo(a.revisionNo));
    return result;
  }

  Future<AppletSourceDocument> revisionSource(
    AgentWidget widget,
    int revisionNo, {
    String? expectedSourceSha256,
  }) async {
    final scope = _currentScopeKey();
    _requireOwnedVersionTarget(widget, scope);
    if (revisionNo < 1 || revisionNo > 1000) {
      throw const FormatException('invalid_applet_revision');
    }
    final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    final cache = _stringMap(widget.spec['versionSourceCache']);
    AppletSourceDocument? document;
    if (cache['$revisionNo'] != null) {
      try {
        document = AppletSourceDocument.fromJson(cache['$revisionNo']);
      } catch (_) {
        /* Refetch damaged cached source. */
      }
    }
    if (document == null) {
      final uri = _baseUri().resolve(
        'v1/agent-games/${Uri.encodeComponent(cloud.gameId)}/revisions/$revisionNo/source',
      );
      final raw = await _readOwnedVersion(
        uri,
        scope,
        maximumBytes: maxOwnedSourceResponseBytes,
      );
      document = AppletSourceDocument.fromJson(raw);
      if (document.id != cloud.gameId ||
          document.clientSurfaceId != _clientSurfaceId(widget) ||
          document.revisionNo != revisionNo ||
          (expectedSourceSha256 != null &&
              document.sourceSha256 != expectedSourceSha256)) {
        throw const FormatException('invalid_applet_source_digest');
      }
      final updated = await _database.updateGeneratedSurfaceMetadata(
        widget.id!,
        expectedScopeKey: scope,
        validate: (current) => _versionTargetCurrent(current, widget, scope),
        update: (current) => {
          'versionSourceCache': {
            ..._stringMap(current.spec['versionSourceCache']),
            '$revisionNo': raw,
          },
        },
      );
      widget.spec = {
        ...widget.spec,
        'versionSourceCache': updated.spec['versionSourceCache'],
      };
    }
    if (document.id != cloud.gameId ||
        document.clientSurfaceId != _clientSurfaceId(widget) ||
        document.revisionNo != revisionNo ||
        (expectedSourceSha256 != null &&
            document.sourceSha256 != expectedSourceSha256) ||
        _currentScopeKey() != scope) {
      throw const FormatException('invalid_applet_source_digest');
    }
    return document;
  }

  /// Human-confirmed reapplication against an explicitly displayed cloud head.
  /// A third device racing this request still receives the normal 409 fence.
  Future<AgentGameCloudMetadata> reapplyAfterConflict(
    AgentWidget widget, {
    required int expectedRemoteRevisionNo,
  }) {
    final snapshot = _snapshot(widget);
    final baseline = surfaceVersionFingerprint(
      widget.spec,
      title: widget.title,
    );
    return _enqueueMutation(snapshot.clientSurfaceId, () async {
      final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
      final uri = _baseUri().resolve(
        'v1/agent-games/${Uri.encodeComponent(cloud.gameId)}/source',
      );
      final remote = AppletSourceDocument.fromJson(
        await _readOwnedVersion(
          uri,
          snapshot.scopeKey,
          maximumBytes: maxOwnedSourceResponseBytes,
        ),
      );
      if (remote.id != cloud.gameId ||
          remote.clientSurfaceId != snapshot.clientSurfaceId ||
          remote.revisionNo != expectedRemoteRevisionNo) {
        throw const AppletVersionConflictException();
      }
      final rows = await _database.getAllWidgets();
      final current = rows.where((row) => row.id == widget.id).firstOrNull;
      if (current == null ||
          surfaceVersionFingerprint(current.spec, title: current.title) !=
              baseline) {
        throw const AppletVersionConflictException();
      }
      final raw = remote.cloud;
      await _writeMetadata(
        widget,
        AgentGameCloudMetadata(
          gameId: remote.id,
          localVersionId: snapshot.localVersionId,
          publishedLocalVersionId: cloud.publishedLocalVersionId,
          revisionNo: remote.revisionNo,
          sourceSha256: remote.sourceSha256,
          syncState: AgentGameSyncState.pending,
          scopeKey: snapshot.scopeKey,
          hasPublished: raw['hasPublished'] == true,
          publishedRevisionNo:
              (raw['publishedRevisionNo'] as num?)?.toInt() ?? 0,
          publishedSourceSha256: raw['publishedSourceSha256']?.toString() ?? '',
          shareUrl: raw['shareUrl']?.toString() ?? '',
        ),
      );
      return _syncSnapshot(snapshot, widget);
    });
  }

  void _requireOwnedVersionTarget(AgentWidget widget, String scope) {
    _ensureNotDeleting(widget);
    final metadata = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    if (widget.id == null ||
        widget.agentId != 'self' ||
        !widget.isSurface ||
        AppletLocalOwnership.storedScopeKey(widget) != scope ||
        metadata.scopeKey != scope ||
        metadata.gameId.isEmpty) {
      throw StateError('applet_request_context_changed');
    }
  }

  bool _versionTargetCurrent(
    AgentWidget current,
    AgentWidget selected,
    String scope,
  ) =>
      _currentScopeKey() == scope &&
      current.agentId == 'self' &&
      AppletLocalOwnership.storedScopeKey(current) == scope &&
      _clientSurfaceId(current) == _clientSurfaceId(selected) &&
      AgentGameCloudMetadata.fromSpec(current.spec['cloud']).gameId ==
          AgentGameCloudMetadata.fromSpec(selected.spec['cloud']).gameId;

  // JSON escaping expands the bounded decoded source; metadata-only history
  // listings retain their smaller allowance. No model token budget is changed.
  static const maxOwnedSourceResponseBytes =
      6 * SurfaceProjectValidator.maximumPublicSourceBytes + 1024 * 1024;

  Future<Map<String, Object?>> _readOwnedVersion(
    Uri uri,
    String scope, {
    int maximumBytes = 3 * 1024 * 1024,
  }) async {
    if (localEdition) return _local.readGame(uri, scope);
    final token = await _accessToken(scope);
    final response = await _http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(_requestTimeout);
    if (_currentScopeKey() != scope) {
      throw StateError('applet_request_context_changed');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        response.bodyBytes.length > maximumBytes) {
      throw StateError('applet_history_unavailable');
    }
    final envelope = jsonDecode(response.body);
    if (envelope is! Map ||
        envelope['code'] != 'OK' ||
        envelope['data'] is! Map) {
      throw const FormatException('applet_version_history_invalid');
    }
    return _stringMap(envelope['data']);
  }

  Future<void> schedulePrivateSync(AgentWidget widget) async {
    if (_deleteIntent(widget) != null) return;
    try {
      await syncPrivate(widget);
    } catch (error, stackTrace) {
      debugPrint('[AgentGameCloud] background sync failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      // A full cloud inventory needs an explicit server-side capacity change,
      // not a new upload every thirty seconds. The local project is retained.
      if (error is! AppletQuotaExceededException) _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_retryTimer != null) return;
    _retryTimer = Timer(const Duration(seconds: 30), () {
      _retryTimer = null;
      unawaited(retryPendingOrFailed());
    });
  }

  Future<AgentGameCloudMetadata> syncPrivate(AgentWidget widget) {
    _ensureNotDeleting(widget);
    final snapshot = _snapshot(widget);
    return _enqueueMutation(
      snapshot.clientSurfaceId,
      () => _syncSnapshot(snapshot, widget),
    );
  }

  Future<AgentGameCloudMetadata> syncNewBeforePresent(
    AgentWidget widget,
  ) async {
    // Validate source and captured ownership before treating a cloud transport
    // failure as optional. Local playback never requires a cloud registration.
    final snapshot = _snapshot(widget);
    try {
      return await syncPrivate(widget);
    } catch (error) {
      if (_currentScopeKey() != snapshot.scopeKey ||
          AppletLocalOwnership.storedScopeKey(widget) != snapshot.scopeKey) {
        rethrow;
      }
      _ensureNotDeleting(widget);
      final previous = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
      final pending = AgentGameCloudMetadata(
        gameId: previous.gameId,
        revisionNo: previous.revisionNo,
        sourceSha256: snapshot.sourceSha256,
        localVersionId: snapshot.localVersionId,
        publishedLocalVersionId: previous.publishedLocalVersionId,
        syncState: error is AppletVersionConflictException
            ? AgentGameSyncState.conflict
            : AgentGameSyncState.pending,
        scopeKey: snapshot.scopeKey,
        hasPublished: previous.hasPublished,
        publishedRevisionNo: previous.publishedRevisionNo,
        publishedSourceSha256: previous.publishedSourceSha256,
        shareUrl: previous.shareUrl,
        syncedAt: previous.syncedAt,
        error: error is AppletQuotaExceededException
            ? 'applet_quota_reached'
            : 'applet_cloud_sync_pending',
      );
      // This strict write still fences account changes, deleted rows and
      // concurrent source changes. It must succeed before local presentation.
      await _writeMetadata(widget, pending);
      if (error is! AppletQuotaExceededException &&
          error is! AppletVersionConflictException) {
        _scheduleRetry();
      }
      return pending;
    }
  }

  /// Durably removes a newly synced Applet that was cancelled before its
  /// presentation receipt committed.
  ///
  /// The tombstone is written using the ownership captured by the generation
  /// turn, even if the active account changed while the sync request was in
  /// flight. When that scope is active we delete immediately; otherwise the
  /// existing account/environment workers resume the idempotent delete when
  /// the owner scope becomes active again.
  Future<AgentGameCompensationStatus> compensateUnpresented(
    AgentWidget widget, {
    required String expectedScopeKey,
  }) async {
    final widgetId = widget.id;
    if (widgetId == null ||
        AppletLocalOwnership.storedScopeKey(widget) != expectedScopeKey) {
      throw StateError('Unpresented Applet ownership is invalid');
    }
    if (expectedScopeKey == AppletLocalOwnership.deviceLegacyScope) {
      await _database.deleteWidgetValidated(
        widgetId,
        validate: (current) =>
            current.agentId == widget.agentId &&
            AppletLocalOwnership.storedScopeKey(current) == expectedScopeKey &&
            current.spec['surfaceId'] == widget.spec['surfaceId'] &&
            isAppletPresentationPending(current),
      );
      return AgentGameCompensationStatus.complete;
    }
    final clientSurfaceId = _clientSurfaceId(widget);
    final mutationKey = _mutationKey(expectedScopeKey, clientSurfaceId);
    _deletingMutationKeys.add(mutationKey);
    try {
      await _markDeletePending(widget, expectedScopeKey, clientSurfaceId);
    } catch (_) {
      _deletingMutationKeys.remove(mutationKey);
      rethrow;
    }

    String currentScopeKey;
    try {
      currentScopeKey = _currentScopeKey();
    } catch (_) {
      _scheduleRetry();
      return AgentGameCompensationStatus.pending;
    }
    if (currentScopeKey != expectedScopeKey) {
      _scheduleRetry();
      return AgentGameCompensationStatus.pending;
    }

    try {
      await _enqueueMutation(
        clientSurfaceId,
        () => _deleteRemoteNow(widget, expectedScopeKey, clientSurfaceId),
      );
      return AgentGameCompensationStatus.complete;
    } catch (error, stackTrace) {
      debugPrint('[AgentGameCloud] cancelled Applet cleanup pending: $error');
      debugPrintStack(stackTrace: stackTrace);
      _scheduleRetry();
      return AgentGameCompensationStatus.pending;
    }
  }

  Future<void> retryPendingOrFailed() async {
    String? cloudScopeKey;
    try {
      cloudScopeKey = _currentScopeKey();
    } catch (_) {}
    final localScopeKey = _accountScopeOverride != null
        ? cloudScopeKey ?? AppletLocalOwnership.currentScopeKey()
        : AppletLocalOwnership.currentScopeKey();
    final widgets = await _database.getAllWidgets();
    final orphanedPresentations = <AgentWidget>[];
    final deleting = <AgentWidget>[];
    final pending = <AgentWidget>[];
    for (final widget in widgets) {
      _AgentGameDeleteIntent? intent;
      try {
        intent = _deleteIntent(widget);
      } catch (error) {
        debugPrint('[AgentGameCloud] invalid delete tombstone: $error');
        continue;
      }
      if (intent != null) {
        // A durable delete intent always outranks presentationPending. A
        // cancellation can carry both markers until remote deletion succeeds.
        if (cloudScopeKey != null && intent.scopeKey == cloudScopeKey) {
          deleting.add(widget);
        }
        continue;
      }
      if (isAppletPresentationPending(widget)) {
        if (isOrphanedAppletPresentation(widget) &&
            AppletLocalOwnership.storedScopeKey(widget) == localScopeKey) {
          orphanedPresentations.add(widget);
        }
        // A current-process presentation is owned by its executor. Never
        // race it with background sync or cleanup.
        continue;
      }
      if (cloudScopeKey == null) continue;
      if (!isCloudAppletWidget(widget) || widget.spec['cloud'] is! Map) {
        continue;
      }
      final metadata = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
      if (metadata.scopeKey != cloudScopeKey) continue;
      // Upload capacity is a server decision. An unrelated retry timer must
      // not repeatedly resend locally retained projects that hit that quota.
      // Explicit sync/publication can recheck the server when the user acts.
      if (metadata.error == 'applet_quota_reached') continue;
      final state = metadata.syncState;
      if (state == AgentGameSyncState.pending ||
          state == AgentGameSyncState.failed) {
        pending.add(widget);
      }
    }
    await Future.wait(
      orphanedPresentations.map(
        (widget) => _recoverOrphanedPresentation(widget, localScopeKey),
      ),
    );
    await Future.wait(deleting.map(_scheduleRemoteDelete));
    await Future.wait(pending.map(schedulePrivateSync));
  }

  Future<void> _recoverOrphanedPresentation(
    AgentWidget widget,
    String scopeKey,
  ) async {
    final widgetId = widget.id;
    if (widgetId == null) return;
    try {
      if (scopeKey != AppletLocalOwnership.deviceLegacyScope &&
          isCloudAppletWidget(widget)) {
        await compensateUnpresented(widget, expectedScopeKey: scopeKey);
        return;
      }
      await _database.deleteWidgetValidated(
        widgetId,
        validate: (current) =>
            current.agentId == widget.agentId &&
            AppletLocalOwnership.storedScopeKey(current) == scopeKey &&
            current.spec['surfaceId'] == widget.spec['surfaceId'] &&
            isOrphanedAppletPresentation(current),
      );
    } catch (error, stackTrace) {
      debugPrint(
        '[AgentGameCloud] orphaned presentation cleanup pending: $error',
      );
      debugPrintStack(stackTrace: stackTrace);
      _scheduleRetry();
    }
  }

  Future<AgentGameCloudMetadata> publish(
    AgentWidget widget, {
    void Function(AgentGamePublicationPhase phase)? onPhase,
  }) {
    _ensureNotDeleting(widget);
    if (!isCloudAppletWidget(widget)) {
      throw StateError(
        'Only public-safe webApp or workerCanvas Applets can be published',
      );
    }
    final snapshot = _snapshot(widget);
    return _enqueueMutation(snapshot.clientSurfaceId, () async {
      onPhase?.call(AgentGamePublicationPhase.reviewing);
      final synced = await _syncSnapshot(snapshot, widget);
      onPhase?.call(AgentGamePublicationPhase.publishing);
      return _publishSynced(widget, synced, snapshot.scopeKey);
    });
  }

  Future<AgentGameCloudMetadata> _publishSynced(
    AgentWidget widget,
    AgentGameCloudMetadata synced,
    String scopeKey,
  ) async {
    if (!synced.isCurrentInCloud) {
      throw StateError('Agent game did not finish syncing');
    }
    final uri = _baseUri().resolve(
      'v1/agent-games/${Uri.encodeComponent(synced.gameId)}/publish',
    );
    final data = await _request(
      uri,
      body: <String, Object?>{
        'revisionNo': synced.revisionNo,
        'sourceSha256': synced.sourceSha256,
      },
      scopeKey: scopeKey,
      mapPublicationUnavailable: true,
    );
    final returnedGameId = _requiredString(data, 'gameId');
    final returnedRevisionNo = _positiveInt(data['revisionNo'], 'revisionNo');
    final returnedSha = _requiredString(data, 'sourceSha256');
    if (data['published'] != true ||
        returnedGameId != synced.gameId ||
        returnedRevisionNo != synced.revisionNo ||
        returnedSha != synced.sourceSha256) {
      throw StateError('Agent game publish returned a different revision');
    }
    final publishedRevisionNo = _optionalPositiveInt(
      data['publishedRevisionNo'],
      fallback: returnedRevisionNo,
    );
    final publishedSha = _optionalString(
      data['publishedSourceSha256'],
      fallback: returnedSha,
    );
    if (publishedRevisionNo != returnedRevisionNo ||
        publishedSha != returnedSha) {
      throw StateError('Agent game publish state does not match the revision');
    }
    final shareUrl = localEdition ? '' : _publicShareUrl(data['shareUrl']);
    final published = AgentGameCloudMetadata(
      gameId: returnedGameId,
      revisionNo: returnedRevisionNo,
      sourceSha256: returnedSha,
      localVersionId: synced.localVersionId,
      publishedLocalVersionId: synced.localVersionId,
      syncState: AgentGameSyncState.published,
      scopeKey: scopeKey,
      hasPublished: true,
      publishedRevisionNo: publishedRevisionNo,
      publishedSourceSha256: publishedSha,
      shareUrl: shareUrl,
      syncedAt: _now().toUtc(),
    );
    await _writeMetadata(widget, published);
    if (_currentScopeKey() != scopeKey) {
      throw StateError('Agent game account changed during the request');
    }
    return published;
  }

  Future<void> unpublish(AgentWidget widget) {
    if (!isCloudAppletWidget(widget)) return Future<void>.value();
    final clientSurfaceId = _clientSurfaceId(widget);
    final scopeKey = _currentScopeKey();
    return _enqueueMutation(
      clientSurfaceId,
      () => _unpublishNow(widget, scopeKey),
    );
  }

  Future<void> deleteRemote(AgentWidget widget) async {
    // Deletion follows durable cloud ownership, not the surface's current
    // rendering eligibility. A previously published workerCanvas Applet may
    // have been edited into a private DOM/canvas surface; its remote record
    // still has to be removed so the public URL and owner quota are revoked.
    final localSurfaceId = _clientSurfaceId(widget);
    final scopeKey = _currentScopeKey();
    _verifyDeleteOwnership(widget, scopeKey);
    final mutationKey = _mutationKey(scopeKey, localSurfaceId);
    _deletingMutationKeys.add(mutationKey);
    try {
      await _markDeletePending(widget, scopeKey, localSurfaceId);
    } catch (_) {
      _deletingMutationKeys.remove(mutationKey);
      rethrow;
    }
    if (_currentScopeKey() != scopeKey) {
      throw StateError('Agent game account changed during the request');
    }
    await _enqueueMutation(
      localSurfaceId,
      () => _deleteRemoteNow(widget, scopeKey, localSurfaceId),
    );
  }

  Future<void> deleteRemoteByClientSurfaceId(
    String rawClientSurfaceId, {
    required String expectedScopeKey,
  }) async {
    final clientSurfaceId = _validateClientSurfaceId(rawClientSurfaceId.trim());
    final scopeKey = _currentScopeKey();
    if (scopeKey != expectedScopeKey) {
      throw StateError('Agent game account changed before deletion');
    }
    final mutationKey = _mutationKey(scopeKey, clientSurfaceId);
    _deletingMutationKeys.add(mutationKey);
    try {
      await _enqueueMutation(
        clientSurfaceId,
        () => _deleteRemoteNow(null, scopeKey, clientSurfaceId),
      );
    } catch (_) {
      _deletingMutationKeys.remove(mutationKey);
      rethrow;
    }
  }

  Future<void> _scheduleRemoteDelete(AgentWidget widget) async {
    try {
      await deleteRemote(widget);
    } catch (error, stackTrace) {
      debugPrint('[AgentGameCloud] background delete failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      _scheduleRetry();
    }
  }

  Future<void> _deleteRemoteNow(
    AgentWidget? widget,
    String scopeKey,
    String clientSurfaceId,
  ) async {
    final uri = _baseUri().resolve(
      'v1/agent-games/by-client/'
      '${Uri.encodeComponent(clientSurfaceId)}/delete',
    );
    final data = await _request(
      uri,
      body: const <String, Object?>{},
      scopeKey: scopeKey,
    );
    if (data['deleted'] != true ||
        _requiredString(data, 'clientSurfaceId') != clientSurfaceId) {
      throw StateError('Agent game deletion was not confirmed');
    }
    if (_currentScopeKey() != scopeKey) {
      throw StateError('Agent game account changed during the request');
    }
    final widgetId = widget?.id;
    if (widgetId != null) {
      await _database.deleteWidgetValidated(
        widgetId,
        validate: (current) {
          final intent = _deleteIntent(current);
          return _currentScopeKey() == scopeKey &&
              current.agentId == widget?.agentId &&
              AppletLocalOwnership.storedScopeKey(current) == scopeKey &&
              _clientSurfaceId(current) == clientSurfaceId &&
              intent?.scopeKey == scopeKey &&
              intent?.clientSurfaceId == clientSurfaceId;
        },
      );
    }
    _deletingMutationKeys.remove(_mutationKey(scopeKey, clientSurfaceId));
  }

  void _verifyDeleteOwnership(AgentWidget widget, String expectedScope) {
    final localScope = AppletLocalOwnership.storedScopeKey(widget);
    if (localScope != expectedScope) {
      throw StateError('Applet belongs to another account or environment');
    }
    final cloud = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    if (cloud.scopeKey.isNotEmpty && cloud.scopeKey != expectedScope) {
      throw StateError('Applet belongs to another account or environment');
    }
    final intent = _deleteIntent(widget);
    if (intent != null && intent.scopeKey != expectedScope) {
      throw StateError('Applet belongs to another account or environment');
    }
  }

  Future<void> _unpublishNow(AgentWidget widget, String scopeKey) async {
    final previous = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    _verifyMetadataScope(previous, scopeKey);
    if (previous.gameId.isEmpty) return;
    final uri = _baseUri().resolve(
      'v1/agent-games/${Uri.encodeComponent(previous.gameId)}/unpublish',
    );
    final data = await _request(
      uri,
      body: const <String, Object?>{},
      scopeKey: scopeKey,
    );
    final returnedGameId = _requiredString(data, 'gameId');
    if (returnedGameId != previous.gameId || data['published'] == true) {
      throw StateError('Agent game unpublish was not confirmed');
    }
    await _writeMetadata(
      widget,
      AgentGameCloudMetadata(
        gameId: returnedGameId,
        revisionNo: _positiveInt(
          data['revisionNo'],
          'revisionNo',
          fallback: previous.revisionNo,
        ),
        sourceSha256: _requiredString(
          data,
          'sourceSha256',
          fallback: previous.sourceSha256,
        ),
        localVersionId: previous.localVersionId,
        syncState: AgentGameSyncState.synced,
        scopeKey: scopeKey,
        hasPublished: false,
        syncedAt: _now().toUtc(),
      ),
    );
  }

  Future<bool> publishAndShare(AgentWidget widget, {Rect? origin}) async {
    final published = await publish(widget);
    if (_currentScopeKey() != published.scopeKey) {
      throw StateError('Agent game account changed before sharing');
    }
    return _shareGateway.share(
      title: 'agent_games.share_title'.tr,
      text: localEdition
          ? _localSourceExport(widget)
          : '${widget.title}\n${published.shareUrl}',
      origin: origin,
    );
  }

  String _localSourceExport(AgentWidget widget) {
    final snapshot = _snapshot(widget);
    if (snapshot.surface['rendering'] != 'webApp') {
      return const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'title': widget.title,
        'surface': snapshot.surface,
      });
    }
    final source = snapshot.surface;
    return '${source['html'] ?? ''}\n'
        '<style>${source['css'] ?? ''}</style>\n'
        '<script>${source['js'] ?? ''}</script>';
  }

  Future<void> _markDeletePending(
    AgentWidget widget,
    String scopeKey,
    String clientSurfaceId,
  ) async {
    final existing = _deleteIntent(widget);
    if (existing != null &&
        (existing.scopeKey != scopeKey ||
            existing.clientSurfaceId != clientSurfaceId)) {
      throw StateError('Applet delete ownership is invalid');
    }
    final intent =
        existing ??
        _AgentGameDeleteIntent(
          scopeKey: scopeKey,
          clientSurfaceId: clientSurfaceId,
        );
    final json = intent.toJson();
    final nextSpec = <String, Object?>{
      ...widget.spec,
      _AgentGameDeleteIntent.specKey: json,
    };
    final widgetId = widget.id;
    if (widgetId != null) {
      await _database.updateWidgetSpecFieldValidated(
        widgetId,
        _AgentGameDeleteIntent.specKey,
        json,
        validate: (current) {
          final currentIntent = _deleteIntent(current);
          return current.agentId == widget.agentId &&
              AppletLocalOwnership.storedScopeKey(current) == scopeKey &&
              _clientSurfaceId(current) == clientSurfaceId &&
              (currentIntent == null ||
                  (currentIntent.scopeKey == scopeKey &&
                      currentIntent.clientSurfaceId == clientSurfaceId));
        },
      );
    }
    widget.spec = nextSpec;
  }

  void _ensureNotDeleting(AgentWidget widget) {
    final clientSurfaceId =
        (widget.spec['surfaceId'] ?? widget.spec['id'] ?? '').toString().trim();
    final scopeKey = AppletLocalOwnership.storedScopeKey(widget);
    if (_deleteIntent(widget) != null ||
        (clientSurfaceId.isNotEmpty &&
            _deletingMutationKeys.contains(
              _mutationKey(scopeKey, clientSurfaceId),
            ))) {
      throw StateError('Applet deletion is pending');
    }
  }

  String _mutationKey(String scopeKey, String clientSurfaceId) =>
      '$scopeKey::$clientSurfaceId';

  _AgentGameDeleteIntent? _deleteIntent(AgentWidget widget) =>
      _AgentGameDeleteIntent.fromSpec(
        widget.spec[_AgentGameDeleteIntent.specKey],
      );

  Future<T> _enqueueMutation<T>(
    String clientSurfaceId,
    Future<T> Function() operation,
  ) {
    final previous = _mutationTails[clientSurfaceId];
    final start = previous == null
        ? Future<void>.value()
        : previous.then<void>((_) {}, onError: (_, _) {});
    final result = start.then((_) => operation());
    late final Future<void> tail;
    tail = result.then<void>(
      (_) => _clearTail(clientSurfaceId, tail),
      onError: (_, _) => _clearTail(clientSurfaceId, tail),
    );
    _mutationTails[clientSurfaceId] = tail;
    return result;
  }

  void _clearTail(String clientSurfaceId, Future<void> completed) {
    if (identical(_mutationTails[clientSurfaceId], completed)) {
      _mutationTails.remove(clientSurfaceId);
    }
  }

  Future<AgentGameCloudMetadata> _syncSnapshot(
    _AgentGameSnapshot snapshot,
    AgentWidget widget,
  ) async {
    final freshRows = await _database.getAllWidgets();
    final fresh = freshRows.where((row) => row.id == widget.id).firstOrNull;
    if (fresh == null ||
        AppletLocalOwnership.storedScopeKey(fresh) != snapshot.scopeKey ||
        _clientSurfaceId(fresh) != snapshot.clientSurfaceId ||
        fresh.spec['cloudDelete'] != null) {
      throw StateError('applet_request_context_changed');
    }
    final previous = AgentGameCloudMetadata.fromSpec(fresh.spec['cloud']);
    _verifyMetadataScope(previous, snapshot.scopeKey);
    await _writeMetadata(
      widget,
      AgentGameCloudMetadata(
        gameId: previous.gameId,
        revisionNo: previous.revisionNo,
        sourceSha256: snapshot.sourceSha256,
        localVersionId: snapshot.localVersionId,
        publishedLocalVersionId: previous.publishedLocalVersionId,
        syncState: AgentGameSyncState.pending,
        scopeKey: snapshot.scopeKey,
        hasPublished: previous.hasPublished,
        publishedRevisionNo: previous.publishedRevisionNo,
        publishedSourceSha256: previous.publishedSourceSha256,
        shareUrl: previous.shareUrl,
      ),
    );
    final uri = _baseUri().resolve(
      'v1/agent-games/by-client/'
      '${Uri.encodeComponent(snapshot.clientSurfaceId)}',
    );
    try {
      final data = await _request(
        uri,
        body: <String, Object?>{
          'title': snapshot.title,
          'experienceType': snapshot.experienceType,
          'surface': snapshot.surface,
          if (snapshot.catalogMetadata case final catalog?) ...{
            'summary': catalog.summary,
            'locale': catalog.locale,
          },
          if (previous.revisionNo > 0) 'baseRevisionNo': previous.revisionNo,
        },
        scopeKey: snapshot.scopeKey,
      );
      _ensureNotDeleting(widget);
      final returnedSha = _requiredString(data, 'sourceSha256');
      if (returnedSha != snapshot.sourceSha256) {
        throw StateError('Agent game sync returned a different source hash');
      }
      if (_requiredString(data, 'clientSurfaceId') !=
              snapshot.clientSurfaceId ||
          _requiredString(data, 'experienceType') != snapshot.experienceType) {
        throw StateError('Agent game sync returned a different game');
      }
      final currentPublished = data['published'] == true;
      final hasPublished = data['hasPublished'] == true || currentPublished;
      var publishedRevisionNo = _optionalPositiveInt(
        data['publishedRevisionNo'],
        fallback: currentPublished
            ? _positiveInt(data['revisionNo'], 'revisionNo')
            : 0,
      );
      var publishedSourceSha256 = _optionalString(
        data['publishedSourceSha256'],
        fallback: currentPublished ? returnedSha : '',
      );
      var shareUrl = '';
      if (hasPublished) {
        if (publishedRevisionNo <= 0 || publishedSourceSha256.isEmpty) {
          throw StateError('Agent game response is missing published state');
        }
        shareUrl = localEdition ? '' : _publicShareUrl(data['shareUrl']);
      } else {
        publishedRevisionNo = 0;
        publishedSourceSha256 = '';
      }
      final synced = AgentGameCloudMetadata(
        gameId: _requiredString(data, 'gameId'),
        revisionNo: _positiveInt(data['revisionNo'], 'revisionNo'),
        sourceSha256: returnedSha,
        localVersionId: snapshot.localVersionId,
        publishedLocalVersionId: previous.publishedLocalVersionId.isNotEmpty
            ? previous.publishedLocalVersionId
            : currentPublished
            ? (previous.localVersionId.isNotEmpty
                  ? previous.localVersionId
                  : snapshot.localVersionId)
            : '',
        syncState: currentPublished
            ? AgentGameSyncState.published
            : AgentGameSyncState.synced,
        scopeKey: snapshot.scopeKey,
        hasPublished: hasPublished,
        publishedRevisionNo: publishedRevisionNo,
        publishedSourceSha256: publishedSourceSha256,
        shareUrl: shareUrl,
        syncedAt: _now().toUtc(),
      );
      await _writeMetadata(widget, synced, syncedSnapshot: snapshot);
      return synced;
    } catch (error) {
      await _writeMetadata(
        widget,
        AgentGameCloudMetadata(
          gameId: previous.gameId,
          revisionNo: previous.revisionNo,
          sourceSha256: snapshot.sourceSha256,
          localVersionId: snapshot.localVersionId,
          publishedLocalVersionId: previous.publishedLocalVersionId,
          syncState: error is AppletVersionConflictException
              ? AgentGameSyncState.conflict
              : AgentGameSyncState.failed,
          scopeKey: snapshot.scopeKey,
          hasPublished: previous.hasPublished,
          publishedRevisionNo: previous.publishedRevisionNo,
          publishedSourceSha256: previous.publishedSourceSha256,
          shareUrl: previous.shareUrl,
          syncedAt: previous.syncedAt,
          error: _boundedError(error),
        ),
      );
      rethrow;
    }
  }

  Future<void> _writeMetadata(
    AgentWidget widget,
    AgentGameCloudMetadata metadata, {
    _AgentGameSnapshot? syncedSnapshot,
  }) async {
    final widgetId = widget.id;
    if (widgetId == null) return;
    final updated = await _database.updateGeneratedSurfaceMetadata(
      widgetId,
      expectedScopeKey: metadata.scopeKey,
      validate: (current) =>
          _currentScopeKey() == metadata.scopeKey &&
          AppletLocalOwnership.storedScopeKey(current) == metadata.scopeKey &&
          _clientSurfaceId(current) == _clientSurfaceId(widget),
      update: (current) {
        final json = metadata.toJson();
        final currentSource = _snapshot(current);
        if (currentSource.sourceSha256 != metadata.sourceSha256 ||
            (metadata.localVersionId.isNotEmpty &&
                currentSource.localVersionId != metadata.localVersionId) ||
            (syncedSnapshot != null &&
                currentSource.localVersionId !=
                    syncedSnapshot.localVersionId)) {
          json['syncState'] = AgentGameSyncState.pending.name;
        }
        final bindings = _stringMap(current.spec['versionCloudBindings']);
        if (syncedSnapshot != null) {
          bindings[syncedSnapshot.localVersionId] = {
            'gameId': metadata.gameId,
            'revisionNo': metadata.revisionNo,
            'sourceSha256': metadata.sourceSha256,
          };
        }
        return {
          'cloud': json,
          if (syncedSnapshot != null) 'versionCloudBindings': bindings,
        };
      },
    );
    widget.spec = {
      ...widget.spec,
      'cloud': updated.spec['cloud'],
      if (updated.spec['versionCloudBindings'] != null)
        'versionCloudBindings': updated.spec['versionCloudBindings'],
    };
  }

  static Map<String, Object?> _stringMap(Object? raw) => raw is Map
      ? raw.map((key, value) => MapEntry(key.toString(), value))
      : {};

  _AgentGameSnapshot _snapshot(AgentWidget widget) {
    _ensureNotDeleting(widget);
    final scopeKey = _currentScopeKey();
    if (AppletLocalOwnership.storedScopeKey(widget) != scopeKey) {
      throw StateError('Applet belongs to another account or environment');
    }
    final widgetId = widget.id;
    if (widgetId == null || !widget.isSurface) {
      throw StateError('A saved Surface game is required');
    }
    final normalizedTitle = widget.title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalizedTitle.isEmpty) {
      throw StateError('Surface game title is required');
    }
    final projectJson = Map<String, Object?>.from(widget.spec);
    projectJson['id'] = (projectJson['surfaceId'] ?? projectJson['id'] ?? '')
        .toString();
    projectJson['title'] = normalizedTitle;
    projectJson['kind'] =
        projectJson['surfaceKind'] ??
        projectJson['surface'] ??
        projectJson['kind'];
    final project = SurfaceProject.fromJson(projectJson);
    SurfaceProjectValidator.validateForPublicApplet(project);
    final clientSurfaceId = project.id.trim();
    _validateClientSurfaceId(clientSurfaceId);
    final surface = <String, Object?>{
      'title': project.title,
      'rendering': project.rendering.name,
      'html': project.html,
      'css': project.css,
      'js': project.js,
      'manifest': project.manifest.toJson(),
      if (widget.spec.containsKey('category') && project.category.isNotEmpty)
        'category': project.experienceType == SurfaceExperienceType.game
            ? 'game'
            : (project.category == 'game' ? 'tools' : project.category),
      if (widget.spec.containsKey('skillInstructions') &&
          project.skillInstructions.isNotEmpty)
        'skillInstructions': project.skillInstructions,
    };
    final catalogMetadata = _AppletCatalogSyncMetadata.fromSpec(
      widget.spec[_AppletCatalogSyncMetadata.specKey],
    );
    return _AgentGameSnapshot(
      clientSurfaceId: clientSurfaceId,
      title: normalizedTitle,
      experienceType: project.experienceType.name,
      scopeKey: scopeKey,
      sourceSha256: canonicalAgentGameSourceSha256(surface),
      localVersionId: SurfaceVersionHistory.read(
        widget.spec,
        title: widget.title,
      ).current.id,
      surface: surface,
      catalogMetadata: catalogMetadata,
    );
  }

  String _clientSurfaceId(AgentWidget widget) {
    final value = (widget.spec['surfaceId'] ?? widget.spec['id'] ?? '')
        .toString()
        .trim();
    return _validateClientSurfaceId(value);
  }

  void stampLocalOwnership(AgentWidget widget, {String? expectedScopeKey}) {
    if (!isCloudAppletWidget(widget)) return;
    final scopeKey = _currentScopeKey();
    if (expectedScopeKey != null && scopeKey != expectedScopeKey) {
      throw StateError('Agent game account changed before local save');
    }
    final previous = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    _verifyMetadataScope(previous, scopeKey);
    final catalogMetadata = _AppletCatalogSyncMetadata.fromSpec(
      widget.spec[_AppletCatalogSyncMetadata.specKey],
    );
    if (previous.scopeKey == scopeKey) return;
    final stampedCatalog = catalogMetadata ?? _newCatalogMetadata(widget);
    widget.spec = <String, Object?>{
      ...widget.spec,
      _AppletCatalogSyncMetadata.specKey: stampedCatalog.toJson(),
      'cloud': AgentGameCloudMetadata(
        gameId: previous.gameId,
        revisionNo: previous.revisionNo,
        sourceSha256: previous.sourceSha256,
        syncState: AgentGameSyncState.pending,
        scopeKey: scopeKey,
        hasPublished: previous.hasPublished,
        publishedRevisionNo: previous.publishedRevisionNo,
        publishedSourceSha256: previous.publishedSourceSha256,
        shareUrl: previous.shareUrl,
        syncedAt: previous.syncedAt,
        error: previous.error,
      ).toJson(),
    };
  }

  _AppletCatalogSyncMetadata _newCatalogMetadata(AgentWidget widget) {
    final localeOverride = _catalogLocaleOverride?.call().trim();
    final registeredLocale = appServices.isRegistered<LocaleConfigService>()
        ? switch (appServices.find<LocaleConfigService>().resolvedAppLocale) {
            AppLocale.zh => 'zh-CN',
            AppLocale.en || AppLocale.system => 'en-US',
          }
        : null;
    final locale = _AppletCatalogSyncMetadata.validLocale(
      localeOverride ?? registeredLocale ?? 'und',
    );
    return _AppletCatalogSyncMetadata(
      summary: _catalogText(widget.subtitle, maxLength: 300, fallback: ''),
      locale: locale,
    );
  }

  bool isVisibleToCurrentAccount(AgentWidget widget) {
    if (!isCloudAppletWidget(widget)) return true;
    final metadata = AgentGameCloudMetadata.fromSpec(widget.spec['cloud']);
    if (metadata.scopeKey.isEmpty) return metadata.gameId.isEmpty;
    try {
      return metadata.scopeKey == _currentScopeKey();
    } catch (_) {
      return false;
    }
  }

  void _verifyMetadataScope(
    AgentGameCloudMetadata metadata,
    String expectedScope,
  ) {
    if (metadata.scopeKey.isEmpty) {
      if (metadata.gameId.isNotEmpty) {
        throw StateError('Agent game cloud ownership is unknown');
      }
      return;
    }
    if (metadata.scopeKey != expectedScope) {
      throw StateError('Agent game belongs to another account or environment');
    }
  }

  String _currentScopeKey() {
    final override = _accountScopeOverride;
    if (override != null) {
      final value = override().trim();
      if (value.isEmpty) throw StateError('Agent game account scope is empty');
      return value;
    }
    if (!appServices.isRegistered<AuthSessionService>()) {
      throw StateError('Sign in is required to sync Agent games');
    }
    final accountUuid = appServices
        .find<AuthSessionService>()
        .session
        .value
        ?.accountUuid
        .trim();
    if (accountUuid == null || accountUuid.isEmpty) {
      throw StateError('Sign in is required to sync Agent games');
    }
    return '${_baseUri().origin}|$accountUuid';
  }

  Future<Map<String, Object?>> _request(
    Uri uri, {
    required Map<String, Object?> body,
    required String scopeKey,
    bool mapPublicationUnavailable = false,
  }) async {
    if (localEdition) {
      final result = await _local.mutateGame(
        uri,
        body,
        expectedScope: scopeKey,
      );
      if (_currentScopeKey() != scopeKey) {
        throw StateError('applet_request_context_changed');
      }
      return result;
    }
    final token = await _accessToken(scopeKey);
    late final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode(body),
          )
          .timeout(_requestTimeout);
      if (_currentScopeKey() != scopeKey) {
        throw StateError('Agent game account changed during the request');
      }
    } catch (error, stackTrace) {
      ServerRequestFailureLog.transport(
        source: 'AgentGameCloud',
        method: 'POST',
        uri: uri,
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    try {
      final decoded = response.body.trim().isEmpty
          ? const <String, Object?>{}
          : jsonDecode(response.body);
      if (decoded is! Map) {
        throw StateError('Agent game cloud response is invalid');
      }
      final envelope = Map<String, Object?>.from(decoded);
      final code = envelope['code']?.toString().trim() ?? '';
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          (code.isNotEmpty && code != 'OK')) {
        final message = envelope['message']?.toString().trim() ?? '';
        if (response.statusCode == 409) {
          throw const AppletVersionConflictException();
        }
        if (response.statusCode == 429 &&
            code == 'RATE_LIMITED' &&
            message == 'agent game storage quota exceeded') {
          throw const AppletQuotaExceededException();
        }
        if (mapPublicationUnavailable &&
            response.statusCode == 503 &&
            (code == 'PUBLICATION_UNAVAILABLE' ||
                code == 'SERVICE_UNAVAILABLE' ||
                code == 'UNAVAILABLE')) {
          throw const AppletPublicationUnavailableException();
        }
        throw StateError(
          message.isEmpty
              ? 'Agent game cloud request failed: HTTP ${response.statusCode}'
              : message,
        );
      }
      final data = envelope['data'];
      if (data is! Map) {
        throw StateError('Agent game cloud response data is invalid');
      }
      return Map<String, Object?>.from(data);
    } catch (error, stackTrace) {
      ServerRequestFailureLog.response(
        source: 'AgentGameCloud',
        method: 'POST',
        uri: uri,
        statusCode: response.statusCode,
        responseBody: response.body,
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<String> _accessToken(String expectedScope) async {
    final override = _accessTokenOverride;
    if (override != null) {
      if (_currentScopeKey() != expectedScope) {
        throw StateError('Agent game account changed during the request');
      }
      return override();
    }
    final auth = appServices.find<AuthSessionService>();
    final current = auth.session.value;
    if (current != null && current.isValid) {
      if (_currentScopeKey() != expectedScope) {
        throw StateError('Agent game account changed during the request');
      }
      return current.accessToken;
    }
    final restored = await auth.restoreOrRefresh();
    final refreshed = auth.session.value;
    if (!restored || refreshed == null || !refreshed.isValid) {
      throw StateError('Sign in is required to sync Agent games');
    }
    if (_currentScopeKey() != expectedScope) {
      throw StateError('Agent game account changed during the request');
    }
    return refreshed.accessToken;
  }

  String _publicShareUrl(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    final trustedOrigin = _baseUri();
    final resolved = trustedOrigin.resolve(value);
    if (value.isEmpty ||
        resolved.scheme != 'https' ||
        resolved.userInfo.isNotEmpty ||
        resolved.fragment.isNotEmpty ||
        resolved.query.isNotEmpty ||
        resolved.origin != trustedOrigin.origin ||
        !resolved.path.startsWith('/g/') ||
        resolved.pathSegments.length != 2 ||
        resolved.pathSegments.last.trim().isEmpty) {
      throw StateError('Published Agent game share URL is invalid');
    }
    return resolved.toString();
  }

  String _requiredString(
    Map<String, Object?> data,
    String key, {
    String fallback = '',
  }) {
    final value = data[key]?.toString().trim() ?? fallback.trim();
    if (value.isEmpty) {
      throw StateError('Agent game response is missing $key');
    }
    return value;
  }

  int _positiveInt(Object? raw, String key, {int fallback = 0}) {
    final value = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '') ?? fallback;
    if (value <= 0) {
      throw StateError('Agent game response is missing $key');
    }
    return value;
  }

  int _optionalPositiveInt(Object? raw, {int fallback = 0}) {
    final value = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '') ?? fallback;
    return value > 0 ? value : 0;
  }

  String _optionalString(Object? raw, {String fallback = ''}) {
    final value = raw?.toString().trim() ?? '';
    return value.isNotEmpty ? value : fallback.trim();
  }

  String _boundedError(Object error) {
    final normalized = error
        .toString()
        .replaceFirst('Bad state: ', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return String.fromCharCodes(normalized.runes.take(240));
  }

  @override
  void onClose() {
    _authSessionWorker?.dispose();
    _environmentWorker?.dispose();
    _retryTimer?.cancel();
    if (_ownsClient) _http.close();
    super.onClose();
  }
}

void scheduleAgentGameCloudSync(AgentWidget widget) {
  if (!isCloudAppletWidget(widget)) return;
  if (!appServices.isRegistered<AgentGameCloudService>()) return;
  unawaited(
    appServices.find<AgentGameCloudService>().schedulePrivateSync(widget),
  );
}

Future<void> syncNewAppletBeforePresent(AgentWidget widget) async {
  if (!isCloudAppletWidget(widget)) return;
  final scopeKey = AppletLocalOwnership.storedScopeKey(widget);
  if (scopeKey == AppletLocalOwnership.deviceLegacyScope) {
    scheduleAgentGameCloudSync(widget);
    return;
  }
  if (!appServices.isRegistered<AgentGameCloudService>()) {
    if (AppletLocalOwnership.currentScopeKey() != scopeKey) {
      throw StateError('applet_request_context_changed');
    }
    // Cloud availability is independent of an owned offline project's native
    // validation and local save. A later cloud action still enforces its quota.
    return;
  }
  await appServices.find<AgentGameCloudService>().syncNewBeforePresent(widget);
}

void stampAgentGameCloudOwnership(
  AgentWidget widget, {
  String? expectedScopeKey,
}) {
  if (!isCloudAppletWidget(widget)) return;
  if (!appServices.isRegistered<AgentGameCloudService>()) return;
  try {
    appServices.find<AgentGameCloudService>().stampLocalOwnership(
      widget,
      expectedScopeKey: expectedScopeKey,
    );
  } catch (error) {
    debugPrint('[AgentGameCloud] local ownership not stamped: $error');
  }
}

bool isAgentGameWidget(AgentWidget widget) =>
    widget.isSurface && widget.spec['experienceType'] == 'game';

bool isCloudAppletWidget(AgentWidget widget) {
  if (!widget.isSurface) {
    return false;
  }
  final experienceType = widget.spec['experienceType'];
  if (experienceType != 'utility' && experienceType != 'game') return false;
  final rendering = widget.spec['rendering'];
  if (rendering == 'workerCanvas') return true;
  if (rendering != 'webApp') return false;
  return _isPublicSafeWebApplet(widget);
}

bool _isPublicSafeWebApplet(AgentWidget widget) {
  try {
    final title = widget.title.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (title.isEmpty) return false;
    final projectJson = Map<String, Object?>.from(widget.spec);
    projectJson['id'] = (projectJson['surfaceId'] ?? projectJson['id'] ?? '')
        .toString();
    projectJson['title'] = title;
    projectJson['kind'] =
        projectJson['surfaceKind'] ??
        projectJson['surface'] ??
        projectJson['kind'];
    final project = SurfaceProject.fromJson(projectJson);
    return project.rendering == SurfaceRendering.webApp &&
        SurfaceProjectValidator.diagnoseForPublicApplet(project).isEmpty;
  } catch (_) {
    return false;
  }
}

String canonicalAgentGameSourceSha256(Map<String, Object?> source) {
  final canonical = jsonEncode(
    _canonicalizeAgentGameValue(source),
  ).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');
  return sha256.convert(utf8.encode(canonical)).toString();
}

Object? _canonicalizeAgentGameValue(Object? value) {
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList()
          ..sort((left, right) => left.key.compareTo(right.key));
    return <String, Object?>{
      for (final entry in entries)
        entry.key: _canonicalizeAgentGameValue(entry.value),
    };
  }
  if (value is List) {
    return value.map(_canonicalizeAgentGameValue).toList(growable: false);
  }
  return value;
}

class _AgentGameSnapshot {
  const _AgentGameSnapshot({
    required this.clientSurfaceId,
    required this.title,
    required this.experienceType,
    required this.scopeKey,
    required this.sourceSha256,
    required this.surface,
    required this.catalogMetadata,
    required this.localVersionId,
  });

  final String clientSurfaceId;
  final String title;
  final String experienceType;
  final String scopeKey;
  final String sourceSha256;
  final Map<String, Object?> surface;
  final _AppletCatalogSyncMetadata? catalogMetadata;
  final String localVersionId;
}

class _AgentGameDeleteIntent {
  const _AgentGameDeleteIntent({
    required this.scopeKey,
    required this.clientSurfaceId,
  });

  static const String specKey = 'cloudDelete';
  static const int schemaVersion = 1;

  final String scopeKey;
  final String clientSurfaceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'scopeKey': scopeKey,
    'clientSurfaceId': clientSurfaceId,
  };

  static _AgentGameDeleteIntent? fromSpec(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) throw StateError('Applet delete tombstone is invalid');
    final json = raw.map((key, value) => MapEntry(key.toString(), value));
    const expected = <String>{'schemaVersion', 'scopeKey', 'clientSurfaceId'};
    if (json.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(json.keys.toSet()).isNotEmpty ||
        json['schemaVersion'] != schemaVersion) {
      throw StateError('Applet delete tombstone is invalid');
    }
    final scopeKey = _boundedDeleteValue(json['scopeKey'], maxLength: 512);
    final clientSurfaceId = _boundedDeleteValue(
      json['clientSurfaceId'],
      maxLength: 160,
    );
    _validateClientSurfaceId(clientSurfaceId);
    return _AgentGameDeleteIntent(
      scopeKey: scopeKey,
      clientSurfaceId: clientSurfaceId,
    );
  }

  static String _boundedDeleteValue(Object? raw, {required int maxLength}) {
    if (raw is! String) {
      throw StateError('Applet delete tombstone is invalid');
    }
    final value = raw.trim();
    if (value.isEmpty ||
        value.runes.length > maxLength ||
        RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) {
      throw StateError('Applet delete tombstone is invalid');
    }
    return value;
  }
}

String _validateClientSurfaceId(String value) {
  if (!_clientSurfaceIdPattern.hasMatch(value)) {
    throw StateError('Applet client surface id is invalid');
  }
  return value;
}

class _AppletCatalogSyncMetadata {
  const _AppletCatalogSyncMetadata({
    required this.summary,
    required this.locale,
  });

  static const String specKey = 'appletCatalog';

  final String summary;
  final String locale;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 2,
    'summary': summary,
    'locale': locale,
  };

  static _AppletCatalogSyncMetadata? fromSpec(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) throw StateError('Applet catalog metadata is invalid');
    final json = raw.map((key, value) => MapEntry(key.toString(), value));
    final version = json['schemaVersion'];
    final expected = version == 1
        ? const <String>{
            'schemaVersion',
            'summary',
            'authorDisplayName',
            'locale',
          }
        : const <String>{'schemaVersion', 'summary', 'locale'};
    if ((version != 1 && version != 2) ||
        json.keys.toSet().difference(expected).isNotEmpty ||
        expected.difference(json.keys.toSet()).isNotEmpty) {
      throw StateError('Applet catalog metadata is invalid');
    }
    if (version == 1) {
      _catalogText(
        json['authorDisplayName'],
        maxLength: 120,
        fallback: 'Agent',
      );
    }
    return _AppletCatalogSyncMetadata(
      summary: _catalogText(json['summary'], maxLength: 300, fallback: ''),
      locale: validLocale(json['locale']),
    );
  }

  static String validLocale(Object? raw) {
    final value = raw is String ? raw.trim() : '';
    if (value != 'und' && value != 'en-US' && value != 'zh-CN') {
      throw StateError('Applet catalog locale is invalid');
    }
    return value;
  }
}

String _catalogText(
  Object? raw, {
  required int maxLength,
  required String fallback,
}) {
  final value = raw is String ? raw.replaceAll(RegExp(r'\s+'), ' ').trim() : '';
  if (value.isEmpty) return fallback;
  if (value.runes.length > maxLength ||
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(value)) {
    throw StateError('Applet catalog text is invalid');
  }
  return value;
}
