import 'dart:convert';

import '../conversation/conversation_utterance.dart';
import '../intent/creation_intent.dart';
import '../intent/lookup_intent.dart';

export '../conversation/conversation_utterance.dart';

/// A stable failure code; model output is deliberately excluded from errors.
class ConversationReplyProtocolException implements Exception {
  const ConversationReplyProtocolException(this.code);

  final String code;

  @override
  String toString() => 'ConversationReplyProtocolException: $code';
}

/// Decodes a complete reply, without publishing text or executing any action.
///
/// The caller must separately admit the conversation scope and delivery mode.
/// Trailing semantic intents are data for the caller's admission gate, never
/// executable streaming actions. Other non-presentation actions remain invalid.
class ConversationReplyDecoder {
  const ConversationReplyDecoder();

  static const maxUtterances = 3;

  static const _envelopeFields = {'reply', 'actions'};
  static const _utteranceFields = {'type', 'text', 'after', 'pause', 'body'};
  static const _bodyTokenFields = {
    'mood',
    'gesture',
    'gaze',
    'posture',
    'style',
  };
  static const _bodyFields = {
    ..._bodyTokenFields,
    'intensity',
    'durationMs',
    'emitMood',
    'persistent',
  };

  ConversationReplyDraft decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) _fail('empty_response');
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      // Literal examples in a complete JSON string are presentation data.
      // These checks apply only to the non-protocol text fallback; they never
      // extract an embedded object or admit an outer executable wrapper.
      _rejectSidebandText(text);
      if (text.contains('```') || text.contains('Claw.')) {
        _fail('wrapped_or_script_response');
      }
      if (_resemblesStructuredResponse(text)) _fail('invalid_json');
      return _single(text);
    }
    if (decoded is! Map<String, Object?>) _fail('top_level_not_object');
    return decodeEnvelope(decoded);
  }

  /// Also admits a complete typed response through the same protocol checks.
  ///
  /// An isolated streaming action is insufficient: the whole list is needed to
  /// reject mixed actions, too many utterances, and unfinished continuations.
  ConversationReplyDraft decodeEnvelope(Map<String, Object?> envelope) {
    _requireFields(envelope, _envelopeFields, 'unknown_envelope_field');
    final reply = envelope['reply'];
    if (reply is! String) _fail('reply_not_string');
    _rejectSidebandText(reply);
    final actions = envelope['actions'];
    if (actions is! List) _fail('actions_not_list');
    if (actions.isEmpty) return _single(reply.trim());

    // Validate the whole action list before making any utterance available.
    CreationIntent? creationIntent;
    LookupIntent? lookupIntent;
    final utteranceActions = <Map<String, Object?>>[];
    for (var index = 0; index < actions.length; index++) {
      final action = actions[index];
      if (action is! Map<String, Object?>) _fail('action_not_object');
      if (action['type'] == 'creation.intent') {
        if (creationIntent != null) _fail('duplicate_creation_intent');
        if (index != actions.length - 1) {
          if (actions[index + 1] is Map &&
              (actions[index + 1] as Map)['type'] == 'reply.utterance') {
            _fail('presentation_after_creation_intent');
          }
          _fail('creation_intent_must_be_last');
        }
        try {
          creationIntent = CreationIntent.fromJson(action);
        } catch (_) {
          _fail('invalid_creation_intent');
        }
      } else if (action['type'] == 'lookup.intent') {
        if (lookupIntent != null) _fail('duplicate_lookup_intent');
        try {
          lookupIntent = LookupIntent.fromJson(action);
        } catch (_) {
          _fail('invalid_lookup_intent');
        }
      } else if (action['type'] == 'reply.utterance') {
        if (lookupIntent != null) _fail('presentation_after_lookup_intent');
        utteranceActions.add(action);
      } else {
        _fail('non_utterance_action');
      }
    }
    if (lookupIntent != null &&
        creationIntent != null &&
        creationIntent.mode != CreationIntentMode.none) {
      _fail('conflicting_semantic_intents');
    }
    if (utteranceActions.isEmpty) {
      final fallback = _single(reply.trim());
      return ConversationReplyDraft(
        reply: fallback.reply,
        utterances: fallback.utterances,
        usesUtteranceProtocol: false,
        creationIntent: creationIntent,
        lookupIntent: lookupIntent,
      );
    }
    if (utteranceActions.length > maxUtterances) _fail('too_many_utterances');

    final drafts = <ConversationUtteranceDraft>[];
    for (var index = 0; index < utteranceActions.length; index++) {
      final draft = decodeUtteranceAction(utteranceActions[index]);
      final isLast = index == utteranceActions.length - 1;
      if (isLast && !draft.after.endsReply) {
        _fail('missing_continuation');
      }
      if (!isLast && draft.after.endsReply) {
        _fail('utterance_after_terminal');
      }
      // There can be one optional supplement, never a chain of silent turns.
      if (draft.after == ConversationAfter.optional &&
          index != utteranceActions.length - 2) {
        _fail('optional_must_precede_final_utterance');
      }
      drafts.add(draft);
    }
    return ConversationReplyDraft(
      reply: reply.trim(),
      utterances: drafts,
      usesUtteranceProtocol: true,
      creationIntent: creationIntent,
      lookupIntent: lookupIntent,
    );
  }

  /// Validates one transport-complete presentation action without publishing it.
  ///
  /// Whole-list ordering and terminal checks still belong to [decodeEnvelope].
  /// This narrower entry point lets a streaming caller admit a `continue` unit
  /// while retaining terminal and optional units until the final envelope is
  /// available.
  ConversationUtteranceDraft decodeUtteranceAction(
    Map<String, Object?> action,
  ) {
    if (action['type'] != 'reply.utterance') {
      _fail('non_utterance_action');
    }
    _requireFields(action, _utteranceFields, 'unknown_utterance_field');
    final text = action['text'];
    if (text is! String || text.trim().isEmpty) _fail('invalid_utterance_text');
    _rejectSidebandText(text);
    final after = switch (action['after']) {
      'continue' => ConversationAfter.continueReply,
      'optional' => ConversationAfter.optional,
      'yield' => ConversationAfter.yieldToUser,
      'finish' => ConversationAfter.finish,
      _ => _fail('invalid_after'),
    };
    ConversationPause? pause;
    if (action.containsKey('pause')) {
      pause = switch (action['pause']) {
        'brief' => ConversationPause.brief,
        'invite' => ConversationPause.invite,
        _ => _fail('invalid_pause'),
      };
    }
    final body = action.containsKey('body')
        ? _decodeBody(action['body'])
        : null;
    return ConversationUtteranceDraft(
      text: text.trim(),
      after: after,
      pause: pause,
      body: body,
    );
  }

  Map<String, Object?> _decodeBody(Object? body) {
    if (body is! Map<String, Object?> || body.isEmpty) _fail('invalid_body');
    _requireFields(body, _bodyFields, 'unknown_body_field');
    for (final field in _bodyTokenFields) {
      if (!body.containsKey(field)) continue;
      final value = body[field];
      if (value is! String ||
          !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(value)) {
        _fail('invalid_body_token');
      }
    }
    if (!_bodyTokenFields.any(body.containsKey)) _fail('invalid_body');
    if (body.containsKey('intensity')) {
      final value = body['intensity'];
      if (value is! num || !value.isFinite || value < 0 || value > 1) {
        _fail('invalid_body_intensity');
      }
    }
    if (body.containsKey('durationMs')) {
      final value = body['durationMs'];
      if (value is! int || value < 350 || value > 5000) {
        _fail('invalid_body_duration');
      }
    }
    if (body.containsKey('emitMood') && body['emitMood'] is! bool) {
      _fail('invalid_body_emit_mood');
    }
    if (body.containsKey('persistent') && body['persistent'] is! bool) {
      _fail('invalid_body_persistent');
    }
    // This is structural admission only. Reuse the existing body-intent gate
    // for semantic tokens, ownership and the per-turn budget before execution.
    return body;
  }

  ConversationReplyDraft _single(String text) {
    if (text.isEmpty) _fail('empty_reply');
    return ConversationReplyDraft(
      reply: text,
      utterances: [ConversationUtteranceDraft(text: text)],
      usesUtteranceProtocol: false,
    );
  }

  static void _rejectSidebandText(String text) {
    // These are legacy control channels, including incomplete or malformed
    // tags. Their payload must never fall back to visible conversation text.
    if (RegExp(
      r'<\s*/?\s*(?:body_intent|task_handoff)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      _fail('sideband_response');
    }
  }

  static bool _resemblesStructuredResponse(String text) =>
      text.startsWith('{') ||
      text.startsWith('[') ||
      text.startsWith('"') ||
      RegExp(
        r'''["'](?:reply|actions|type|text|after|pause|body)["']\s*:''',
      ).hasMatch(text) ||
      RegExp(r'''[\{\[]\s*["'][^"'\n]+["']\s*:''').hasMatch(text) ||
      RegExp(r'[\{\[]\s*[a-zA-Z_$][\w$]*\s*:').hasMatch(text);

  static void _requireFields(
    Map<String, Object?> input,
    Set<String> allowed,
    String code,
  ) {
    if (input.keys.any((key) => !allowed.contains(key))) _fail(code);
  }

  static Never _fail(String code) =>
      throw ConversationReplyProtocolException(code);
}
