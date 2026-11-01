import '../intent/creation_intent.dart';
import '../intent/lookup_intent.dart';

/// What may happen after a published utterance in this model response.
///
/// These values grant no permission to start another model turn or a tool.
enum ConversationAfter {
  continueReply,
  optional,
  yieldToUser,
  finish;

  String get wireValue => switch (this) {
    continueReply => 'continue',
    optional => 'optional',
    yieldToUser => 'yield',
    finish => 'finish',
  };

  bool get endsReply => this == yieldToUser || this == finish;
}

/// A semantic pause; the host, rather than the model, chooses its duration.
enum ConversationPause { brief, invite }

/// An unpublished utterance. Turn identity and sequence belong to the host.
class ConversationUtteranceDraft {
  ConversationUtteranceDraft({
    required this.text,
    this.after = ConversationAfter.finish,
    this.pause,
    Map<String, Object?>? body,
  }) : body = body == null ? null : _freezeMap(body);

  final String text;
  final ConversationAfter after;
  final ConversationPause? pause;

  /// High-level intent data, not a renderer command.
  ///
  /// After publication, a consumer may apply this data at real speech start or
  /// text delivery through the existing body-intent admission, turn ownership
  /// and per-turn budget. Gesture omission and an explicit `none` remain distinct.
  final Map<String, Object?>? body;
}

/// A complete response with presentation drafts and unexecuted semantic data.
class ConversationReplyDraft {
  ConversationReplyDraft({
    required this.reply,
    required List<ConversationUtteranceDraft> utterances,
    required this.usesUtteranceProtocol,
    this.creationIntent,
    this.lookupIntent,
  }) : utterances = List<ConversationUtteranceDraft>.unmodifiable(utterances);

  /// Compatibility aggregate; never publish it in addition to [utterances].
  final String reply;
  final List<ConversationUtteranceDraft> utterances;
  final bool usesUtteranceProtocol;

  /// Data for the owning Runtime to admit after the complete envelope is proven.
  /// Neither decoding nor streaming presentation grants execution permission.
  final CreationIntent? creationIntent;
  final LookupIntent? lookupIntent;
}

Map<String, Object?> _freezeMap(Map<String, Object?> input) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in input.entries) entry.key: _freezeValue(entry.value),
    });

Object? _freezeValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  if (value is Map<String, Object?>) return _freezeMap(value);
  throw ArgumentError('Conversation body values must be JSON data');
}
