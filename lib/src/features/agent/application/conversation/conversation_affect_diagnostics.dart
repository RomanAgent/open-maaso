import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';
import 'package:sembast/sembast.dart';

enum ConversationAffectDiagnosticMode { replyFirst, buffered, proactive }

enum ConversationAffectDiagnosticOutcome {
  missing,
  applied,
  rejected,
  taskBlocked,
}

enum ConversationAffectDiagnosticReason {
  metadataMissing,
  invalidMetadata,
  projectionApplied,
  projectionRejected,
  taskOwnerActive,
  localFailure,
}

/// A bounded account-local sidecar, never part of reply or speech delivery.
/// No text, model body, account identity, request identity or network data is
/// accepted by this interface. The caller records once after complete metadata.
abstract final class ConversationAffectDiagnostics {
  static const maximumRecords = 20;
  static const storeName = 'conversation_affect_diagnostics.v1';
  static final _record = StoreRef<String, List<Object?>>(
    storeName,
  ).record('recent');
  static Future<void> _tail = Future<void>.value();
  static const _moods = {
    ...AvatarBodyIntentPolicy.conversationMoods,
    'shy',
    'sleeping',
    'wink',
    'speaking',
    'bored',
    'fear',
  };

  /// [isCurrent] fences the originating account/environment. The caller also
  /// checks turn ownership before recording; a normally completed turn need
  /// not become stale merely because its active-turn handle was cleared.
  /// Persistence is queued, has no caller await, and cannot fail the chat.
  static void record({
    required ConversationAffectDiagnosticMode mode,
    required ConversationAffectDiagnosticOutcome outcome,
    required ConversationAffectDiagnosticReason reason,
    required bool Function() isCurrent,
    required bool cuePresent,
    int cueCount = 0,
    String? mood,
    double? intensity,
    int? durationMs,
    bool? persistent,
    bool? rendererReady,
  }) {
    final DBService owner;
    final Database database;
    try {
      final current = appServices.peek<DBService>();
      if (current == null) return;
      owner = current;
      database = owner.raw;
    } on Object {
      return;
    }
    bool current() {
      try {
        return identical(appServices.peek<DBService>(), owner) &&
            !owner.isClosed &&
            identical(owner.raw, database) &&
            isCurrent();
      } on Object {
        return false;
      }
    }

    if (!current()) return;
    final entry = <String, Object?>{
      'atUtc': DateTime.now().toUtc().toIso8601String(),
      'mode': mode.name,
      'outcome': outcome.name,
      'reason': reason.name,
      'cuePresent': cuePresent,
      'cueCount': cueCount.clamp(0, 32),
      if (mood != null && mood.length <= 16 && _moods.contains(mood))
        'mood': mood,
      if (intensity != null && intensity.isFinite)
        'intensity': intensity.clamp(0.0, 1.0),
      if (durationMs != null) 'durationMs': durationMs.clamp(0, 60000),
      'persistent': ?persistent,
      'rendererReady': ?rendererReady,
    };
    _tail = _tail
        .then((_) async {
          if (!current()) return;
          await database.transaction((transaction) async {
            if (!current()) return;
            final previous = await _record.get(transaction) ?? <Object?>[];
            if (!current()) return;
            final next = <Object?>[...previous, entry];
            if (next.length > maximumRecords) {
              next.removeRange(0, next.length - maximumRecords);
            }
            await _record.put(transaction, next);
          });
        })
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  /// Diagnostic/test draining only. Reply delivery never awaits this sidecar.
  static Future<void> get whenSettled => _tail;
}
