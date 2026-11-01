import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/conversation_preference.dart';
import 'package:maaso/src/core/services/agent_persona_memory_store.dart';
import 'package:maaso/src/core/services/db_service.dart';

abstract interface class ConversationPreferenceStore {
  Future<Map<String, Object?>?> read();
  Future<void> write(ConversationPreferenceSnapshot value);
}

final class SembastConversationPreferenceStore
    implements ConversationPreferenceStore {
  SembastConversationPreferenceStore(
    this.database, {
    required this.accountScopeDigest,
  });
  final DBService database;
  final String accountScopeDigest;

  AgentPersonaMemoryStore get _memory => AgentPersonaMemoryStore(
    database: database.raw,
    accountScopeDigest: accountScopeDigest,
    kind: AgentPersonaMemoryKind.conversationStyle,
    legacyStoreName: 'conversation_preferences.v1',
    legacyRecordKey: accountScopeDigest,
    normalizePayload: (value) {
      final snapshot = ConversationPreferenceSnapshot.fromStorageJson(value);
      if (snapshot.accountScopeDigest != accountScopeDigest) {
        throw const FormatException('conversation memory account mismatch');
      }
      return snapshot.toStorageJson();
    },
  );

  @override
  Future<Map<String, Object?>?> read() => _memory.read();

  @override
  Future<void> write(ConversationPreferenceSnapshot value) async {
    if (value.accountScopeDigest != accountScopeDigest) {
      throw StateError('conversation_preference_account_mismatch');
    }
    await _memory.write(value.toStorageJson());
  }
}

enum _PreferenceLifecycle { created, initializing, active, degraded, retired }

/// User-owned explicit persona memories with account isolation and
/// write-before-publish state. They never create inferred memory episodes,
/// shared contexts or relationship-stage evidence.
final class ConversationPreferenceService extends AppService {
  ConversationPreferenceService({
    required ConversationPreferenceStore store,
    required this.accountScopeDigest,
  }) : _store = store,
       state = Rx(
         ConversationPreferenceSnapshot(
           accountScopeDigest: accountScopeDigest,
           humorStyle: ConversationHumorStyle.subdued,
         ),
       );

  final ConversationPreferenceStore _store;
  final String accountScopeDigest;
  final Rx<ConversationPreferenceSnapshot> state;
  _PreferenceLifecycle _lifecycle = _PreferenceLifecycle.created;
  Future<void> _tail = Future<void>.value();
  Future<void>? _initialization;

  bool get isAvailable =>
      _lifecycle == _PreferenceLifecycle.active && !isClosed;
  int get revision => state.value.revision;
  ConversationPreferenceSnapshot get effectiveSnapshot => state.value;

  Future<ConversationPreferenceService> init() async {
    if (_lifecycle != _PreferenceLifecycle.created || isClosed) {
      throw StateError('conversation_preference_already_initialized');
    }
    _lifecycle = _PreferenceLifecycle.initializing;
    _initialization = () async {
      try {
        final raw = await _store.read();
        if (_lifecycle != _PreferenceLifecycle.initializing || isClosed) return;
        final restored = raw == null
            ? ConversationPreferenceSnapshot(
                accountScopeDigest: accountScopeDigest,
              )
            : ConversationPreferenceSnapshot.fromStorageJson(raw);
        if (restored.accountScopeDigest != accountScopeDigest) {
          throw const FormatException(
            'conversation preference account mismatch',
          );
        }
        _lifecycle = _PreferenceLifecycle.active;
        state.value = restored;
      } on Object {
        if (_lifecycle == _PreferenceLifecycle.initializing) {
          _lifecycle = _PreferenceLifecycle.degraded;
        }
      }
    }();
    await _initialization;
    return this;
  }

  Future<void> setHumorStyle(ConversationHumorStyle style) => _update(
    (current) => _replace(
      current,
      humorStyle: style,
      humorStyleExplicit: true,
      banterBoundaries: {
        for (final entry in current.banterBoundaries.entries)
          if (style == ConversationHumorStyle.lightBanter ||
              entry.value != BanterDisposition.accepted)
            entry.key: entry.value,
      },
    ),
  );

  Future<void> setPreferredAddress(String? address) => _update(
    (current) =>
        _replace(current, preferredAddress: address, replaceAddress: true),
  );

  Future<void> setForbiddenAddresses(Iterable<String> addresses) {
    final captured = List<String>.of(addresses);
    return _update(
      (current) => _replace(
        current,
        forbiddenAddresses: captured,
        preferredAddress:
            captured
                .map((value) => value.trim())
                .contains(current.preferredAddress)
            ? null
            : current.preferredAddress,
        replaceAddress: true,
      ),
    );
  }

  Future<void> setBanterBoundary(String topic, BanterDisposition disposition) {
    if (!conversationBanterTopics.contains(topic)) {
      return Future.error(ArgumentError('invalid conversation topic'));
    }
    return _update(
      (current) => _replace(
        current,
        banterBoundaries: {
          for (final entry in current.banterBoundaries.entries)
            if (entry.key != topic) entry.key: entry.value,
          if (disposition != BanterDisposition.unknown) topic: disposition,
        },
      ),
    );
  }

  Future<void> setBanterBoundaries(
    Map<String, BanterDisposition> boundaries, {
    int? expectedRevision,
  }) {
    final captured = Map<String, BanterDisposition>.of(boundaries);
    return _update(
      (current) => _replace(current, banterBoundaries: captured),
      expectedRevision: expectedRevision,
    );
  }

  /// Clearing removes all choices, retaining only a monotonic invalidation revision.
  Future<void> clear() => _update(
    (current) => ConversationPreferenceSnapshot(
      accountScopeDigest: accountScopeDigest,
      revision: current.revision + 1,
    ),
    allowRecovery: true,
  );

  ConversationPreferenceSnapshot _replace(
    ConversationPreferenceSnapshot value, {
    ConversationHumorStyle? humorStyle,
    bool? humorStyleExplicit,
    String? preferredAddress,
    bool replaceAddress = false,
    Iterable<String>? forbiddenAddresses,
    Map<String, BanterDisposition>? banterBoundaries,
  }) => ConversationPreferenceSnapshot(
    accountScopeDigest: accountScopeDigest,
    revision: value.revision + 1,
    humorStyle: humorStyle ?? value.humorStyle,
    humorStyleExplicit: humorStyleExplicit ?? value.humorStyleExplicit,
    preferredAddress: replaceAddress
        ? preferredAddress
        : value.preferredAddress,
    forbiddenAddresses: forbiddenAddresses ?? value.forbiddenAddresses,
    banterBoundaries: banterBoundaries ?? value.banterBoundaries,
  );

  Future<void> _update(
    ConversationPreferenceSnapshot Function(ConversationPreferenceSnapshot)
    mutate, {
    bool allowRecovery = false,
    int? expectedRevision,
  }) {
    final operation = _tail.then((_) async {
      if ((!isAvailable &&
              !(allowRecovery &&
                  _lifecycle == _PreferenceLifecycle.degraded)) ||
          isClosed) {
        throw StateError('conversation_preference_unavailable');
      }
      if (expectedRevision != null && revision != expectedRevision) {
        throw StateError('conversation_preferences_changed');
      }
      final next = mutate(state.value);
      await _store.write(next);
      if (_lifecycle == _PreferenceLifecycle.retired || isClosed) return;
      _lifecycle = _PreferenceLifecycle.active;
      state.value = next;
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> deactivateAndDrain() {
    _retire();
    return Future.wait<void>([?_initialization, _tail]);
  }

  void _retire() {
    _lifecycle = _PreferenceLifecycle.retired;
    state.value = ConversationPreferenceSnapshot(
      accountScopeDigest: accountScopeDigest,
      revision: revision,
      humorStyle: ConversationHumorStyle.subdued,
    );
  }

  @override
  void onClose() {
    _retire();
    super.onClose();
  }
}
