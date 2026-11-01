/// Standardized Conversation Message Model
/// Used for passing context between the Agent, User, and LLM.
class Message {
  /// Role: 'system' / 'user' / 'assistant' / 'tool' (tool result).
  final String role;

  /// The actual content of the message.  May be empty when [toolCalls] is
  /// present (assistant message that *only* requested tool invocations).
  final String content;

  /// For `role == 'assistant'` only.  When the model decided to call one
  /// or more tools instead of (or in addition to) producing text, each
  /// requested call lives here.  Caller is expected to invoke them and
  /// append matching [Message.tool] entries to the conversation before
  /// asking the model to continue.
  final List<ToolCall>? toolCalls;

  /// For `role == 'tool'` only.  Identifies which assistant tool_call this
  /// message answers — must equal the matching [ToolCall.id].
  final String? toolCallId;

  Message({
    required this.role,
    required this.content,
    this.toolCalls,
    this.toolCallId,
  });

  factory Message.system(String content) =>
      Message(role: 'system', content: content);

  factory Message.user(String content) =>
      Message(role: 'user', content: content);

  factory Message.assistant(String content) =>
      Message(role: 'assistant', content: content);

  /// Assistant turn that requested one or more tool invocations.  Content
  /// may still be non-empty (some providers stream a partial reply before
  /// emitting tool_calls), but most of the time it's '' here.
  factory Message.assistantToolCalls(
    List<ToolCall> calls, {
    String content = '',
  }) => Message(role: 'assistant', content: content, toolCalls: calls);

  /// Result of running a single tool the assistant requested.  Append one
  /// of these per [ToolCall] the previous assistant message produced, in
  /// the same order, before the next [LLMClient.chatWithTools] call.
  factory Message.tool({required String toolCallId, required String content}) =>
      Message(role: 'tool', content: content, toolCallId: toolCallId);

  factory Message.fromJson(Map<String, dynamic> json) {
    final rawCalls = json['tool_calls'];
    final calls = rawCalls is List
        ? rawCalls
              .whereType<Map>()
              .map((m) => ToolCall.fromJson(m.cast<String, dynamic>()))
              .toList()
        : null;
    return Message(
      role: json['role'] as String? ?? 'user',
      content: json['content'] as String? ?? '',
      toolCalls: calls,
      toolCallId: json['tool_call_id'] as String?,
    );
  }

  /// Serializes to an OpenAI-compatible JSON map.  Drops fields that
  /// aren't applicable to the role so the API doesn't complain about
  /// unexpected keys (e.g. user messages with `tool_calls: null`).
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'role': role};
    if (toolCalls != null && toolCalls!.isNotEmpty) {
      json['tool_calls'] = toolCalls!.map((c) => c.toJson()).toList();
      // OpenAI accepts content=null for tool-call-only turns, but several
      // OpenAI-compat proxies reject null and want an empty string.  Empty
      // string is safe for both.
      json['content'] = content;
    } else {
      json['content'] = content;
    }
    if (toolCallId != null) {
      json['tool_call_id'] = toolCallId;
    }
    return json;
  }

  @override
  String toString() {
    final shortContent = content.length > 50
        ? '${content.substring(0, 50)}...'
        : content;
    final extra = [
      if (toolCalls != null) 'tool_calls=${toolCalls!.length}',
      if (toolCallId != null) 'tool_call_id=$toolCallId',
    ].join(', ');
    return 'Message(role: $role, content: $shortContent${extra.isEmpty ? '' : ', $extra'})';
  }
}

/// One tool invocation requested by an assistant turn.  Mirrors the
/// OpenAI `tool_calls[i]` shape so we can round-trip JSON without
/// remapping.
class ToolCall {
  /// Provider-assigned id.  Must be echoed back in the matching
  /// [Message.tool.toolCallId].
  final String id;

  /// Right now OpenAI only ships 'function'.  Kept for future
  /// 'retrieval' / 'code_interpreter' / 'computer_use' kinds.
  final String type;

  /// Tool name as registered in the request's `tools[]` array.
  final String name;

  /// Raw argument JSON the model produced.  We don't pre-parse it because
  /// providers occasionally stream unparseable fragments and the caller
  /// usually wants the raw bytes for logging.
  final String argumentsJson;

  ToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
    this.type = 'function',
  });

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final fn = json['function'];
    final name = fn is Map ? (fn['name']?.toString() ?? '') : '';
    final args = fn is Map ? (fn['arguments']?.toString() ?? '{}') : '{}';
    return ToolCall(
      id: json['id']?.toString() ?? '',
      type: json['type']?.toString() ?? 'function',
      name: name,
      argumentsJson: args,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'function': {'name': name, 'arguments': argumentsJson},
  };

  @override
  String toString() => 'ToolCall($name, args=$argumentsJson)';
}

/// Result of a single round-trip from [LLMClient.chatWithTools] — either
/// the model produced final text, asked for one or more tool calls, or
/// both.  Caller drives the loop: if [toolCalls] is non-empty, run them,
/// append `Message.tool(...)` for each, send a second request.
class ChatTurnResult {
  /// Text produced this round.  Empty when the model wants tools first
  /// before saying anything.
  final String content;

  /// Tools the model wants invoked.  Empty when the turn was pure text.
  final List<ToolCall> toolCalls;

  ChatTurnResult({required this.content, required this.toolCalls});

  bool get hasToolCalls => toolCalls.isNotEmpty;

  @override
  String toString() =>
      'ChatTurnResult(content=${content.length} chars, tools=${toolCalls.length})';
}
