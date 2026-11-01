import '../body/avatar_body_intent_policy.dart';
import '../persona/persona_utterance_decoder.dart';

/// Optional face metadata for a completely verified compatibility reply. This
/// never publishes text or grants a tool, gaze, posture or full-body action.
abstract final class ReplyFirstFacialCue {
  static ConversationUtteranceDraft? validate(
    ConversationReplyDraft reply, {
    required String streamedReply,
  }) {
    if (!reply.usesUtteranceProtocol) return null;
    if (reply.creationIntent == null) {
      throw const ConversationReplyProtocolException('missing_creation_intent');
    }
    if (reply.utterances.length != 1) _fail('multiple');
    final unit = reply.utterances.single;
    if (unit.text != reply.reply ||
        (streamedReply.isNotEmpty && unit.text != streamedReply.trim())) {
      _fail('mirror_mismatch');
    }
    if (!unit.after.endsReply) _fail('not_terminal');
    final payload = AvatarBodyIntentPolicy.normalize(
      unit.body == null ? null : Map<String, dynamic>.from(unit.body!),
    );
    if (payload == null || payload['mood'] == 'none') _fail('invalid');
    if ((payload['gesture'] ?? 'none') != 'none' ||
        payload['gaze'] != 'none' ||
        payload['posture'] != 'none' ||
        payload.containsKey('energy')) {
      _fail('not_facial');
    }
    // Even an omitted gesture must not infer a nod/cheer from the mood.
    return ConversationUtteranceDraft(
      text: unit.text,
      after: unit.after,
      body: {...payload, 'gesture': 'none'},
    );
  }

  /// Optional presentation mistakes cannot justify another semantic request.
  /// Missing/invalid creation intent data retains the existing repair path.
  static bool isPresentationFailure(ConversationReplyProtocolException error) {
    final code = error.code;
    return code.startsWith('reply_first_body_') ||
        code.startsWith('invalid_body') ||
        const {
          'unknown_body_field',
          'unknown_utterance_field',
          'invalid_utterance_text',
          'invalid_after',
          'invalid_pause',
          'too_many_utterances',
          'missing_continuation',
          'utterance_after_terminal',
          'presentation_after_lookup_intent',
          'presentation_after_creation_intent',
        }.contains(code);
  }

  static Never _fail(String reason) =>
      throw ConversationReplyProtocolException('reply_first_body_$reason');
}
