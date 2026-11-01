import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';

import '../llm/llm_client.dart';
import '../models/message.dart';
import '../utils/logger.dart';
import 'skill_manager.dart';

/// Top-level orchestrator for the native tool-calling loop.
///
/// Sequence per call:
///   1. Send [messages] + [tools] to [client].
///   2. If model produced final text and no tool_calls → return it.
///   3. Otherwise: invoke each requested tool via [skillManager], append
///      `tool` messages, loop until either text-only response, [maxRounds]
///      hit, or [shouldCancel] flips true.
///
/// Bug-tolerant by design:
///   * unknown tool name → `{"error":"unknown_tool","name":...}` returned
///     as the tool result; loop continues so the model can recover.
///   * malformed args JSON → same shape, `{"error":"bad_arguments",...}`.
///   * skill throw → caught, error JSON returned as result.
///
/// Returns a [ToolCallRunResult] capturing final text + per-round telemetry
/// for TC5's stats UI.
class ToolCallRunner {
  final LLMClient client;
  final SkillManager skillManager;

  /// Maximum native tool-call rounds before returning a bounded result.
  final int maxRounds;

  /// Optional cancellation token re-checked between rounds.  Returns true
  /// to bail with the last assistant text seen so far.
  final bool Function()? shouldCancel;

  /// Optional sink for tool execution events — TC5 telemetry / debug UI.
  final void Function(ToolCallEvent event)? onEvent;

  ToolCallRunner({
    required this.client,
    required this.skillManager,
    this.maxRounds = 6,
    this.shouldCancel,
    this.onEvent,
  });

  Future<ToolCallRunResult> run({
    required List<Message> messages,
    Duration? timeout,
    AppLocale? locale,
  }) async {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    final convo = List<Message>.from(messages);
    final tools = skillManager.toNativeTools(
      format: NativeToolFormat.openai,
      locale: turnLocale,
    );
    final perRound = <RoundStat>[];
    String lastContent = '';

    for (var round = 0; round < maxRounds; round++) {
      if (shouldCancel?.call() == true) {
        return ToolCallRunResult(
          content: lastContent,
          rounds: perRound,
          stoppedReason: 'cancelled',
        );
      }
      final turn = await client.chatWithTools(convo, tools, timeout: timeout);
      lastContent = turn.content;
      perRound.add(
        RoundStat(
          toolCalls: turn.toolCalls.length,
          hadContent: turn.content.isNotEmpty,
        ),
      );
      onEvent?.call(
        ToolCallEvent.round(
          index: round,
          toolCalls: turn.toolCalls.length,
          contentLength: turn.content.length,
        ),
      );

      if (!turn.hasToolCalls) {
        return ToolCallRunResult(
          content: turn.content,
          rounds: perRound,
          stoppedReason: 'text_only',
        );
      }

      // Persist the assistant turn that requested these calls — providers
      // require it to be present before the matching `tool` responses or
      // they reject the follow-up request.
      convo.add(
        Message.assistantToolCalls(turn.toolCalls, content: turn.content),
      );

      for (final call in turn.toolCalls) {
        onEvent?.call(ToolCallEvent.toolStart(name: call.name));
        final result = await _runOne(call, turnLocale);
        onEvent?.call(
          ToolCallEvent.toolEnd(
            name: call.name,
            resultPreview: _previewResult(result),
          ),
        );
        convo.add(Message.tool(toolCallId: call.id, content: result));
      }
    }
    return ToolCallRunResult(
      content: lastContent,
      rounds: perRound,
      stoppedReason: 'max_rounds',
    );
  }

  Future<String> _runOne(ToolCall call, AppLocale locale) async {
    Map<String, dynamic> args;
    try {
      final decoded = call.argumentsJson.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(call.argumentsJson);
      if (decoded is! Map) {
        return jsonEncode({'error': 'bad_arguments'});
      }
      args = Map<String, dynamic>.from(decoded);
    } catch (e) {
      Log.w('🛠️ [ToolCallRunner] bad args for ${call.name}: $e');
      return jsonEncode({'error': 'bad_arguments'});
    }
    try {
      return await skillManager.invokeTool(
        call.name,
        args,
        locale: locale,
        callId: call.id,
        channel: ActionContractChannel.nativeTool,
      );
    } on InvalidToolArgumentsException catch (e) {
      Log.w('🛠️ [ToolCallRunner] ${e.code} for ${call.name}');
      return jsonEncode({'error': 'bad_arguments'});
    } on StateError catch (e) {
      Log.w('🛠️ [ToolCallRunner] ${e.message}');
      return jsonEncode({'error': 'unknown_tool', 'name': call.name});
    } catch (e, st) {
      Log.e('❌ [ToolCallRunner] ${call.name} threw: $e\n$st');
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  static String _previewResult(String s) {
    final trimmed = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
  }
}

class RoundStat {
  final int toolCalls;
  final bool hadContent;
  RoundStat({required this.toolCalls, required this.hadContent});
}

class ToolCallRunResult {
  /// Final text produced by the model — empty when stopped early.
  final String content;

  /// One entry per LLM round-trip.  Useful for TC5 telemetry / debug UI.
  final List<RoundStat> rounds;

  /// 'text_only' | 'max_rounds' | 'cancelled'
  final String stoppedReason;

  ToolCallRunResult({
    required this.content,
    required this.rounds,
    required this.stoppedReason,
  });

  int get totalToolCalls => rounds.fold(0, (s, r) => s + r.toolCalls);
}

/// Per-step event surface for telemetry.  TC5 will plug a listener here
/// that updates a settings-page panel; production builds can leave it
/// null and pay zero overhead.
class ToolCallEvent {
  final String kind; // 'round' | 'tool_start' | 'tool_end'
  final int? index;
  final String? name;
  final int? toolCalls;
  final int? contentLength;
  final String? resultPreview;

  ToolCallEvent._({
    required this.kind,
    this.index,
    this.name,
    this.toolCalls,
    this.contentLength,
    this.resultPreview,
  });

  factory ToolCallEvent.round({
    required int index,
    required int toolCalls,
    required int contentLength,
  }) => ToolCallEvent._(
    kind: 'round',
    index: index,
    toolCalls: toolCalls,
    contentLength: contentLength,
  );

  factory ToolCallEvent.toolStart({required String name}) =>
      ToolCallEvent._(kind: 'tool_start', name: name);

  factory ToolCallEvent.toolEnd({
    required String name,
    required String resultPreview,
  }) => ToolCallEvent._(
    kind: 'tool_end',
    name: name,
    resultPreview: resultPreview,
  );
}
