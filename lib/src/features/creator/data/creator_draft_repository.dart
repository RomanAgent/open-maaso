import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/creator/domain/creator_draft.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:sembast/sembast.dart';

class CreatorScopeChangedException implements Exception {
  const CreatorScopeChangedException();

  @override
  String toString() => 'creator_scope_changed';
}

class CreatorDraftRepository extends AppService {
  CreatorDraftRepository({
    DBService? database,
    AppEnvironmentService? environment,
    AuthSessionService? auth,
    String? mountedScopeKey,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent,
       _mountedScopeKey = mountedScopeKey,
       _database = database ?? appServices.find<DBService>(),
       _environment = environment ?? appServices.find<AppEnvironmentService>(),
       _auth = auth ?? appServices.find<AuthSessionService>();

  static final StoreRef<String, Map<String, Object?>> _store =
      StoreRef<String, Map<String, Object?>>('creator_drafts.v1');

  final bool Function()? _isCurrent;
  final String? _mountedScopeKey;
  final DBService _database;
  final AppEnvironmentService _environment;
  final AuthSessionService _auth;

  String get currentScopeKey {
    final account = _auth.session.value?.accountUuid.trim();
    return '${_environment.environment.value.key}|'
        '${account == null || account.isEmpty ? 'deviceLegacy' : account}';
  }

  Future<List<CreatorDraft>> list() async {
    final expectedScope = currentScopeKey;
    _guard(expectedScope);
    final snapshots = await _store.find(
      _database.raw,
      finder: Finder(
        filter: Filter.equals('scopeKey', expectedScope),
        sortOrders: <SortOrder>[SortOrder('updatedAt', false)],
      ),
    );
    _guard(expectedScope);
    final drafts = <CreatorDraft>[];
    for (final snapshot in snapshots) {
      try {
        final draft = CreatorDraft.fromJson(snapshot.value);
        if (draft.scopeKey == expectedScope) drafts.add(draft);
      } catch (_) {
        // A damaged draft is isolated instead of hiding valid creator work.
      }
    }
    return List<CreatorDraft>.unmodifiable(drafts);
  }

  Future<CreatorDraft?> get(String id) async {
    final expectedScope = currentScopeKey;
    _guard(expectedScope);
    final raw = await _store.record(id).get(_database.raw);
    _guard(expectedScope);
    if (raw == null) return null;
    final draft = CreatorDraft.fromJson(raw);
    return draft.scopeKey == expectedScope ? draft : null;
  }

  Future<void> save(CreatorDraft draft) async {
    final expectedScope = currentScopeKey;
    _guard(expectedScope);
    if (draft.scopeKey != expectedScope) {
      throw const CreatorScopeChangedException();
    }
    await _database.raw.transaction((transaction) async {
      _guard(expectedScope);
      await _store.record(draft.id).put(transaction, draft.toJson());
      _guard(expectedScope);
    });
    _guard(expectedScope);
  }

  Future<void> delete(String id) async {
    final expectedScope = currentScopeKey;
    _guard(expectedScope);
    await _database.raw.transaction((transaction) async {
      _guard(expectedScope);
      final raw = await _store.record(id).get(transaction);
      _guard(expectedScope);
      if (raw == null) return;
      final draft = CreatorDraft.fromJson(raw);
      if (draft.scopeKey != expectedScope) {
        throw const CreatorScopeChangedException();
      }
      await _store.record(id).delete(transaction);
      _guard(expectedScope);
    });
    _guard(expectedScope);
  }

  /// Apply only to the unchanged source, inside the account DB transaction.
  /// A draft edited/deleted while the preview was loading cannot be overwritten.
  Future<CreatorDraft> applyTaskImage({
    required String draftId,
    required String expectedFingerprint,
    required String expectedApplicationRevision,
    required CreatorAssetRef asset,
    required bool Function() canContinue,
  }) async {
    final scope = currentScopeKey;
    _guard(scope);
    final applied = await _database.raw.transaction((tx) async {
      _guard(scope);
      if (!canContinue()) throw const CreatorScopeChangedException();
      final raw = await _store.record(draftId).get(tx);
      _guard(scope);
      if (!canContinue()) throw const CreatorScopeChangedException();
      if (raw == null) throw StateError('creator_draft_changed');
      final current = CreatorDraft.fromJson(raw);
      if (current.scopeKey != scope ||
          creatorDraftTaskFingerprint(current) != expectedFingerprint ||
          creatorDraftApplicationRevision(current) !=
              expectedApplicationRevision) {
        throw StateError('creator_draft_changed');
      }
      final next = current.copyWith(
        status: CreatorDraftStatus.ready,
        asset: asset,
        updatedAt: DateTime.now(),
      );
      await _store.record(draftId).put(tx, next.toJson());
      _guard(scope);
      if (!canContinue()) throw const CreatorScopeChangedException();
      return next;
    });
    _guard(scope);
    if (!canContinue()) throw const CreatorScopeChangedException();
    return applied;
  }

  void _guard(String expectedScope) {
    if (isClosed ||
        _isCurrent?.call() == false ||
        currentScopeKey != expectedScope ||
        (_mountedScopeKey != null && expectedScope != _mountedScopeKey)) {
      throw const CreatorScopeChangedException();
    }
  }
}
