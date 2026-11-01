import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:sembast/sembast.dart';

enum ChatReplyFeedback { excellent, poor }

/// Immutable identity of the persisted reply selected by the user.
/// Never resolve a later widget's message after an asynchronous menu action.
final class ChatReplyFeedbackTarget {
  const ChatReplyFeedbackTarget._({
    required ChatReplyFeedbackStore owner,
    required this.messageId,
    required this.sessionId,
    required String fingerprint,
  }) : _owner = owner,
       _fingerprint = fingerprint;

  final ChatReplyFeedbackStore _owner;
  final int messageId;
  final String sessionId;
  final String _fingerprint;
}

/// Local-only reply ratings in the existing account's Sembast database.
///
/// No network request, report submission, runtime training, or startup service
/// is involved. The account mount and database handle are captured once, while
/// each operation verifies that the exact persisted reply still exists.
final class ChatReplyFeedbackStore {
  ChatReplyFeedbackStore({
    required DBService database,
    required AccountStorageScopeService scopes,
    required AccountStorageScopeMount mount,
    bool Function()? isCurrentContext,
  }) : _ownerDatabase = database,
       _database = database.raw,
       _scopes = scopes,
       _mount = mount,
       _isCurrentContext = isCurrentContext {
    scopes.requireCurrent(mount);
  }

  static final _messages = intMapStoreFactory.store('chat_messages');
  static final _feedback = StoreRef<String, Map<String, Object?>>(
    'chat_reply_feedback.v1',
  );

  final DBService _ownerDatabase;
  final Database _database;
  final AccountStorageScopeService _scopes;
  final AccountStorageScopeMount _mount;
  final bool Function()? _isCurrentContext;

  /// Capture only when a message menu opens; account startup stays unchanged.
  static ChatReplyFeedbackStore? maybeCurrent() {
    final database = appServices.maybeFind<DBService>();
    final scopes = appServices.maybeFind<AccountStorageScopeService>();
    final mount = scopes?.activeMount;
    if (database == null || scopes == null || mount == null) return null;
    try {
      return ChatReplyFeedbackStore(
        database: database,
        scopes: scopes,
        mount: mount,
        isCurrentContext: () =>
            identical(appServices.maybeFind<DBService>(), database) &&
            identical(
              appServices.maybeFind<AccountStorageScopeService>(),
              scopes,
            ),
      );
    } on StateError {
      return null;
    }
  }

  bool get isCurrent {
    if (!_scopes.isCurrent(_mount) || _isCurrentContext?.call() == false) {
      return false;
    }
    try {
      return identical(_ownerDatabase.raw, _database);
    } on StateError {
      return false;
    }
  }

  /// In-memory streaming rows and user messages have no rating target.
  ChatReplyFeedbackTarget? capture(ChatMessage message) {
    if (!isCurrent || !_eligible(message)) return null;
    return ChatReplyFeedbackTarget._(
      owner: this,
      messageId: message.id!,
      sessionId: message.sessionId,
      fingerprint: _fingerprint(message),
    );
  }

  Future<ChatReplyFeedback?> read(ChatReplyFeedbackTarget target) =>
      _withTarget(target, (transaction) async {
        final value = await _record(target).get(transaction);
        return _decode(value, target);
      });

  /// Repeating a selected choice cancels it; the other choice replaces it.
  /// Sembast serializes the read/modify/write so rapid taps stay mutually exclusive.
  Future<ChatReplyFeedback?> toggle(
    ChatReplyFeedbackTarget target,
    ChatReplyFeedback choice,
  ) => _withTarget(target, (transaction) async {
    final record = _record(target);
    final previous = _decode(await record.get(transaction), target);
    _requireTarget(target);
    final next = previous == choice ? null : choice;
    if (next == null) {
      await record.delete(transaction);
    } else {
      await record.put(transaction, <String, Object?>{
        'fingerprint': target._fingerprint,
        'value': next.name,
      });
    }
    return next;
  });

  Future<T> _withTarget<T>(
    ChatReplyFeedbackTarget target,
    Future<T> Function(Transaction transaction) action,
  ) async {
    _requireTarget(target);
    final result = await _database.transaction((transaction) async {
      _requireTarget(target);
      final raw = await _messages.record(target.messageId).get(transaction);
      _requireTarget(target);
      final message = raw == null
          ? null
          : ChatMessage.fromJson(raw, id: target.messageId);
      if (message == null ||
          !_eligible(message) ||
          message.sessionId != target.sessionId ||
          _fingerprint(message) != target._fingerprint) {
        throw StateError('chat_reply_feedback_message_changed');
      }
      final result = await action(transaction);
      _requireTarget(target);
      return result;
    });
    _requireTarget(target);
    return result;
  }

  void _requireTarget(ChatReplyFeedbackTarget target) {
    if (!isCurrent || !identical(target._owner, this)) {
      throw StateError('chat_reply_feedback_scope_changed');
    }
  }

  RecordRef<String, Map<String, Object?>> _record(
    ChatReplyFeedbackTarget target,
  ) => _feedback.record(
    jsonEncode([
      _mount.scope.storageNamespace,
      target.sessionId,
      target.messageId,
    ]),
  );

  static ChatReplyFeedback? _decode(
    Map<String, Object?>? value,
    ChatReplyFeedbackTarget target,
  ) {
    if (value?['fingerprint'] != target._fingerprint) return null;
    return switch (value?['value']) {
      'excellent' => ChatReplyFeedback.excellent,
      'poor' => ChatReplyFeedback.poor,
      _ => null,
    };
  }

  static bool _eligible(ChatMessage message) =>
      message.id != null &&
      message.id! > 0 &&
      message.sessionId.trim().isNotEmpty &&
      message.senderId.trim().isNotEmpty &&
      !message.isUserMessage &&
      message.senderId != 'user' &&
      message.content.trim().isNotEmpty &&
      (message.deliveryStatus == null ||
          message.deliveryStatus == 'published' ||
          message.deliveryStatus == 'interrupted');

  // Only this digest is stored alongside the choice; reply text is not duplicated.
  static String _fingerprint(ChatMessage message) =>
      sha256.convert(utf8.encode(jsonEncode(message.toJson()))).toString();
}
