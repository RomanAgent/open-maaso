import 'dart:async';
import 'dart:convert';

import '../models/message.dart';
import 'llm_response_integrity.dart';

class LLMStreamEvent {
  const LLMStreamEvent({required this.event, required this.data});

  final String event;
  final String data;

  bool get isDone => event == 'done' || data.trim() == '[DONE]';

  bool get isReplyDelta => event == 'reply.delta';

  Map<String, dynamic>? get jsonPayload {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  String get deltaText {
    if (isDone || !isReplyDelta) return '';
    final decoded = jsonPayload;
    if (decoded == null) return data;
    final direct = decoded['delta'];
    if (direct is String) return direct;
    return '';
  }
}

/// Optional transport capability for presentation-only structured streaming.
///
/// Natural conversation callers may opt into this stream explicitly. The
/// events grant no tool or action authority; the caller must still validate the
/// complete response envelope before accepting terminal output.
abstract interface class PresentationStreamingLLMClient {
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  });
}

/// Optional JSON-object transport for generation and its repair requests.
///
/// Message roles and order are retained. JSON mode constrains the transport's
/// output syntax; the caller still validates the artifact and action contract.
/// An unsupported provider must report failure without silently dispatching a
/// second, potentially billed request in plain-text mode.
abstract interface class StructuredOutputLLMClient {
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  });
}

/// Resolves one provider/model snapshot for an owned generation task.
/// The resolved transport must continue checking live account, permission and
/// configuration fences for each request; it must not freeze an access token.
abstract interface class StructuredOutputClientResolver {
  Future<LLMClient> resolveStructuredOutputClient();
}

enum ProjectSourceTermination { complete, knownLength }

/// Visible provider output is untrusted source data. A length-limited prefix
/// can be continued by the project producer but must never execute directly.
/// Unknown interruption and safety rejection are exceptions, not prefixes.
final class ProjectSourceResponse {
  const ProjectSourceResponse({
    required this.visibleText,
    required this.termination,
    this.facts,
  });

  final String visibleText;
  final ProjectSourceTermination termination;
  final LLMOutputFacts? facts;
  bool get isComplete => termination == ProjectSourceTermination.complete;
}

/// Optional generation transport with a host-owned project-source mode.
/// Ordinary conversation and strict JSON-string operations retain their
/// existing budgets and never inherit this mode from user-authored text.
abstract interface class ProjectSourceLLMClient {
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  });
}

/// LLM Client Abstract Interface
/// All Large Language Models (Gemini, OpenAI, Claude, etc.) integrated into
/// the Maaso agent core must implement this interface.
abstract class LLMClient {
  /// Default timeout for LLM API calls
  Duration get defaultTimeout => const Duration(seconds: 60);

  /// Initiates a multi-turn dialogue and returns the generated plain-text response.
  /// [messages] contains the context history and the current Prompt.
  Future<String> chat(List<Message> messages, {Duration? timeout});

  /// Forces the model to output data in JSON format.
  /// Typically used for RouterAgent dispatching or when requiring the
  /// model to output a structured configuration.
  Future<String> generateJson(String prompt, {Duration? timeout});

  /// Streaming chat yields text deltas for presentation. These chunks do not
  /// grant action authority: callers validate the complete structured response
  /// before executing actions. Early voice output requires the separately
  /// guarded presentation stream contract.
  ///
  /// Default implementation falls back to a single-shot [chat] call so
  /// providers that don't support real streaming still work — they just
  /// emit the whole response as one final chunk.  Override in concrete
  /// providers (e.g. OpenAI SSE) for true incremental delivery.
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  /// Structured SSE event stream. Providers that only support plain text
  /// inherit a compatibility wrapper that maps text deltas to reply.delta.
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await for (final chunk in streamChat(messages, timeout: timeout)) {
      if (chunk.isEmpty) continue;
      yield LLMStreamEvent(
        event: 'reply.delta',
        data: jsonEncode({'delta': chunk}),
      );
    }
  }

  /// Native tool-calling round.  Sends [messages] together with a [tools]
  /// array (use [SkillManager.toNativeTools] to build it) and returns
  /// whatever the model produced — final text, a list of tool invocations
  /// it wants run, or both.
  ///
  /// Caller drives the multi-turn loop:
  /// ```dart
  ///   var convo = [...history, Message.user(input)];
  ///   while (true) {
  ///     final turn = await client.chatWithTools(convo, tools);
  ///     if (!turn.hasToolCalls) return turn.content;
  ///     convo.add(Message.assistantToolCalls(turn.toolCalls, content: turn.content));
  ///     for (final c in turn.toolCalls) {
  ///       final args = jsonDecode(c.argumentsJson) as Map<String, dynamic>;
  ///       final result = await skillManager.invokeTool(c.name, args);
  ///       convo.add(Message.tool(toolCallId: c.id, content: result));
  ///     }
  ///   }
  /// ```
  ///
  /// Default implementation throws. Callers may select the validated JSON
  /// action-envelope path when native tool calling is unavailable.
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) {
    throw UnsupportedError('Provider does not implement native tool calling.');
  }
}
