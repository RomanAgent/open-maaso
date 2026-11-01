import 'dart:async';

import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart'
    show ConversationReplyDecoder, ConversationReplyProtocolException;
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

enum ConversationProxyProbeStatus {
  jsonSupported,
  typedSupported,
  emptyResponse,
  invalidResponse,
  invalidOrTruncatedResponse,
  timedOut,
  serverError,
  transportError,
  responseLimit,
}

/// A diagnostic receipt, deliberately excluding response text and exceptions.
class ConversationProxyProbeResult {
  const ConversationProxyProbeResult({
    required this.status,
    required this.doneObserved,
    required this.streamClosed,
    required this.deltaEvents,
    required this.typedEvents,
    required this.ignoredEvents,
    required this.utteranceCount,
    this.errorCode,
  });

  final ConversationProxyProbeStatus status;
  final bool doneObserved;
  final bool streamClosed;
  final int deltaEvents;
  final int typedEvents;
  final int ignoredEvents;
  final int utteranceCount;
  final String? errorCode;

  bool get supportsContract =>
      status == ConversationProxyProbeStatus.jsonSupported ||
      status == ConversationProxyProbeStatus.typedSupported;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'supportsContract': supportsContract,
    'doneObserved': doneObserved,
    'streamClosed': streamClosed,
    'deltaEvents': deltaEvents,
    'typedEvents': typedEvents,
    'ignoredEvents': ignoredEvents,
    'utteranceCount': utteranceCount,
    if (errorCode != null) 'errorCode': errorCode,
  };
}

/// Explicit, one-request protocol check using a caller's authenticated client.
///
/// This has no runtime, TTS, storage, prompt logger, or credential dependency.
/// It neither closes the shared client nor changes its authentication state.
class ConversationProxyProbe {
  const ConversationProxyProbe();

  static const maxTimeout = Duration(seconds: 30);
  static const maxResponseCharacters = 16384;
  static const maxEvents = 512;
  static const _metadataEvents = {'trace', 'usage', 'ping', 'heartbeat'};

  static const expectedResponse =
      '{"reply":"Alpha.Beta?Gamma.","actions":['
      '{"type":"reply.utterance","text":"Alpha.","after":"continue",'
      '"pause":"brief","body":{"mood":"thinking","gaze":"away"}},'
      '{"type":"reply.utterance","text":"Beta?","after":"optional",'
      '"pause":"invite"},'
      '{"type":"reply.utterance","text":"Gamma.","after":"finish"}]}';

  /// Shorter deadlines exist for tests; callers cannot extend the 30s budget.
  Future<ConversationProxyProbeResult> run(
    LLMClient client, {
    Duration timeout = maxTimeout,
  }) {
    if (timeout <= Duration.zero || timeout > maxTimeout) {
      throw ArgumentError('Probe timeout must be within 0 < timeout <= 30s.');
    }
    final result = Completer<ConversationProxyProbeResult>();
    final delta = StringBuffer();
    final typed = <Map<String, Object?>>[];
    var deltaEvents = 0;
    var typedEvents = 0;
    var ignoredEvents = 0;
    var eventCount = 0;
    var responseCharacters = 0;
    var doneObserved = false;
    var streamClosed = false;
    StreamSubscription<LLMStreamEvent>? subscription;
    Timer? deadline;

    void cancelSubscription() {
      final current = subscription;
      subscription = null;
      if (current == null) return;
      try {
        // Cancellation itself may be asynchronous or stuck in a provider.
        // The diagnostic result must still respect its total deadline.
        unawaited(current.cancel().catchError((Object _, StackTrace _) {}));
      } catch (_) {
        // Never include provider exception text in this diagnostic receipt.
      }
    }

    void finish(
      ConversationProxyProbeStatus status, {
      String? errorCode,
      int utteranceCount = 0,
    }) {
      if (result.isCompleted) return;
      deadline?.cancel();
      result.complete(
        ConversationProxyProbeResult(
          status: status,
          doneObserved: doneObserved,
          streamClosed: streamClosed,
          deltaEvents: deltaEvents,
          typedEvents: typedEvents,
          ignoredEvents: ignoredEvents,
          utteranceCount: utteranceCount,
          errorCode: errorCode,
        ),
      );
      cancelSubscription();
    }

    void validate() {
      const decoder = ConversationReplyDecoder();
      final raw = delta.toString().trim();
      if (typed.isEmpty && raw.isEmpty) {
        finish(
          ConversationProxyProbeStatus.emptyResponse,
          errorCode: 'empty_response',
        );
        return;
      }
      try {
        final expected = decoder.decode(expectedResponse);
        final actual = typed.isEmpty
            ? decoder.decode(raw)
            : decoder.decodeEnvelope({
                'reply': typed.map((action) => action['text'] ?? '').join(),
                'actions': typed,
              });
        if (!_matchesFixture(actual, expected)) {
          finish(
            ConversationProxyProbeStatus.invalidResponse,
            errorCode: 'fixture_mismatch',
          );
          return;
        }
        // Some typed protocols also emit the aggregate spoken text as deltas.
        // Accept only the fixed aggregate or the same validated JSON envelope.
        if (typed.isNotEmpty && raw.isNotEmpty && raw != expected.reply) {
          if (!_matchesFixture(decoder.decode(raw), expected)) {
            finish(
              ConversationProxyProbeStatus.invalidResponse,
              errorCode: 'conflicting_formats',
            );
            return;
          }
        }
        finish(
          typed.isEmpty
              ? ConversationProxyProbeStatus.jsonSupported
              : ConversationProxyProbeStatus.typedSupported,
          utteranceCount: actual.utterances.length,
        );
      } on ConversationReplyProtocolException {
        // The public parser intentionally does not guess whether malformed
        // JSON was truncated by transport or originally generated that way.
        finish(
          ConversationProxyProbeStatus.invalidOrTruncatedResponse,
          errorCode: 'invalid_or_truncated_contract',
        );
      } catch (_) {
        finish(
          ConversationProxyProbeStatus.invalidResponse,
          errorCode: 'invalid_contract',
        );
      }
    }

    void onEvent(LLMStreamEvent event) {
      if (result.isCompleted) return;
      eventCount++;
      if (eventCount > maxEvents) {
        finish(
          ConversationProxyProbeStatus.responseLimit,
          errorCode: 'event_limit',
        );
        return;
      }
      responseCharacters += event.data.length;
      if (responseCharacters > maxResponseCharacters) {
        finish(
          ConversationProxyProbeStatus.responseLimit,
          errorCode: 'response_limit',
        );
        return;
      }
      if (event.event == 'error') {
        finish(
          ConversationProxyProbeStatus.serverError,
          errorCode: 'server_error',
        );
        return;
      }
      if (event.event == 'done' || (event.isReplyDelta && event.isDone)) {
        doneObserved = true;
        validate();
        return;
      }
      if (event.event != 'reply.delta' && event.event != 'reply.utterance') {
        if (_metadataEvents.contains(event.event)) {
          ignoredEvents++;
        } else {
          // Match the real generator: discarding a behavioral event cannot
          // turn an otherwise mixed response into proof of compatibility.
          finish(
            ConversationProxyProbeStatus.invalidResponse,
            errorCode: 'non_presentation_event',
          );
        }
        return;
      }
      if (event.event == 'reply.delta') {
        deltaEvents++;
        delta.write(event.deltaText);
        return;
      }
      typedEvents++;
      final payload = event.jsonPayload;
      if (payload == null || typed.length >= 3) {
        finish(
          ConversationProxyProbeStatus.invalidResponse,
          errorCode: 'invalid_typed_payload',
        );
        return;
      }
      typed.add({
        if (!payload.containsKey('type')) 'type': 'reply.utterance',
        ...payload,
      });
    }

    deadline = Timer(
      timeout,
      () => finish(
        ConversationProxyProbeStatus.timedOut,
        errorCode: 'total_timeout',
      ),
    );
    try {
      subscription = client
          .streamChatEvents([
            Message.system(
              '[maaso_mode:low_latency_voice]\n'
              'This is a synthetic protocol check, not a user conversation. '
              'Return exactly the JSON object in the user message. '
              'Preserve every field and value. No markdown or extra text.',
            ),
            Message.user(expectedResponse),
          ], timeout: timeout)
          .listen(
            onEvent,
            onError: (Object _, StackTrace _) => finish(
              ConversationProxyProbeStatus.transportError,
              errorCode: 'transport_error',
            ),
            onDone: () {
              if (result.isCompleted) return;
              streamClosed = true;
              validate();
            },
          );
      if (result.isCompleted) cancelSubscription();
    } catch (_) {
      finish(
        ConversationProxyProbeStatus.transportError,
        errorCode: 'transport_error',
      );
    }
    return result.future;
  }

  static bool _matchesFixture(
    ConversationReplyDraft actual,
    ConversationReplyDraft expected,
  ) {
    if (!actual.usesUtteranceProtocol ||
        actual.reply != expected.reply ||
        actual.utterances.length != expected.utterances.length) {
      return false;
    }
    for (var i = 0; i < expected.utterances.length; i++) {
      final a = actual.utterances[i];
      final b = expected.utterances[i];
      if (a.text != b.text ||
          a.after != b.after ||
          a.pause != b.pause ||
          !_sameJson(a.body, b.body)) {
        return false;
      }
    }
    return true;
  }

  static bool _sameJson(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every(
            (key) => b.containsKey(key) && _sameJson(a[key], b[key]),
          );
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_sameJson(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
