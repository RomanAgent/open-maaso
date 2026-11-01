import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast.dart';

import 'package:maaso/src/core/models/agent_moment.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/milestone.dart';
import 'package:maaso/src/core/models/relationship_state.dart';

import 'persistence/account_storage_scope_service.dart';
import 'persistence/app_database_opener.dart';

class _ConversationPublicationCancelled implements Exception {
  const _ConversationPublicationCancelled();
}

/// Trusted native publication work committed atomically with one chat row.
/// Implementations must bind the same account Database; this is never model JSON.
abstract interface class ConversationPublicationTransaction {
  Future<T> trackPublication<T>(Future<T> Function() operation);
  bool usesDatabase(Database database);
  Future<ChatMessage?> findExisting(
    Transaction transaction,
    ChatMessage proposed,
  );
  Future<void> commit(
    Transaction transaction,
    ChatMessage committed, {
    required bool Function() mayPublish,
  });
}

/// Sembast-backed persistence.
///
/// We use three stores:
/// * [_agents] : String-keyed by `userId` — only one record per agent ID, so
///   no unique-index dance needed (writing the same key just overwrites).
/// * [_messages] : Auto-int keyed; queries filter by sessionId + sort by ts.
/// * [_moments]  : Auto-int keyed; queries sort by timestamp desc.
class DBService extends AppService {
  DBService({Future<void> Function(Database database)? closeDatabase})
    : _closeDatabaseHandle = closeDatabase ?? _closeSembastDatabase;

  static Future<void> _closeSembastDatabase(Database database) =>
      database.close();

  final Future<void> Function(Database database) _closeDatabaseHandle;
  Database? _database;
  Future<Database>? _databaseFuture;
  Future<void>? _closeFuture;
  bool _databaseClosed = false;
  bool _databaseCloseCompleted = false;

  static final _agents = StoreRef<String, Map<String, Object?>>('agents');
  static final _messages = intMapStoreFactory.store('chat_messages');
  static final _conversationTurnSeals = StoreRef<String, bool>(
    'conversation_turn_seals',
  );
  static final _moments = intMapStoreFactory.store('moments');
  static final _widgets = intMapStoreFactory.store('agent_widgets');
  static final _agentPresence = StoreRef<String, Map<String, Object?>>(
    'agent_presence',
  );
  // Relationship: single record keyed 'self' (like _agents).  Milestones:
  // auto-int keyed, append-only, sorted by `when` desc on read.
  static final _relationship = StoreRef<String, Map<String, Object?>>(
    'relationship',
  );
  static final _milestones = intMapStoreFactory.store('milestones');

  Future<DBService> init({
    DatabaseFactory? factory,
    String? path,
    AccountStorageScope? scope,
  }) async {
    if (_databaseClosed) {
      throw StateError('DBService is closed');
    }
    _databaseFuture ??= factory != null
        ? factory.openDatabase(path ?? 'maaso_test.db')
        : scope == null
        ? openDefaultAppDatabase()
        : openScopedAppDatabase(scope);
    final database = await _databaseFuture!;
    if (_databaseClosed) {
      throw StateError('DBService is closed');
    }
    _database = database;
    return this;
  }

  Database get _db {
    if (_databaseClosed) {
      throw StateError('DBService is closed');
    }
    return _database ?? (throw StateError('DBService is not initialized'));
  }

  Database get raw => _db;

  /// Closes the owned Sembast handle exactly once.
  ///
  /// Account lifecycle coordination must await this after every service that
  /// can still issue persistence work has drained.
  Future<void> close() {
    if (_databaseCloseCompleted) return Future<void>.value();
    final inFlight = _closeFuture;
    if (inFlight != null) return inFlight;

    _databaseClosed = true;
    final operation = _closeDatabase();
    _closeFuture = operation;
    operation.then<void>(
      (_) => _databaseCloseCompleted = true,
      onError: (Object _, StackTrace _) {
        if (identical(_closeFuture, operation)) _closeFuture = null;
      },
    );
    return operation;
  }

  Future<void> _closeDatabase() async {
    final opening = _databaseFuture;
    if (opening == null) return;
    final database = await opening;
    await _closeDatabaseHandle(database);
  }

  @override
  void onClose() {
    // AppLifecycle is synchronous. Production account teardown explicitly
    // awaits close(); this remains a best-effort safety net for legacy paths.
    unawaited(close());
    super.onClose();
  }

  // ——————————————————— AgentProfile ———————————————————

  /// Upsert by `userId`.  Since the store is keyed by userId, this naturally
  /// overwrites any existing record without needing a unique-index hack.
  Future<void> saveAgentProfile(AgentProfile profile) async {
    await _agents.record(profile.userId).put(_db, profile.toJson());
  }

  Future<AgentProfile?> getSelfProfile() async {
    final json = await _agents.record('self').get(_db);
    if (json == null) {
      final records = await _agents.find(_db, finder: Finder(limit: 1));
      if (records.isEmpty) return null;
      final migrated = AgentProfile.fromJson(records.first.value);
      migrated.userId = 'self';
      await saveAgentProfile(migrated);
      return migrated;
    }
    return AgentProfile.fromJson(json);
  }

  Future<AgentProfile?> getProfile(String userId) async {
    final json = await _agents.record(userId).get(_db);
    if (json == null) return null;
    return AgentProfile.fromJson(json);
  }

  // ——————————————————— AgentPresence ———————————————————

  Future<Map<String, Object?>?> getAgentPresenceState(String agentId) async {
    return _agentPresence.record(agentId).get(_db);
  }

  Future<void> saveAgentPresenceState(
    String agentId,
    Map<String, Object?> snapshot,
  ) async {
    await _agentPresence.record(agentId).put(_db, snapshot);
  }

  // ——————————————————— Relationship & Milestones ———————————————————

  /// The single user↔agent relationship record, or null on first launch.
  Future<RelationshipState?> getRelationship() async {
    final json = await _relationship.record('self').get(_db);
    if (json == null) return null;
    return RelationshipState.fromJson(json);
  }

  Future<void> saveRelationship(RelationshipState state) async {
    await _relationship.record('self').put(_db, state.toJson());
  }

  /// Append a milestone; returns the assigned record key.
  Future<int> addMilestone(Milestone m) async {
    final key = await _milestones.add(_db, m.toJson());
    m.id = key;
    return key;
  }

  /// Most-recent milestones first.
  Future<List<Milestone>> getMilestones({int limit = 100}) async {
    final finder = Finder(sortOrders: [SortOrder('when', false)], limit: limit);
    final records = await _milestones.find(_db, finder: finder);
    return records.map((r) => Milestone.fromJson(r.value, id: r.key)).toList();
  }

  // ——————————————————— ChatMessage ———————————————————

  /// Append a message; returns the assigned record key.
  Future<int> saveChatMessage(ChatMessage message) async {
    final key = await _messages.add(_db, message.toJson());
    message.id = key;
    return key;
  }

  /// A relay retry keeps its stable user/assistant identity on both devices.
  Future<ChatMessage> saveRelayedChatMessage(
    ChatMessage message, {
    void Function()? onInserted,
  }) async {
    final snapshot = ChatMessage.fromJson(message.toJson());
    final identity = snapshot.idempotencyKey;
    final role = snapshot.isUserMessage ? 'user' : 'assistant';
    if (snapshot.turnId == null ||
        !RegExp(
          r'^runtime-chat:[A-Za-z0-9._:-]{8,96}$',
        ).hasMatch(snapshot.turnId!) ||
        identity != '${snapshot.turnId}:$role' ||
        snapshot.sessionId != 'self' ||
        snapshot.senderId != (snapshot.isUserMessage ? 'user' : 'self') ||
        snapshot.receiverId != (snapshot.isUserMessage ? 'self' : 'user') ||
        snapshot.turnOrigin != ChatMessageTurnOrigins.user ||
        snapshot.outreachId != null ||
        (snapshot.content.trim().isEmpty && snapshot.attachments.isEmpty) ||
        (snapshot.isUserMessage
            ? snapshot.utteranceId != null ||
                  snapshot.sequence != null ||
                  snapshot.deliveryStatus != null
            : snapshot.utteranceId != 'reply' ||
                  snapshot.sequence != 0 ||
                  snapshot.deliveryStatus != 'published')) {
      throw ArgumentError('Invalid relayed chat message');
    }
    var inserted = false;
    final result = await _db.transaction((transaction) async {
      final previous = await _messages.findFirst(
        transaction,
        finder: Finder(
          filter: Filter.and([
            Filter.equals('sessionId', snapshot.sessionId),
            Filter.equals('idempotencyKey', identity),
          ]),
        ),
      );
      if (previous != null) {
        final stored = ChatMessage.fromJson(previous.value, id: previous.key);
        final storedWire = stored.toJson()..remove('timestamp');
        final incomingWire = snapshot.toJson()..remove('timestamp');
        // A source draft and its canonical server row may have different clocks.
        // All authorship, delivery and content fields must still agree.
        if (jsonEncode(storedWire) != jsonEncode(incomingWire)) {
          throw StateError('Relayed message identity has conflicting content');
        }
        return stored;
      }
      final key = await _messages.add(transaction, snapshot.toJson());
      inserted = true;
      return ChatMessage.fromJson(snapshot.toJson(), id: key);
    });
    if (inserted) onInserted?.call();
    return result;
  }

  /// Imports one authenticated online event using a portable event identity.
  /// Authority and attachment transfer are verified by LiveCompanionSyncService.
  Future<ChatMessage> saveOnlineChatMessage(
    ChatMessage message, {
    required bool Function() isCurrent,
    void Function()? onInserted,
  }) async {
    final snapshot = ChatMessage.fromJson(message.toJson());
    if (!RegExp(
          r'^live-sync:[A-Za-z0-9._:-]{8,64}$',
        ).hasMatch(snapshot.idempotencyKey ?? '') ||
        snapshot.sessionId != 'self' ||
        !snapshot.isModelContextEligible ||
        snapshot.senderId != (snapshot.isUserMessage ? 'user' : 'self') ||
        snapshot.receiverId != (snapshot.isUserMessage ? 'self' : 'user') ||
        snapshot.content.trim().isEmpty && snapshot.attachments.isEmpty) {
      throw const FormatException('invalid_online_message');
    }
    var inserted = false;
    final result = await _db.transaction((tx) async {
      if (!isCurrent()) throw StateError('online_chat_account_changed');
      final existing = await _messages.findFirst(
        tx,
        finder: Finder(
          filter: Filter.equals('idempotencyKey', snapshot.idempotencyKey),
        ),
      );
      if (!isCurrent()) throw StateError('online_chat_account_changed');
      if (existing != null) {
        if (jsonEncode(existing.value) != jsonEncode(snapshot.toJson())) {
          throw const FormatException('online_chat_identity_conflict');
        }
        return ChatMessage.fromJson(existing.value, id: existing.key);
      }
      final key = await _messages.add(tx, snapshot.toJson());
      if (!isCurrent()) throw StateError('online_chat_account_changed');
      inserted = true;
      return ChatMessage.fromJson(snapshot.toJson(), id: key);
    });
    if (inserted && isCurrent()) onInserted?.call();
    return result;
  }

  /// Looks up a published identity without loading the conversation history.
  /// Callers can preserve its original wording/locale when a workflow resumes.
  Future<ChatMessage?> findConversationUtterance({
    required String sessionId,
    required String turnId,
    required String utteranceId,
  }) async {
    final record = await _messages.findFirst(
      _db,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('sessionId', sessionId),
          Filter.equals('turnId', turnId),
          Filter.equals('utteranceId', utteranceId),
        ]),
      ),
    );
    return record == null
        ? null
        : ChatMessage.fromJson(record.value, id: record.key);
  }

  /// Commits one visible assistant utterance once per session/turn/utterance ID.
  ///
  /// The returned row is detached from mutable caller input. Exact retries
  /// return its existing record; conflicting retries throw. A sealed turn or
  /// lost ownership returns null, including retries of an already committed row.
  /// Ordinary [saveChatMessage] intentionally remains an unconditional append.
  Future<ChatMessage?> publishConversationUtterance(
    ChatMessage message, {
    bool Function()? shouldContinue,
    ConversationPublicationTransaction? publication,
  }) {
    Future<ChatMessage?> operation() => _publishConversationUtterance(
      message,
      shouldContinue: shouldContinue,
      publication: publication,
    );
    return publication == null
        ? operation()
        : publication.trackPublication(operation);
  }

  Future<ChatMessage?> _publishConversationUtterance(
    ChatMessage message, {
    bool Function()? shouldContinue,
    ConversationPublicationTransaction? publication,
  }) async {
    if (publication != null && !publication.usesDatabase(_db)) {
      throw StateError('conversation_publication_database_mismatch');
    }
    final snapshot = ChatMessage.fromJson(message.toJson());
    if (shouldContinue != null && !shouldContinue()) return null;
    _validateConversationUtterance(snapshot);
    final wire = snapshot.toJson();
    final sealKey = _conversationTurnKey(snapshot.sessionId, snapshot.turnId!);

    void requireOwnership() {
      if (shouldContinue != null && !shouldContinue()) {
        throw const _ConversationPublicationCancelled();
      }
    }

    try {
      return await _db.transaction((transaction) async {
        requireOwnership();
        final sealed = await _conversationTurnSeals
            .record(sealKey)
            .get(transaction);
        requireOwnership();
        if (sealed == true) return null;
        if (publication != null) {
          final committed = await publication.findExisting(
            transaction,
            snapshot,
          );
          requireOwnership();
          if (committed != null) return committed;
        }

        final existing = await _messages.findFirst(
          transaction,
          finder: Finder(
            filter: Filter.and([
              Filter.equals('sessionId', snapshot.sessionId),
              Filter.equals('turnId', snapshot.turnId),
              Filter.equals('utteranceId', snapshot.utteranceId),
            ]),
          ),
        );
        requireOwnership();
        if (existing != null) {
          final stored = ChatMessage.fromJson(existing.value, id: existing.key);
          if (!_sameConversationUtterance(stored.toJson(), wire)) {
            throw StateError(
              'Conversation utterance identity already committed',
            );
          }
          if (publication != null) {
            await publication.commit(
              transaction,
              stored,
              mayPublish: () => shouldContinue?.call() ?? true,
            );
            requireOwnership();
          }
          return stored;
        }

        final key = await _messages.add(transaction, wire);
        // Throwing here rolls the write back when cancellation arrives while
        // Sembast is awaiting the append. Storage and unexpected errors escape.
        requireOwnership();
        final committed = ChatMessage.fromJson(wire, id: key);
        if (publication != null) {
          await publication.commit(
            transaction,
            committed,
            mayPublish: () => shouldContinue?.call() ?? true,
          );
          requireOwnership();
        }
        return committed;
      });
    } on _ConversationPublicationCancelled {
      return null;
    }
  }

  /// Durably prevents further publications from an ended or interrupted turn.
  Future<void> sealConversationTurn({
    required String sessionId,
    required String turnId,
  }) async {
    if (sessionId.trim().isEmpty || turnId.trim().isEmpty) {
      throw ArgumentError('Conversation seal requires sessionId and turnId');
    }
    final key = _conversationTurnKey(sessionId, turnId.trim());
    await _db.transaction((transaction) async {
      await _conversationTurnSeals.record(key).put(transaction, true);
    });
  }

  static String _conversationTurnKey(String sessionId, String turnId) =>
      jsonEncode([sessionId, turnId]);

  static void _validateConversationUtterance(ChatMessage message) {
    if (message.sessionId.trim().isEmpty ||
        message.turnId == null ||
        message.utteranceId == null ||
        message.senderId.trim().isEmpty ||
        message.receiverId.trim().isEmpty ||
        (message.content.trim().isEmpty &&
            !message.attachments.any((item) => item.kind == 'image')) ||
        message.isUserMessage ||
        message.sequence == null ||
        (message.deliveryStatus != 'published' &&
            message.deliveryStatus != 'interrupted')) {
      throw ArgumentError(
        'A visible assistant utterance requires valid metadata',
      );
    }
  }

  static bool _sameConversationUtterance(
    Map<String, Object?> existing,
    Map<String, Object?> retry,
  ) {
    // A retry may be constructed later, so its timestamp is not identity. The
    // original timestamp and record key are always returned without rewriting.
    for (final field in const [
      'sessionId',
      'senderId',
      'receiverId',
      'content',
      'isUserMessage',
      'turnOrigin',
      'idempotencyKey',
      'outreachId',
      'turnId',
      'utteranceId',
      'sequence',
      'deliveryStatus',
      'attachments',
      'appletReference',
      'invocationReference',
      'taskReference',
      'visualContext',
    ]) {
      if (!_samePublicationValue(existing[field], retry[field])) return false;
    }
    return true;
  }

  static bool _samePublicationValue(Object? a, Object? b) {
    if (a is List && b is List) {
      return a.length == b.length &&
          a.indexed.every(
            (entry) => _samePublicationValue(entry.$2, b[entry.$1]),
          );
    }
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every(
            (key) =>
                b.containsKey(key) && _samePublicationValue(a[key], b[key]),
          );
    }
    return a == b;
  }

  /// All messages in a session, oldest first.
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    final finder = Finder(
      filter: Filter.equals('sessionId', sessionId),
      sortOrders: [
        SortOrder<Object?>.custom('timestamp', _compareChatTimestamps),
        SortOrder(Field.key),
      ],
    );
    final records = await _messages.find(_db, finder: finder);
    return records
        .map((r) => ChatMessage.fromJson(r.value, id: r.key))
        .toList();
  }

  /// Messages in [from, before), oldest first, without a tail limit.
  ///
  /// Legacy timestamps mix UTC and zone-less local ISO strings. Filtering by
  /// parsed instants preserves their existing meaning. Sembast scans the raw
  /// records, but only matching rows are decoded and sorted as chat messages.
  Future<List<ChatMessage>> getMessagesInRange(
    String sessionId, {
    required DateTime from,
    required DateTime before,
  }) async {
    if (!from.isBefore(before)) return const <ChatMessage>[];
    final records = await _messages.find(
      _db,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('sessionId', sessionId),
          Filter.custom((record) {
            final raw = record['timestamp'];
            final timestamp = raw is String ? DateTime.tryParse(raw) : null;
            return timestamp != null &&
                !timestamp.isBefore(from) &&
                timestamp.isBefore(before);
          }),
        ]),
        sortOrders: [
          SortOrder<Object?>.custom('timestamp', _compareChatTimestamps),
          SortOrder(Field.key),
        ],
      ),
    );
    return records
        .map((record) => ChatMessage.fromJson(record.value, id: record.key))
        .toList();
  }

  /// Recent N messages in a session, oldest first — avoids loading the
  /// entire history when only the tail is needed (e.g. for LLM context).
  Future<List<ChatMessage>> getRecentMessages(
    String sessionId, {
    int limit = 8,
  }) async {
    if (limit <= 0) return const <ChatMessage>[];
    final finder = Finder(
      filter: Filter.equals('sessionId', sessionId),
      sortOrders: [
        SortOrder<Object?>.custom('timestamp', _compareChatTimestamps, false),
        SortOrder(Field.key, false),
      ],
      limit: limit,
    );
    final records = await _messages.find(_db, finder: finder);
    return records.reversed
        .map((r) => ChatMessage.fromJson(r.value, id: r.key))
        .toList();
  }

  static int _compareChatTimestamps(Object? left, Object? right) {
    // Legacy rows mix local ISO strings without an offset and UTC strings.
    // Compare instants before limiting results; never rewrite those records or
    // guess an offset from the sender's role. Zone-less values retain Dart's
    // existing local-time interpretation used by ChatMessage.fromJson.
    final leftTime = left is String ? DateTime.tryParse(left) : null;
    final rightTime = right is String ? DateTime.tryParse(right) : null;
    if (leftTime == null) return rightTime == null ? 0 : -1;
    if (rightTime == null) return 1;
    return leftTime.compareTo(rightTime);
  }

  // ——————————————————— AgentMoment ———————————————————

  Future<int> saveAgentMoment(AgentMoment moment) async {
    final key = await _moments.add(_db, moment.toJson());
    moment.id = key;
    return key;
  }

  /// Newest first.
  Future<List<AgentMoment>> getAllMoments() async {
    final finder = Finder(
      sortOrders: [SortOrder('timestamp', false /* desc */)],
    );
    final records = await _moments.find(_db, finder: finder);
    return records
        .map((r) => AgentMoment.fromJson(r.value, id: r.key))
        .toList();
  }

  // ——————————————————— AgentWidget (Widget Hub) ———————————————————

  /// Persist a new widget the AI built; returns the assigned key.
  Future<int> saveAgentWidget(AgentWidget w) async {
    final key = await _widgets.add(_db, w.toJson());
    w.id = key;
    return key;
  }

  /// Atomically validates the current Widget Hub snapshot before inserting.
  ///
  /// Generated Applets use this to enforce account-scoped quota and Surface
  /// ID uniqueness even if two creation attempts overlap in one process.
  Future<int> saveAgentWidgetValidated(
    AgentWidget widget, {
    required void Function(List<AgentWidget> current) validate,
  }) async {
    final key = await _db.transaction((transaction) async {
      final records = await _widgets.find(transaction);
      final current = records
          .map((record) => AgentWidget.fromJson(record.value, id: record.key))
          .toList(growable: false);
      validate(current);
      final key = await _widgets.add(transaction, widget.toJson());
      validate(current);
      return key;
    });
    widget.id = key;
    return key;
  }

  /// Newest first; the Hub list view consumes this.
  Future<List<AgentWidget>> getAllWidgets() async {
    final finder = Finder(
      sortOrders: [SortOrder('createdAt', false /* desc */)],
    );
    final records = await _widgets.find(_db, finder: finder);
    return records
        .map((r) => AgentWidget.fromJson(r.value, id: r.key))
        .toList();
  }

  /// Mark a widget as seen so the home banner can fade.
  Future<void> markWidgetSeen(int id) async {
    await _widgets.record(id).update(_db, {'seen': true});
  }

  Future<void> markWidgetSeenValidated(
    int id, {
    required bool Function(AgentWidget current) validate,
  }) async {
    await _db.transaction((transaction) async {
      final record = _widgets.record(id);
      final raw = await record.get(transaction);
      if (raw == null) throw StateError('Widget was deleted');
      final current = AgentWidget.fromJson(raw, id: id);
      if (!validate(current)) throw StateError('Widget ownership changed');
      await record.update(transaction, const <String, Object?>{'seen': true});
      if (!validate(current)) throw StateError('Widget ownership changed');
    });
  }

  /// Update a single field inside a widget's [spec] (sembast dotted-path
  /// update, so the rest of the spec is preserved). Used to refresh a blog
  /// tile's stored `url` after the local server re-binds to a new port.
  Future<void> updateWidgetSpecField(int id, String key, Object? value) async {
    await _widgets.record(id).update(_db, {'spec.$key': value});
  }

  /// Atomically updates one generated-widget spec field after validating the
  /// exact row both before and after the write.
  Future<void> updateWidgetSpecFieldValidated(
    int id,
    String key,
    Object? value, {
    required bool Function(AgentWidget current) validate,
  }) async {
    await _db.transaction((transaction) async {
      final record = _widgets.record(id);
      final raw = await record.get(transaction);
      if (raw == null) throw StateError('Widget was deleted');
      final current = AgentWidget.fromJson(raw, id: id);
      if (!validate(current)) throw StateError('Widget ownership changed');
      final rawSpec = current.spec;
      final nextSpec = <String, Object?>{...rawSpec, key: value};
      await record.update(transaction, <String, Object?>{'spec': nextSpec});
      final updated = AgentWidget.fromJson(<String, Object?>{
        ...raw,
        'spec': nextSpec,
      }, id: id);
      if (!validate(updated)) throw StateError('Widget ownership changed');
    });
  }

  /// Patch a widget's top-level fields (title/icon) and/or replace its [spec].
  /// Used by generated surfaces to edit a saved project in place while
  /// preserving the Widget Hub record key.
  Future<void> updateWidget(
    int id, {
    String? title,
    String? icon,
    Map<String, Object?>? spec,
  }) async {
    final patch = <String, Object?>{};
    if (title != null) patch['title'] = title;
    if (icon != null) patch['icon'] = icon;
    if (spec != null) patch['spec'] = spec;
    if (patch.isEmpty) return;
    await _widgets.record(id).update(_db, patch);
  }

  /// Updates a generated Surface without allowing a stale editor snapshot to
  /// overwrite ownership, cloud sync, catalog, or deletion state.
  Future<Map<String, Object?>> updateGeneratedSurface(
    int id, {
    String? title,
    required Map<String, Object?> spec,
    String? expectedScopeKey,
    String? expectedSourceFingerprint,
    bool Function(AgentWidget current, String expectedScopeKey)? validateScope,
  }) async {
    return _db.transaction((transaction) async {
      final record = _widgets.record(id);
      final current = await record.get(transaction);
      if (current == null) throw StateError('Generated Surface was deleted');
      final currentWidget = AgentWidget.fromJson(current, id: id);
      _validateExpectedWidgetScope(
        currentWidget,
        expectedScopeKey: expectedScopeKey,
        validateScope: validateScope,
      );
      if (expectedSourceFingerprint != null &&
          surfaceVersionFingerprint(
                currentWidget.spec,
                title: currentWidget.title,
              ) !=
              expectedSourceFingerprint) {
        throw StateError('surface_version_conflict');
      }
      final rawSpec = current['spec'];
      final currentSpec = rawSpec is Map
          ? rawSpec.map((key, value) => MapEntry(key.toString(), value))
          : const <String, Object?>{};
      if (currentSpec['cloudDelete'] != null) {
        throw StateError('Applet deletion is pending');
      }
      final merged = Map<String, Object?>.from(spec);
      for (final key in const <String>{
        'appletLocal',
        'appletCatalog',
        'cloud',
        'cloudDelete',
        'versionCloudBindings',
        'versionSourceCache',
        'versionCloudIndex',
      }) {
        if (currentSpec.containsKey(key)) {
          merged[key] = currentSpec[key];
        } else {
          merged.remove(key);
        }
      }
      final patch = <String, Object?>{'spec': merged};
      if (title != null) patch['title'] = title;
      await record.update(transaction, patch);
      final updated = AgentWidget.fromJson(<String, Object?>{
        ...current,
        ...patch,
      }, id: id);
      _validateExpectedWidgetScope(
        updated,
        expectedScopeKey: expectedScopeKey,
        validateScope: validateScope,
      );
      return merged;
    });
  }

  /// Atomically merges owner-scoped cloud/version bookkeeping. The callback
  /// cannot modify executable source, title, ownership, or deletion state.
  Future<AgentWidget> updateGeneratedSurfaceMetadata(
    int id, {
    required String expectedScopeKey,
    required bool Function(AgentWidget current) validate,
    required Map<String, Object?> Function(AgentWidget current) update,
  }) => _db.transaction((transaction) async {
    final record = _widgets.record(id);
    final raw = await record.get(transaction);
    if (raw == null) throw StateError('Generated Surface was deleted');
    final current = AgentWidget.fromJson(raw, id: id);
    if (!validate(current) || current.spec['cloudDelete'] != null) {
      throw StateError('Widget ownership changed');
    }
    final changes = update(current);
    const allowed = {
      'cloud',
      'versionCloudBindings',
      'versionSourceCache',
      'versionCloudIndex',
    };
    if (changes.keys.any((key) => !allowed.contains(key))) {
      throw StateError('Invalid generated Surface metadata field');
    }
    final spec = {...current.spec, ...changes};
    await record.update(transaction, {'spec': spec});
    final updated = AgentWidget.fromJson({...raw, 'spec': spec}, id: id);
    if (!validate(updated)) throw StateError('Widget ownership changed');
    return updated;
  });

  /// Re-surface an existing widget: mark it unseen + bump its timestamp so it
  /// becomes the "latest unseen" again and the home chip pops it — used when
  /// the agent re-opens a saved widget instead of regenerating it.
  Future<void> resurfaceWidget(
    int id, {
    String? expectedScopeKey,
    bool Function(AgentWidget current, String expectedScopeKey)? validateScope,
  }) async {
    await _db.transaction((transaction) async {
      final record = _widgets.record(id);
      final raw = await record.get(transaction);
      if (raw == null) throw StateError('Widget was deleted');
      final current = AgentWidget.fromJson(raw, id: id);
      _validateExpectedWidgetScope(
        current,
        expectedScopeKey: expectedScopeKey,
        validateScope: validateScope,
      );
      final patch = <String, Object?>{
        'seen': false,
        'createdAt': DateTime.now().toIso8601String(),
      };
      await record.update(transaction, patch);
      final updated = AgentWidget.fromJson(<String, Object?>{
        ...raw,
        ...patch,
      }, id: id);
      _validateExpectedWidgetScope(
        updated,
        expectedScopeKey: expectedScopeKey,
        validateScope: validateScope,
      );
    });
  }

  Future<void> deleteWidget(int id) async {
    await _widgets.record(id).delete(_db);
  }

  Future<void> deleteWidgetValidated(
    int id, {
    required bool Function(AgentWidget current) validate,
  }) async {
    await _db.transaction((transaction) async {
      final record = _widgets.record(id);
      final raw = await record.get(transaction);
      if (raw == null) return;
      final current = AgentWidget.fromJson(raw, id: id);
      if (!validate(current)) throw StateError('Widget ownership changed');
      await record.delete(transaction);
      if (!validate(current)) throw StateError('Widget ownership changed');
    });
  }

  static void _validateExpectedWidgetScope(
    AgentWidget current, {
    required String? expectedScopeKey,
    required bool Function(AgentWidget current, String expectedScopeKey)?
    validateScope,
  }) {
    if (expectedScopeKey == null && validateScope == null) return;
    if (expectedScopeKey == null ||
        validateScope == null ||
        !validateScope(current, expectedScopeKey)) {
      throw StateError('Widget ownership changed');
    }
  }

  /// Returns the most recently created widget across all agents, or null.
  /// Used by the home screen's "AI made you something new" chip.
  Future<AgentWidget?> latestWidget() async {
    final finder = Finder(
      sortOrders: [SortOrder('createdAt', false)],
      limit: 1,
    );
    final records = await _widgets.find(_db, finder: finder);
    if (records.isEmpty) return null;
    return AgentWidget.fromJson(records.first.value, id: records.first.key);
  }

  Future<AgentWidget?> latestUnseenWidget() async {
    final finder = Finder(
      filter: Filter.equals('seen', false),
      sortOrders: [SortOrder('createdAt', false)],
      limit: 1,
    );
    final records = await _widgets.find(_db, finder: finder);
    if (records.isEmpty) return null;
    return AgentWidget.fromJson(records.first.value, id: records.first.key);
  }
}
