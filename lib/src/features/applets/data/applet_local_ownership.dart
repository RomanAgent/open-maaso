import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';

String normalizeAppletCatalogSummary(Object? raw) {
  if (raw == null) return '';
  if (raw is! String) {
    throw const FormatException('invalid_applet_summary');
  }
  final normalized = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.runes.length > 300 ||
      RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(normalized)) {
    throw const FormatException('invalid_applet_summary');
  }
  return normalized;
}

class AppletQuotaExceededException implements Exception {
  const AppletQuotaExceededException({this.limit = 5});

  final int limit;

  @override
  String toString() => 'applet_quota_reached';
}

class AppletQuotaUnavailableException implements Exception {
  const AppletQuotaUnavailableException();

  @override
  String toString() => 'applet_quota_unavailable';
}

/// Account-and-environment ownership for locally persisted generated applets.
///
/// The internal [AgentWidget] record remains unchanged for storage
/// compatibility. New records carry this metadata inside `spec`; records made
/// before the metadata existed remain device legacy and are never silently
/// assigned to whichever account signs in first.
class AppletLocalOwnership {
  const AppletLocalOwnership._();

  static const String metadataKey = 'appletLocal';
  static const String deviceLegacyScope = 'device-legacy';
  static const int schemaVersion = 1;

  static String currentScopeKey() {
    final account = appServices.isRegistered<AuthSessionService>()
        ? appServices
                  .find<AuthSessionService>()
                  .session
                  .value
                  ?.accountUuid
                  .trim() ??
              ''
        : '';
    if (account.isEmpty) return deviceLegacyScope;

    final origin = appServices.isRegistered<AppEnvironmentService>()
        ? appServices.find<AppEnvironmentService>().baseUri.origin
        : '';
    if (origin.isEmpty) return deviceLegacyScope;
    return '$origin|$account';
  }

  static void stamp(AgentWidget widget, {String? scopeKey}) {
    if (!widget.isSurface) return;
    final scope = _normalizedScope(scopeKey ?? currentScopeKey());
    widget.spec = <String, Object?>{
      ...widget.spec,
      metadataKey: <String, Object?>{
        'schemaVersion': schemaVersion,
        'scopeKey': scope,
      },
    };
  }

  static bool isVisible(AgentWidget widget, {String? scopeKey}) {
    if (!widget.isSurface) return false;
    final current = _normalizedScope(scopeKey ?? currentScopeKey());
    final stored = storedScopeKey(widget);
    return stored == current;
  }

  /// Returns an explicit scope for every record. Legacy unscoped records are
  /// device-only and therefore hidden whenever a signed-in scope is active.
  static String storedScopeKey(AgentWidget widget) {
    final local = _map(widget.spec[metadataKey]);
    final localVersion = _positiveInt(local['schemaVersion']);
    final localScope = local['scopeKey']?.toString().trim() ?? '';
    if (localVersion == schemaVersion && localScope.isNotEmpty) {
      return localScope;
    }

    // Agent Games created before the generic Applet metadata already carried
    // a trustworthy account/environment scope in their cloud metadata.
    final cloud = _map(widget.spec['cloud']);
    final cloudScope = cloud['scopeKey']?.toString().trim() ?? '';
    if (cloudScope.isNotEmpty) return cloudScope;
    return deviceLegacyScope;
  }

  static Future<int> ownedCount(DBService database, {String? scopeKey}) async {
    final current = _normalizedScope(scopeKey ?? currentScopeKey());
    final widgets = await database.getAllWidgets();
    return widgets.where((item) => isVisible(item, scopeKey: current)).length;
  }

  static Future<void> ensureCanCreate(
    DBService database, {
    String? scopeKey,
    String? existingSurfaceId,
    String? proposedSurfaceId,
  }) async {
    final current = _normalizedScope(scopeKey ?? currentScopeKey());
    if (currentScopeKey() != current) {
      throw const AppletQuotaUnavailableException();
    }
    final normalizedExisting = existingSurfaceId?.trim() ?? '';
    final normalizedProposed = proposedSurfaceId?.trim() ?? '';
    final items = await database.getAllWidgets();
    if (currentScopeKey() != current) {
      throw const AppletQuotaUnavailableException();
    }
    for (final item in items) {
      if (!isVisible(item, scopeKey: current)) continue;
      final surfaceId = item.spec['surfaceId']?.toString().trim() ?? '';
      if (normalizedExisting.isNotEmpty && surfaceId == normalizedExisting) {
        return;
      }
      if (normalizedProposed.isNotEmpty && surfaceId == normalizedProposed) {
        throw StateError('duplicate_applet_surface_id');
      }
    }
  }

  static Future<int> saveNew(
    DBService database,
    AgentWidget widget, {
    required String expectedScopeKey,
    void Function()? validateAuthority,
  }) async {
    final scope = _normalizedScope(expectedScopeKey);
    validateAuthority?.call();
    if (currentScopeKey() != scope || storedScopeKey(widget) != scope) {
      throw const AppletQuotaUnavailableException();
    }
    final proposedSurfaceId = widget.spec['surfaceId']?.toString().trim() ?? '';
    if (proposedSurfaceId.isEmpty) {
      throw StateError('missing_applet_surface_id');
    }
    final id = await database.saveAgentWidgetValidated(
      widget,
      validate: (current) {
        validateAuthority?.call();
        if (currentScopeKey() != scope) {
          throw const AppletQuotaUnavailableException();
        }
        _validateLocalSurfaceIdentity(
          localItems: current,
          scopeKey: scope,
          proposedSurfaceId: proposedSurfaceId,
        );
      },
    );
    validateAuthority?.call();
    if (currentScopeKey() != scope) {
      throw const AppletQuotaUnavailableException();
    }
    return id;
  }

  // Local authoring is independent of cloud catalog storage quotas.
  // Keep identity checks inside the database transaction for concurrent saves.
  static void _validateLocalSurfaceIdentity({
    required List<AgentWidget> localItems,
    required String scopeKey,
    required String proposedSurfaceId,
  }) {
    for (final item in localItems) {
      if (!isVisible(item, scopeKey: scopeKey)) continue;
      final surfaceId = item.spec['surfaceId']?.toString().trim() ?? '';
      if (proposedSurfaceId.isNotEmpty && surfaceId == proposedSurfaceId) {
        throw StateError('duplicate_applet_surface_id');
      }
    }
  }

  static List<Worker> watchScope(void Function() listener) {
    final workers = <Worker>[];
    if (appServices.isRegistered<AuthSessionService>()) {
      workers.add(
        ever<MaasoAuthSession?>(
          appServices.find<AuthSessionService>().session,
          (_) => listener(),
        ),
      );
    }
    if (appServices.isRegistered<AppEnvironmentService>()) {
      workers.add(
        ever<MaasoEnvironment>(
          appServices.find<AppEnvironmentService>().environment,
          (_) => listener(),
        ),
      );
    }
    return workers;
  }

  static String _normalizedScope(String value) {
    final normalized = value.trim();
    return normalized.isEmpty ? deviceLegacyScope : normalized;
  }

  static Map<String, Object?> _map(Object? raw) => raw is Map
      ? raw.map((key, value) => MapEntry(key.toString(), value))
      : const <String, Object?>{};

  static int _positiveInt(Object? raw) {
    if (raw is int) return raw > 0 ? raw : 0;
    if (raw is num) return raw.toInt() > 0 ? raw.toInt() : 0;
    final parsed = int.tryParse(raw?.toString() ?? '');
    return parsed != null && parsed > 0 ? parsed : 0;
  }
}
