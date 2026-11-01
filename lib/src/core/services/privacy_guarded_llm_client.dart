import 'dart:async';

import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

/// Optional transport capability for a caller's final owned-turn fence after
/// asynchronous configuration/privacy/authentication preparation. Ordinary chat
/// and stream methods keep their existing behavior and output contracts.
abstract interface class PrivacyAdmissionLLMClient {
  Future<String> chatWithAdmission(
    List<Message> messages, {
    Duration? timeout,
    required void Function() onAdmitted,
  });
}

/// A cached transport receives a fresh permission check for each operation.
/// The factory supplies a guard bound to the account that resolved the client.
LLMClient privacyGuardedLLMClient(
  LLMClient inner,
  Future<void> Function() requirePermission,
) {
  if (inner is StructuredOutputLLMClient) {
    return inner is PresentationStreamingLLMClient
        ? _PrivacyStructuredPresentationClient(inner, requirePermission)
        : _PrivacyStructuredClient(inner, requirePermission);
  }
  return inner is PresentationStreamingLLMClient
      ? _PrivacyPresentationClient(inner, requirePermission)
      : _PrivacyLLMClient(inner, requirePermission);
}

/// Pins only the configuration resolver, retaining every live permission
/// wrapper. A repair cannot silently switch providers after Settings changes.
Future<LLMClient> resolveStructuredOutputClientForTask(LLMClient client) async {
  if (client is _PrivacyLLMClient) {
    return privacyGuardedLLMClient(
      await resolveStructuredOutputClientForTask(client.inner),
      client.requirePermission,
    );
  }
  if (client is StructuredOutputClientResolver) {
    return (client as StructuredOutputClientResolver)
        .resolveStructuredOutputClient();
  }
  return client;
}

/// Role-preserving generation request. Production structured transports never
/// retry into ordinary chat on a provider rejection. The compatibility branch
/// supports existing local/test clients which do not advertise JSON mode.
Future<String> chatJsonObjectWithPrivacyAdmission(
  LLMClient client,
  List<Message> messages, {
  Duration? timeout,
  required FutureOr<void> Function() onAdmitted,
}) async {
  if (client is _PrivacyLLMClient) {
    await client.requirePermission();
    return chatJsonObjectWithPrivacyAdmission(
      client.inner,
      messages,
      timeout: timeout,
      onAdmitted: () async {
        // Authentication refresh can await inside the transport. Recheck at
        // the last local boundary before the request leaves this account.
        await client.requirePermission();
        await onAdmitted();
      },
    );
  }
  if (client is StructuredOutputLLMClient) {
    return (client as StructuredOutputLLMClient).chatJsonObject(
      messages,
      timeout: timeout,
      onAdmitted: onAdmitted,
    );
  }
  await onAdmitted();
  return client.chat(messages, timeout: timeout);
}

/// Source mode preserves roles and performs live permission checks before
/// dispatch. Local/test clients can return complete source DTO text through
/// chat; production transports negotiate the dedicated mode explicitly.
Future<ProjectSourceResponse> generateProjectSourceWithPrivacyAdmission(
  LLMClient client,
  List<Message> messages, {
  Duration? timeout,
  required FutureOr<void> Function() onAdmitted,
  bool Function()? shouldCancel,
}) async {
  if (shouldCancel?.call() == true) {
    throw const LLMResponseIntegrityException.publicFailure('interrupted');
  }
  if (client is _PrivacyLLMClient) {
    await client.requirePermission();
    final response = await generateProjectSourceWithPrivacyAdmission(
      client.inner,
      messages,
      timeout: timeout,
      shouldCancel: shouldCancel,
      onAdmitted: () async {
        await client.requirePermission();
        await onAdmitted();
      },
    );
    await client.requirePermission();
    return response;
  }
  if (client is ProjectSourceLLMClient) {
    return (client as ProjectSourceLLMClient).generateProjectSource(
      messages,
      timeout: timeout,
      shouldCancel: shouldCancel,
      onAdmitted: onAdmitted,
    );
  }
  await onAdmitted();
  final text = await client.chat(messages, timeout: timeout);
  if (shouldCancel?.call() == true) {
    throw const LLMResponseIntegrityException.publicFailure('interrupted');
  }
  return ProjectSourceResponse(
    visibleText: text,
    termination: ProjectSourceTermination.complete,
  );
}

/// Runs the known local permission wrappers before announcing admission to the
/// inner model client. The callback may still cancel a stale owned turn.
/// This boundary is deliberately conservative for other clients: failures
/// after entry into an unknown inner client may have reached a provider.
/// Existing chat/stream APIs keep their original behavior and error types.
Future<String> chatWithPrivacyAdmission(
  LLMClient client,
  List<Message> messages, {
  Duration? timeout,
  required void Function() onAdmitted,
}) async {
  if (client is _PrivacyLLMClient) {
    await client.requirePermission();
    return chatWithPrivacyAdmission(
      client.inner,
      messages,
      timeout: timeout,
      onAdmitted: onAdmitted,
    );
  }
  if (client is PrivacyAdmissionLLMClient) {
    return (client as PrivacyAdmissionLLMClient).chatWithAdmission(
      messages,
      timeout: timeout,
      onAdmitted: onAdmitted,
    );
  }
  onAdmitted();
  return client.chat(messages, timeout: timeout);
}

class _PrivacyLLMClient extends LLMClient {
  _PrivacyLLMClient(this.inner, this.requirePermission);
  final LLMClient inner;
  final Future<void> Function() requirePermission;

  @override
  Duration get defaultTimeout => inner.defaultTimeout;

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    await requirePermission();
    return inner.chat(messages, timeout: timeout);
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    await requirePermission();
    return inner.generateJson(prompt, timeout: timeout);
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    await requirePermission();
    return inner.chatWithTools(messages, tools, timeout: timeout);
  }

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await requirePermission();
    yield* inner.streamChat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await requirePermission();
    yield* inner.streamChatEvents(messages, timeout: timeout);
  }
}

final class _PrivacyPresentationClient extends _PrivacyLLMClient
    implements PresentationStreamingLLMClient {
  _PrivacyPresentationClient(super.inner, super.requirePermission);

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await requirePermission();
    yield* (inner as PresentationStreamingLLMClient)
        .streamPresentationChatEvents(messages, timeout: timeout);
  }
}

class _PrivacyStructuredClient extends _PrivacyLLMClient
    implements StructuredOutputLLMClient, ProjectSourceLLMClient {
  _PrivacyStructuredClient(super.inner, super.requirePermission);

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) => generateProjectSourceWithPrivacyAdmission(
    this,
    messages,
    timeout: timeout,
    shouldCancel: shouldCancel,
    onAdmitted: onAdmitted ?? () {},
  );

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) => chatJsonObjectWithPrivacyAdmission(
    this,
    messages,
    timeout: timeout,
    onAdmitted: onAdmitted ?? () {},
  );
}

final class _PrivacyStructuredPresentationClient
    extends _PrivacyStructuredClient
    implements PresentationStreamingLLMClient {
  _PrivacyStructuredPresentationClient(super.inner, super.requirePermission);

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await requirePermission();
    yield* (inner as PresentationStreamingLLMClient)
        .streamPresentationChatEvents(messages, timeout: timeout);
  }
}
